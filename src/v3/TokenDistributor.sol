// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TokenVesting} from "./TokenVesting.sol";

/**
 * @title TokenDistributor
 * @dev Distributes vested agent tokens to vault LPs pro-rata based on their vault share percentage.
 * @notice This contract is the beneficiary of all TokenVesting contracts and handles distribution to LPs.
 */
contract TokenDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The AxiomVault contract (ERC-4626) 
    IERC4626 public immutable vault;
    
    /// @notice Mapping from token address to vesting contract address
    mapping(address => address) public tokenToVesting;
    
    /// @notice Mapping from token to user to amount claimed
    mapping(address => mapping(address => uint256)) public claimed;
    
    /// @notice Mapping from token to total amount received by distributor
    mapping(address => uint256) public totalReceived;
    
    /// @notice Array of all registered tokens
    address[] public tokens;
    
    /// @notice Mapping to check if a token is registered
    mapping(address => bool) public isTokenRegistered;

    /// @notice Emitted when tokens are claimed by an LP
    event TokensClaimed(address indexed user, address indexed token, uint256 amount);
    
    /// @notice Emitted when tokens are released from a vesting contract
    event TokensReleased(address indexed vestingContract, address indexed token, uint256 amount);
    
    /// @notice Emitted when a new token is registered
    event TokenAdded(address indexed token, address indexed vestingContract);

    /**
     * @dev Creates the TokenDistributor contract
     * @param _vault Address of the AxiomVault contract
     * @param _owner Address that will own this contract (Safe multisig)
     */
    constructor(address _vault, address _owner) Ownable(_owner) {
        require(_vault != address(0), "TokenDistributor: vault is the zero address");
        require(_owner != address(0), "TokenDistributor: owner is the zero address");
        
        vault = IERC4626(_vault);
    }

    /**
     * @notice Add a new agent token and its vesting contract
     * @dev Only callable by owner (Safe multisig)
     * @param token Address of the agent token
     * @param vestingContract Address of the TokenVesting contract for this token
     */
    function addToken(address token, address vestingContract) external onlyOwner {
        require(token != address(0), "TokenDistributor: token is the zero address");
        require(vestingContract != address(0), "TokenDistributor: vesting contract is the zero address");
        require(!isTokenRegistered[token], "TokenDistributor: token already registered");
        
        // Verify the vesting contract is for this token
        TokenVesting vesting = TokenVesting(vestingContract);
        require(address(vesting.token()) == token, "TokenDistributor: token mismatch");
        require(vesting.beneficiary() == address(this), "TokenDistributor: beneficiary mismatch");
        
        tokenToVesting[token] = vestingContract;
        isTokenRegistered[token] = true;
        tokens.push(token);
        
        emit TokenAdded(token, vestingContract);
    }

    /**
     * @notice Release vested tokens from a TokenVesting contract to this distributor
     * @dev Can be called by anyone. Pulls vested tokens from vesting contract.
     * @param vestingContract Address of the TokenVesting contract to release from
     */
    function release(address vestingContract) external {
        TokenVesting vesting = TokenVesting(vestingContract);
        require(vesting.beneficiary() == address(this), "TokenDistributor: not beneficiary");
        
        uint256 releasableBefore = vesting.releasable();
        require(releasableBefore > 0, "TokenDistributor: no tokens to release");
        
        vesting.release();
        
        // Track total received for this token
        address token = address(vesting.token());
        totalReceived[token] += releasableBefore;
        
        emit TokensReleased(vestingContract, token, releasableBefore);
    }

    /**
     * @notice Claim pro-rata share of a specific agent token
     * @dev LP claims their share based on vault position at time of claim
     * @param token Address of the agent token to claim
     */
    function claim(address token) external nonReentrant {
        require(isTokenRegistered[token], "TokenDistributor: token not registered");
        
        uint256 claimableAmount = claimable(token, msg.sender);
        require(claimableAmount > 0, "TokenDistributor: no tokens to claim");
        
        claimed[token][msg.sender] += claimableAmount;
        IERC20(token).safeTransfer(msg.sender, claimableAmount);
        
        emit TokensClaimed(msg.sender, token, claimableAmount);
    }

    /**
     * @notice Batch claim multiple agent tokens
     * @dev Allows LP to claim from multiple tokens in a single transaction
     * @param tokenList Array of token addresses to claim
     */
    function claimMultiple(address[] calldata tokenList) external {
        for (uint256 i = 0; i < tokenList.length; i++) {
            uint256 claimableAmount = claimable(tokenList[i], msg.sender);
            if (claimableAmount > 0) {
                claimed[tokenList[i]][msg.sender] += claimableAmount;
                IERC20(tokenList[i]).safeTransfer(msg.sender, claimableAmount);
                emit TokensClaimed(msg.sender, tokenList[i], claimableAmount);
            }
        }
    }

    /**
     * @notice Calculate how much of a token a user can claim
     * @param token Address of the agent token
     * @param user Address of the LP
     * @return amount Amount of tokens the user can claim
     */
    function claimable(address token, address user) public view returns (uint256 amount) {
        if (!isTokenRegistered[token]) {
            return 0;
        }
        
        uint256 userShares = vault.balanceOf(user);
        if (userShares == 0) {
            return 0;
        }
        
        uint256 totalShares = vault.totalSupply();
        if (totalShares == 0) {
            return 0;
        }
        
        uint256 totalTokensReceived = totalReceived[token];
        uint256 userTotalShare = (totalTokensReceived * userShares) / totalShares;
        uint256 alreadyClaimed = claimed[token][user];
        
        if (userTotalShare > alreadyClaimed) {
            amount = userTotalShare - alreadyClaimed;
        }
    }

    /**
     * @notice Get the total number of registered tokens
     * @return count Number of registered tokens
     */
    function getTokenCount() external view returns (uint256 count) {
        return tokens.length;
    }

    /**
     * @notice Get all registered token addresses
     * @return tokenList Array of all registered token addresses
     */
    function getAllTokens() external view returns (address[] memory tokenList) {
        return tokens;
    }

    /**
     * @notice Get token addresses with pagination
     * @param offset Starting index
     * @param limit Maximum number of tokens to return
     * @return paginatedTokens Array of token addresses
     */
    function getTokens(uint256 offset, uint256 limit) external view returns (address[] memory paginatedTokens) {
        require(offset < tokens.length, "TokenDistributor: offset out of bounds");
        
        uint256 end = offset + limit;
        if (end > tokens.length) {
            end = tokens.length;
        }
        
        paginatedTokens = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            paginatedTokens[i - offset] = tokens[i];
        }
    }

    /**
     * @notice Get claimable amounts for a user across multiple tokens
     * @param user Address of the LP
     * @param tokenList Array of token addresses to check
     * @return amounts Array of claimable amounts corresponding to tokenList
     */
    function getClaimableAmounts(
        address user, 
        address[] calldata tokenList
    ) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](tokenList.length);
        for (uint256 i = 0; i < tokenList.length; i++) {
            amounts[i] = claimable(tokenList[i], user);
        }
    }

    /**
     * @notice Get user's vault share percentage (in basis points, 10000 = 100%)
     * @param user Address of the LP
     * @return sharePercentage User's share percentage in basis points
     */
    function getUserVaultSharePercentage(address user) external view returns (uint256 sharePercentage) {
        uint256 userShares = vault.balanceOf(user);
        uint256 totalShares = vault.totalSupply();
        
        if (totalShares == 0) {
            return 0;
        }
        
        sharePercentage = (userShares * 10000) / totalShares;
    }
}