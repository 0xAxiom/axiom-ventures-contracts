// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenVesting} from "./TokenVesting.sol";

interface ITokenDistributor {
    function addToken(address token, address vestingContract) external;
}

/**
 * @title AgentDeal
 * @dev Factory + registry for creating investment deals. Deployed once, creates vesting contracts per deal.
 * @notice Each deal represents a $20K USDC investment for 20% of an agent's token supply
 */
contract AgentDeal is Ownable {
    using SafeERC20 for IERC20;
    /// @notice Deal status enumeration
    enum DealStatus {
        Created,      // Deal created but tokens not yet deposited
        Confirmed,    // Tokens deposited to vesting contract
        Active        // Deal is live and vesting
    }

    /// @notice Structure representing an investment deal
    struct Deal {
        address agent;           // Agent receiving the investment
        address token;           // Agent's ERC20 token address
        address vestingContract; // TokenVesting contract for this deal
        uint256 usdcAmount;     // USDC amount (always 20000e6)
        uint256 tokenAmount;    // Amount of agent tokens (20% of supply)
        uint256 timestamp;      // When the deal was created
        DealStatus status;      // Current status of the deal
    }

    /// @notice AxiomVault contract address (where USDC comes from)
    address public immutable vault;
    
    /// @notice TokenDistributor contract address (beneficiary of vesting contracts)
    address public immutable distributor;
    
    /// @notice USDC token contract address
    IERC20 public immutable usdc;
    
    /// @notice Array of all deals
    Deal[] public deals;
    
    /// @notice Mapping from agent address to array of their deal IDs
    mapping(address => uint256[]) public agentToDeals;
    
    /// @notice Standard USDC investment amount (20,000 USDC)
    uint256 public constant USDC_AMOUNT = 20_000e6;
    
    /// @notice Standard cliff period (2 weeks)
    uint256 public constant CLIFF_DURATION = 1_209_600; // 2 weeks in seconds
    
    /// @notice Standard vesting period (3 months after cliff)
    uint256 public constant VESTING_DURATION = 7_776_000; // 90 days in seconds

    /// @notice Emitted when a new deal is created
    event DealCreated(
        uint256 indexed dealId,
        address indexed agent,
        address indexed token,
        address vestingContract,
        uint256 tokenAmount
    );

    /// @notice Emitted when a deal is confirmed (tokens deposited)
    event DealConfirmed(uint256 indexed dealId, address indexed agent);

    /// @notice Emitted when a deal is executed atomically
    event DealExecuted(
        uint256 indexed dealId,
        address indexed agent,
        address indexed token,
        address vestingContract,
        uint256 tokenAmount,
        uint256 usdcAmount
    );

    /**
     * @dev Creates the AgentDeal factory contract
     * @param _vault Address of the AxiomVault contract
     * @param _distributor Address of the TokenDistributor contract
     * @param _usdc Address of the USDC token contract
     * @param _owner Address that will own this contract (Safe multisig)
     */
    constructor(
        address _vault,
        address _distributor,
        address _usdc,
        address _owner
    ) Ownable(_owner) {
        require(_vault != address(0), "AgentDeal: vault is the zero address");
        require(_distributor != address(0), "AgentDeal: distributor is the zero address");
        require(_usdc != address(0), "AgentDeal: usdc is the zero address");
        require(_owner != address(0), "AgentDeal: owner is the zero address");
        
        vault = _vault;
        distributor = _distributor;
        usdc = IERC20(_usdc);
    }

    /**
     * @notice Create a new investment deal
     * @dev Only callable by owner (Safe multisig). Does NOT transfer tokens or USDC.
     * @param agent Address of the agent receiving investment
     * @param token Address of the agent's ERC20 token
     * @param tokenAmount Amount of tokens to vest (20% of agent's supply)
     * @return dealId The ID of the created deal
     */
    function createDeal(
        address agent,
        address token,
        uint256 tokenAmount
    ) external onlyOwner returns (uint256 dealId) {
        require(agent != address(0), "AgentDeal: agent is the zero address");
        require(token != address(0), "AgentDeal: token is the zero address");
        require(tokenAmount > 0, "AgentDeal: token amount must be > 0");

        // Deploy new TokenVesting contract for this deal
        TokenVesting vestingContract = new TokenVesting(
            token,
            distributor,
            CLIFF_DURATION,
            VESTING_DURATION,
            tokenAmount
        );

        // Create deal record
        dealId = deals.length;
        deals.push(Deal({
            agent: agent,
            token: token,
            vestingContract: address(vestingContract),
            usdcAmount: USDC_AMOUNT,
            tokenAmount: tokenAmount,
            timestamp: block.timestamp,
            status: DealStatus.Created
        }));

        // Track deals by agent
        agentToDeals[agent].push(dealId);

        emit DealCreated(dealId, agent, token, address(vestingContract), tokenAmount);
    }

    /**
     * @notice Confirm a deal after tokens have been deposited to the vesting contract
     * @dev Only callable by owner. Verifies the vesting contract has received the tokens.
     * @param dealId ID of the deal to confirm
     */
    function confirmDeal(uint256 dealId) external onlyOwner {
        require(dealId < deals.length, "AgentDeal: invalid deal ID");
        
        Deal storage deal = deals[dealId];
        require(deal.status == DealStatus.Created, "AgentDeal: deal already confirmed");
        
        // Verify the vesting contract has received the tokens
        IERC20 token = IERC20(deal.token);
        uint256 balance = token.balanceOf(deal.vestingContract);
        require(balance >= deal.tokenAmount, "AgentDeal: insufficient tokens in vesting contract");
        
        deal.status = DealStatus.Confirmed;
        
        emit DealConfirmed(dealId, deal.agent);
    }

    /**
     * @notice Execute a deal atomically as part of token launch
     * @dev Called during launch flow after 20% tokens are sent to vesting contract
     * @param agent Address of the agent receiving the investment
     * @param token Address of the newly launched agent token
     * @param vestingContract Address of the pre-created vesting contract with tokens
     * @return dealId The ID of the executed deal
     */
    function executeDeal(
        address agent,
        address token,
        address vestingContract
    ) external onlyOwner returns (uint256 dealId) {
        require(agent != address(0), "AgentDeal: agent is the zero address");
        require(token != address(0), "AgentDeal: token is the zero address");
        require(vestingContract != address(0), "AgentDeal: vesting contract is the zero address");

        // Verify vesting contract setup
        TokenVesting vesting = TokenVesting(vestingContract);
        require(address(vesting.token()) == token, "AgentDeal: vesting token mismatch");
        require(vesting.beneficiary() == distributor, "AgentDeal: vesting beneficiary mismatch");

        // Get token total supply to calculate expected 20%
        IERC20 agentToken = IERC20(token);
        uint256 totalSupply = agentToken.totalSupply();
        require(totalSupply > 0, "AgentDeal: token has no supply");
        
        uint256 expectedTokenAmount = (totalSupply * 20) / 100; // 20% of supply

        // Verify the vesting contract received exactly 20% of token supply
        uint256 vestingBalance = agentToken.balanceOf(vestingContract);
        require(
            vestingBalance >= expectedTokenAmount,
            "AgentDeal: insufficient tokens in vesting contract"
        );

        // Create deal record with Confirmed status (since tokens are already deposited)
        dealId = deals.length;
        deals.push(Deal({
            agent: agent,
            token: token,
            vestingContract: vestingContract,
            usdcAmount: USDC_AMOUNT,
            tokenAmount: expectedTokenAmount,
            timestamp: block.timestamp,
            status: DealStatus.Confirmed // Skip Created status since tokens are already there
        }));

        // Track deals by agent
        agentToDeals[agent].push(dealId);

        // Add token to distributor so LPs can claim
        ITokenDistributor(distributor).addToken(token, vestingContract);

        // Transfer USDC from this contract to agent
        usdc.safeTransfer(agent, USDC_AMOUNT);

        emit DealExecuted(
            dealId,
            agent,
            token,
            vestingContract,
            expectedTokenAmount,
            USDC_AMOUNT
        );
    }

    /**
     * @notice Create a vesting contract for a token (helper for launch contracts)
     * @dev Returns the vesting contract address so launch contracts know where to send tokens
     * @param token Address of the agent token
     * @param tokenAmount Amount of tokens that will be vested
     * @return vestingContract Address of the created vesting contract
     */
    function createVestingContract(
        address token,
        uint256 tokenAmount
    ) external onlyOwner returns (address vestingContract) {
        require(token != address(0), "AgentDeal: token is the zero address");
        require(tokenAmount > 0, "AgentDeal: token amount must be > 0");

        TokenVesting vesting = new TokenVesting(
            token,
            distributor,
            CLIFF_DURATION,
            VESTING_DURATION,
            tokenAmount
        );

        return address(vesting);
    }

    /**
     * @notice Fund the contract with USDC for future deals
     * @dev Owner can deposit USDC to the contract for atomic deal execution
     * @param amount Amount of USDC to deposit
     */
    function depositUSDC(uint256 amount) external onlyOwner {
        require(amount > 0, "AgentDeal: amount must be > 0");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw USDC from the contract
     * @dev Only owner can withdraw unused USDC
     * @param amount Amount of USDC to withdraw
     * @param to Address to send USDC to
     */
    function withdrawUSDC(uint256 amount, address to) external onlyOwner {
        require(amount > 0, "AgentDeal: amount must be > 0");
        require(to != address(0), "AgentDeal: to is the zero address");
        usdc.safeTransfer(to, amount);
    }

    /**
     * @notice Get USDC balance of this contract
     * @return balance USDC balance
     */
    function getUSDCBalance() external view returns (uint256 balance) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Get details of a specific deal
     * @param dealId ID of the deal to query
     * @return deal The deal struct
     */
    function getDeal(uint256 dealId) external view returns (Deal memory deal) {
        require(dealId < deals.length, "AgentDeal: invalid deal ID");
        return deals[dealId];
    }

    /**
     * @notice Get total number of deals
     * @return count Total number of deals created
     */
    function getDealsCount() external view returns (uint256 count) {
        return deals.length;
    }

    /**
     * @notice Get number of active deals (confirmed status)
     * @return count Number of active deals
     */
    function getActiveDealCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < deals.length; i++) {
            if (deals[i].status == DealStatus.Confirmed) {
                count++;
            }
        }
    }

    /**
     * @notice Get all deal IDs for a specific agent
     * @param agent Address of the agent
     * @return dealIds Array of deal IDs for the agent
     */
    function getDealsByAgent(address agent) external view returns (uint256[] memory dealIds) {
        return agentToDeals[agent];
    }

    /**
     * @notice Get all deals with pagination
     * @param offset Starting index
     * @param limit Maximum number of deals to return
     * @return paginatedDeals Array of deals
     */
    function getAllDeals(uint256 offset, uint256 limit) external view returns (Deal[] memory paginatedDeals) {
        require(offset < deals.length, "AgentDeal: offset out of bounds");
        
        uint256 end = offset + limit;
        if (end > deals.length) {
            end = deals.length;
        }
        
        paginatedDeals = new Deal[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            paginatedDeals[i - offset] = deals[i];
        }
    }
}