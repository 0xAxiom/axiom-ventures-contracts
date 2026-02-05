// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

/**
 * @title AxiomVenturesFund1
 * @notice ERC-721 LP slips representing 1/200th ownership in Axiom Ventures Fund 1
 * @dev UUPS upgradeable, trading locked until sold out, 2.5% royalties
 * @author Axiom Ventures
 * 
 * Fund 1: $200K raise, 20 AI agents, $100K implied FDV entry
 * 
 * Fee Structure:
 * - 1% deposit fee → Safe (for $AXIOM burns)
 * - 1% distribution fee → Safe (on token claims)
 * - 2.5% royalty → Safe (on secondary sales, 50% for burns)
 */

interface IClankerVault {
    function claim(address token) external;
}

contract AxiomVenturesFund1 is 
    Initializable,
    ERC721Upgradeable,
    ERC2981Upgradeable,
    UUPSUpgradeable,
    ReentrancyGuard 
{
    using SafeERC20 for IERC20;
    using LibString for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC on Base mainnet
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    
    /// @notice Price per LP slip in USDC (6 decimals) - $1,010
    uint256 public constant SLIP_PRICE = 1010e6;
    
    /// @notice Maximum slips in fund
    uint256 public constant MAX_SUPPLY = 200;
    
    /// @notice Deposit fee in basis points (1% = 100)
    uint256 public constant DEPOSIT_FEE_BPS = 100;
    
    /// @notice Distribution fee in basis points (1% = 100)
    uint256 public constant DISTRIBUTION_FEE_BPS = 100;
    
    /// @notice Royalty fee in basis points (2.5% = 250)
    uint96 public constant ROYALTY_BPS = 250;
    
    /// @notice Precision for accumulated dividends
    uint256 public constant PRECISION = 1e18;
    
    /// @notice Maximum tokens to process in one batch
    uint256 public constant MAX_BATCH_SIZE = 50;
    
    /// @notice Maximum slips per wallet (10% of fund)
    uint256 public constant MAX_PER_WALLET = 20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Multi-sig safe for funds and critical operations
    address public safe;
    
    /// @notice Admin for OpenSea collection management
    address public metadataAdmin;
    
    /// @notice Clanker vault address (updateable)
    address public clankerVault;
    
    /// @notice Collection metadata URI
    string public contractMetadataURI;
    
    /// @notice Whether deposits are currently open
    bool public depositsOpen;
    
    /// @notice Whether the contract is paused
    bool public paused;
    
    /// @notice Whether trading is enabled (auto-enabled on sellout)
    bool public tradingEnabled;
    
    /// @notice Whether upgrades have been permanently locked
    bool public upgradesLocked;
    
    /// @notice Total slips minted
    uint256 public totalMinted;
    
    /// @notice Array of agent token addresses
    address[] public agentTokens;
    
    /// @notice Whether an address is a tracked agent token
    mapping(address => bool) public isAgentToken;
    
    /// @notice Accumulated dividends per share (scaled by PRECISION)
    mapping(address => uint256) public accumulatedPerShare;
    
    /// @notice Dividend debt per slip per token (scaled by PRECISION)
    mapping(uint256 => mapping(address => uint256)) public rewardDebt;
    
    /// @notice Total tokens ever received per agent token
    mapping(address => uint256) public totalReceived;
    
    /// @notice Total tokens claimed per slip per agent token
    mapping(uint256 => mapping(address => uint256)) public totalClaimed;
    
    /// @notice Slips minted per wallet (for max per wallet enforcement)
    mapping(address => uint256) public slipsMintedBy;

    /// @notice Storage gap for future upgrades
    uint256[29] private __gap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed depositor, uint256 count, uint256 firstSlipId, uint256 feeAmount);
    event TokensClaimedFromClanker(address indexed token, uint256 amount);
    event TokenClaimed(uint256 indexed slipId, address indexed token, uint256 amount, uint256 fee);
    event DepositsOpenChanged(bool open);
    event PausedChanged(bool paused);
    event TradingEnabled();
    event ClankerVaultUpdated(address indexed oldVault, address indexed newVault);
    event MetadataAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event AgentTokenAdded(address indexed token);
    event UpgradesPermanentlyLocked();
    event ClankerClaimFailed(address indexed token, bytes reason);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlySafe();
    error OnlyMetadataAdmin();
    error DepositsNotOpen();
    error ContractPaused();
    error TradingNotEnabled();
    error SoldOut();
    error ExceedsMaxPerWallet();
    error InvalidCount();
    error NotSlipOwner();
    error NothingToClaim();
    error UpgradesAreLocked();
    error ZeroAddress();
    error TokenAlreadyTracked();
    error BatchTooLarge();
    error InvalidBatchRange();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySafe() {
        if (msg.sender != safe) revert OnlySafe();
        _;
    }

    modifier onlyMetadataAdmin() {
        if (msg.sender != metadataAdmin) revert OnlyMetadataAdmin();
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the contract
     * @param _safe Multi-sig safe address
     * @param _metadataAdmin OpenSea admin address
     * @param _clankerVault Clanker vault address
     */
    function initialize(
        address _safe,
        address _metadataAdmin,
        address _clankerVault
    ) external initializer {
        if (_safe == address(0) || _metadataAdmin == address(0) || _clankerVault == address(0)) {
            revert ZeroAddress();
        }

        __ERC721_init("Axiom Ventures Fund 1", "AVF1");
        __ERC2981_init();

        safe = _safe;
        metadataAdmin = _metadataAdmin;
        clankerVault = _clankerVault;
        depositsOpen = true;
        
        // Set default royalty (2.5% to Safe)
        _setDefaultRoyalty(_safe, ROYALTY_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit USDC to receive LP slips
     * @param count Number of slips to purchase
     */
    function deposit(uint256 count) external nonReentrant whenNotPaused {
        if (!depositsOpen) revert DepositsNotOpen();
        if (count == 0) revert InvalidCount();
        if (totalMinted + count > MAX_SUPPLY) revert SoldOut();
        if (slipsMintedBy[msg.sender] + count > MAX_PER_WALLET) revert ExceedsMaxPerWallet();

        uint256 grossAmount = count * SLIP_PRICE;
        uint256 feeAmount = (grossAmount * DEPOSIT_FEE_BPS) / 10000;
        
        // Transfer full amount to safe (includes 1% fee for burns)
        USDC.safeTransferFrom(msg.sender, safe, grossAmount);

        uint256 firstSlipId = totalMinted;

        for (uint256 i = 0; i < count;) {
            _safeMintSlip(msg.sender);
            unchecked { ++i; }
        }
        
        slipsMintedBy[msg.sender] += count;

        emit Deposited(msg.sender, count, firstSlipId, feeAmount);
        
        // Auto-enable trading when sold out
        if (totalMinted == MAX_SUPPLY && !tradingEnabled) {
            tradingEnabled = true;
            emit TradingEnabled();
        }
    }
    
    /**
     * @dev Internal mint that initializes reward debt for existing tokens
     */
    function _safeMintSlip(address to) internal {
        uint256 slipId = totalMinted;
        _mint(to, slipId);
        totalMinted++;
        
        // Initialize reward debt for all existing tokens
        uint256 tokenCount = agentTokens.length;
        for (uint256 i = 0; i < tokenCount;) {
            address token = agentTokens[i];
            rewardDebt[slipId][token] = accumulatedPerShare[token];
            unchecked { ++i; }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           TRANSFER OVERRIDE
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @dev Override to enforce trading lock until sold out
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        
        // Allow minting (from == 0) always
        // Block transfers if trading not enabled (except Safe can always transfer)
        if (from != address(0) && !tradingEnabled && from != safe) {
            revert TradingNotEnabled();
        }
        
        return super._update(to, tokenId, auth);
    }

    /*//////////////////////////////////////////////////////////////
                         CLANKER CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim vested tokens from Clanker vault (permissionless)
     * @param token Agent token address to claim
     */
    function claimFromClanker(address token) external nonReentrant whenNotPaused {
        _claimFromClanker(token);
    }

    /**
     * @notice Claim batch of agent tokens from Clanker vault
     * @param startIdx Start index in agentTokens array
     * @param count Number of tokens to claim
     */
    function claimFromClankerBatch(uint256 startIdx, uint256 count) external nonReentrant whenNotPaused {
        if (count > MAX_BATCH_SIZE) revert BatchTooLarge();
        
        uint256 length = agentTokens.length;
        uint256 endIdx = startIdx + count;
        if (endIdx > length) endIdx = length;
        if (startIdx >= length) revert InvalidBatchRange();
        
        for (uint256 i = startIdx; i < endIdx;) {
            _claimFromClanker(agentTokens[i]);
            unchecked { ++i; }
        }
    }

    /**
     * @dev Internal function to claim from Clanker using interface with try/catch
     */
    function _claimFromClanker(address token) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        
        // Use interface with try/catch for safety
        try IClankerVault(clankerVault).claim(token) {
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            uint256 received = balanceAfter - balanceBefore;
            
            if (received > 0) {
                totalReceived[token] += received;
                
                // Update accumulated dividends per share (scaled)
                accumulatedPerShare[token] += (received * PRECISION) / MAX_SUPPLY;
                
                // Track token if new
                if (!isAgentToken[token]) {
                    agentTokens.push(token);
                    isAgentToken[token] = true;
                    emit AgentTokenAdded(token);
                }
                
                emit TokensClaimedFromClanker(token, received);
            }
        } catch (bytes memory reason) {
            emit ClankerClaimFailed(token, reason);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          LP CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim a single token for a slip
     * @param slipId The slip NFT ID
     * @param token The agent token to claim
     */
    function claimSingleToken(uint256 slipId, address token) external nonReentrant whenNotPaused {
        if (ownerOf(slipId) != msg.sender) revert NotSlipOwner();
        _claimSingleToken(slipId, token, msg.sender);
    }

    /**
     * @notice Claim batch of tokens for a slip
     * @param slipId The slip NFT ID
     * @param startIdx Start index in agentTokens array
     * @param count Number of tokens to claim
     */
    function claimTokensBatch(uint256 slipId, uint256 startIdx, uint256 count) external nonReentrant whenNotPaused {
        if (ownerOf(slipId) != msg.sender) revert NotSlipOwner();
        if (count > MAX_BATCH_SIZE) revert BatchTooLarge();
        
        uint256 length = agentTokens.length;
        uint256 endIdx = startIdx + count;
        if (endIdx > length) endIdx = length;
        if (startIdx >= length) revert InvalidBatchRange();
        
        for (uint256 i = startIdx; i < endIdx;) {
            address token = agentTokens[i];
            uint256 pending = _pendingReward(slipId, token);
            if (pending > 0) {
                _claimSingleToken(slipId, token, msg.sender);
            }
            unchecked { ++i; }
        }
    }

    /**
     * @dev Internal function to claim a single token using dividend pattern
     */
    function _claimSingleToken(uint256 slipId, address token, address recipient) internal {
        uint256 accumulated = accumulatedPerShare[token];
        uint256 debt = rewardDebt[slipId][token];
        
        // Calculate pending reward (descale from PRECISION)
        uint256 pending = (accumulated - debt) / PRECISION;
        
        if (pending == 0) revert NothingToClaim();
        
        // Update debt to current accumulated (prevents double claiming)
        rewardDebt[slipId][token] = accumulated;
        
        // Track total claimed for this slip
        totalClaimed[slipId][token] += pending;
        
        // Calculate fee (1%)
        uint256 fee = (pending * DISTRIBUTION_FEE_BPS) / 10000;
        uint256 payout = pending - fee;
        
        // Transfer fee to safe
        if (fee > 0) {
            IERC20(token).safeTransfer(safe, fee);
        }
        
        // Transfer payout to recipient
        if (payout > 0) {
            IERC20(token).safeTransfer(recipient, payout);
        }
        
        emit TokenClaimed(slipId, token, payout, fee);
    }
    
    /**
     * @dev Calculate pending reward for a slip
     */
    function _pendingReward(uint256 slipId, address token) internal view returns (uint256) {
        uint256 accumulated = accumulatedPerShare[token];
        uint256 debt = rewardDebt[slipId][token];
        return (accumulated - debt) / PRECISION;
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get all tracked agent tokens
     */
    function getAgentTokens() external view returns (address[] memory) {
        return agentTokens;
    }

    /**
     * @notice Get number of agent tokens
     */
    function getAgentTokenCount() external view returns (uint256) {
        return agentTokens.length;
    }

    /**
     * @notice Get ALL claimable tokens for a slip (convenience function)
     * @param slipId The slip NFT ID
     * @return tokens Array of token addresses
     * @return amounts Array of pending amounts (after fee)
     */
    function getClaimableAll(uint256 slipId) external view returns (
        address[] memory tokens,
        uint256[] memory amounts
    ) {
        uint256 length = agentTokens.length;
        tokens = new address[](length);
        amounts = new uint256[](length);
        
        for (uint256 i = 0; i < length;) {
            address token = agentTokens[i];
            tokens[i] = token;
            
            uint256 pending = _pendingReward(slipId, token);
            uint256 fee = (pending * DISTRIBUTION_FEE_BPS) / 10000;
            amounts[i] = pending - fee;
            
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Get claim history for a slip (what has been claimed)
     * @param slipId The slip NFT ID
     * @return tokens Array of token addresses
     * @return amounts Array of total claimed amounts
     */
    function getClaimHistory(uint256 slipId) external view returns (
        address[] memory tokens,
        uint256[] memory amounts
    ) {
        uint256 length = agentTokens.length;
        tokens = new address[](length);
        amounts = new uint256[](length);
        
        for (uint256 i = 0; i < length;) {
            address token = agentTokens[i];
            tokens[i] = token;
            amounts[i] = totalClaimed[slipId][token];
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Get full status for a slip (for OpenSea buyers)
     * @param slipId The slip NFT ID
     * @return numPendingTokens Number of tokens with pending claims
     * @return numClaimedTokens Number of tokens with claimed history
     * @return totalAgentTokens Total number of agent tokens in fund
     */
    function getTokenStatus(uint256 slipId) external view returns (
        uint256 numPendingTokens,
        uint256 numClaimedTokens,
        uint256 totalAgentTokens
    ) {
        uint256 length = agentTokens.length;
        totalAgentTokens = length;
        
        for (uint256 i = 0; i < length;) {
            address token = agentTokens[i];
            
            if (_pendingReward(slipId, token) > 0) {
                numPendingTokens++;
            }
            if (totalClaimed[slipId][token] > 0) {
                numClaimedTokens++;
            }
            
            unchecked { ++i; }
        }
    }

    /**
     * @notice Get pending rewards for a slip across a batch of tokens
     * @param slipId The slip NFT ID
     * @param startIdx Start index
     * @param count Number of tokens
     * @return tokens Array of token addresses
     * @return amounts Array of pending amounts (after fee)
     */
    function getPendingBatch(uint256 slipId, uint256 startIdx, uint256 count) external view returns (
        address[] memory tokens,
        uint256[] memory amounts
    ) {
        uint256 length = agentTokens.length;
        uint256 endIdx = startIdx + count;
        if (endIdx > length) endIdx = length;
        
        uint256 batchSize = endIdx - startIdx;
        tokens = new address[](batchSize);
        amounts = new uint256[](batchSize);
        
        for (uint256 i = 0; i < batchSize;) {
            address token = agentTokens[startIdx + i];
            tokens[i] = token;
            
            uint256 pending = _pendingReward(slipId, token);
            uint256 fee = (pending * DISTRIBUTION_FEE_BPS) / 10000;
            amounts[i] = pending - fee;
            
            unchecked { ++i; }
        }
    }

    /**
     * @notice Get pending reward for a specific token
     * @param slipId The slip NFT ID
     * @param token The agent token address
     * @return Pending amount after fee
     */
    function getPending(uint256 slipId, address token) external view returns (uint256) {
        uint256 pending = _pendingReward(slipId, token);
        uint256 fee = (pending * DISTRIBUTION_FEE_BPS) / 10000;
        return pending - fee;
    }

    /**
     * @notice OpenSea looks for this to determine collection owner
     */
    function owner() public view returns (address) {
        return metadataAdmin;
    }

    /**
     * @notice Collection-level metadata for OpenSea
     */
    function contractURI() public view returns (string memory) {
        return contractMetadataURI;
    }
    
    /**
     * @notice ERC165 interface support
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC2981Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Token metadata with on-chain SVG
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        
        string memory svg = _generateSVG(tokenId);
        
        // Check claim status for metadata
        (uint256 numPending, uint256 numClaimed, ) = this.getTokenStatus(tokenId);
        
        string memory json = string(abi.encodePacked(
            '{"name":"Axiom Ventures Fund 1 #', tokenId.toString(),
            '","description":"LP slip representing 1/200th of Axiom Ventures Fund 1. Entitles holder to pro-rata share of 20 AI agent tokens at $100K implied FDV.',
            tradingEnabled ? '' : ' Trading locked until sold out.',
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '",',
            '"attributes":[',
                '{"trait_type":"Fund","value":"Fund 1"},',
                '{"trait_type":"Network","value":"Base"},',
                '{"trait_type":"Slip Price","value":"$1,010 USDC"},',
                '{"trait_type":"Total Supply","value":"200"},',
                '{"trait_type":"Entry FDV","value":"$100,000"},',
                '{"trait_type":"Pending Claims","value":"', numPending.toString(), '"},',
                '{"trait_type":"Claimed Tokens","value":"', numClaimed.toString(), '"},',
                '{"trait_type":"Trading","value":"', tradingEnabled ? 'Enabled' : 'Locked', '"}',
            ']}'
        ));
        
        return string(abi.encodePacked(
            'data:application/json;base64,',
            Base64.encode(bytes(json))
        ));
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update Clanker vault address
     */
    function setClankerVault(address _vault) external onlySafe {
        if (_vault == address(0)) revert ZeroAddress();
        emit ClankerVaultUpdated(clankerVault, _vault);
        clankerVault = _vault;
    }

    /**
     * @notice Update metadata admin
     */
    function setMetadataAdmin(address _admin) external onlySafe {
        if (_admin == address(0)) revert ZeroAddress();
        emit MetadataAdminUpdated(metadataAdmin, _admin);
        metadataAdmin = _admin;
    }

    /**
     * @notice Open or close deposits
     */
    function setDepositsOpen(bool _open) external onlySafe {
        depositsOpen = _open;
        emit DepositsOpenChanged(_open);
    }
    
    /**
     * @notice Pause or unpause the contract
     */
    function setPaused(bool _paused) external onlySafe {
        paused = _paused;
        emit PausedChanged(_paused);
    }
    
    /**
     * @notice Manually enable trading (Safe can enable early if needed)
     */
    function enableTrading() external onlySafe {
        if (!tradingEnabled) {
            tradingEnabled = true;
            emit TradingEnabled();
        }
    }

    /**
     * @notice Set collection metadata URI
     */
    function setContractURI(string calldata _uri) external onlyMetadataAdmin {
        contractMetadataURI = _uri;
    }

    /**
     * @notice Manually add an agent token (if needed)
     */
    function addAgentToken(address token) external onlySafe {
        if (token == address(0)) revert ZeroAddress();
        if (isAgentToken[token]) revert TokenAlreadyTracked();
        
        agentTokens.push(token);
        isAgentToken[token] = true;
        emit AgentTokenAdded(token);
    }

    /**
     * @notice Permanently lock upgrades (irreversible)
     */
    function lockUpgrades() external onlySafe {
        upgradesLocked = true;
        emit UpgradesPermanentlyLocked();
    }

    /*//////////////////////////////////////////////////////////////
                              UUPS
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address) internal override onlySafe {
        if (upgradesLocked) revert UpgradesAreLocked();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL SVG
    //////////////////////////////////////////////////////////////*/

    function _generateSVG(uint256 tokenId) internal view returns (string memory) {
        string memory slipNumber = _padNumber(tokenId, 3);
        string memory tradingStatus = tradingEnabled ? "TRADEABLE" : "LOCKED";
        string memory statusColor = tradingEnabled ? "#84cc16" : "#ef4444";
        
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 1500" width="1200" height="1500">',
            '<rect fill="#0a0a0a" width="1200" height="1500"/>',
            '<rect x="40" y="40" width="1120" height="1420" fill="none" stroke="#1a1a1a" stroke-width="2" rx="24"/>',
            '<rect x="60" y="60" width="1080" height="1380" fill="#0f0f0f" rx="20"/>',
            '<text fill="#e5e5e5" font-family="monospace" font-size="42" font-weight="600" x="100" y="140">AXIOM VENTURES</text>',
            '<text fill="#525252" font-family="monospace" font-size="28" x="100" y="185">Fund 1</text>',
            '<line x1="100" y1="240" x2="1100" y2="240" stroke="#1a1a1a" stroke-width="2"/>',
            '<text fill="#1a1a1a" font-family="monospace" font-size="280" font-weight="700" x="100" y="620">SLIP</text>',
            '<text fill="#84cc16" font-family="monospace" font-size="320" font-weight="700" x="180" y="1000">#', slipNumber, '</text>',
            '<line x1="100" y1="1120" x2="1100" y2="1120" stroke="#1a1a1a" stroke-width="2"/>',
            '<text fill="#737373" font-family="monospace" font-size="26" x="100" y="1180">1 of 200</text>',
            '<text fill="#737373" font-family="monospace" font-size="26" x="100" y="1225">$1,010 USDC</text>',
            '<text fill="#525252" font-family="monospace" font-size="26" text-anchor="end" x="1100" y="1180">$100K FDV Entry</text>',
            '<text fill="#525252" font-family="monospace" font-size="26" text-anchor="end" x="1100" y="1225">20 AI Agents</text>',
            '<rect x="100" y="1280" width="180" height="40" rx="8" fill="', statusColor, '" fill-opacity="0.15"/>',
            '<text fill="', statusColor, '" font-family="monospace" font-size="22" font-weight="600" x="120" y="1308">', tradingStatus, '</text>',
            '<circle cx="1050" cy="120" r="32" fill="none" stroke="#84cc16" stroke-width="2"/>',
            '<text fill="#84cc16" font-family="monospace" font-size="32" font-weight="700" text-anchor="middle" x="1050" y="132">A</text>',
            '</svg>'
        ));
    }

    function _padNumber(uint256 num, uint256 length) internal pure returns (string memory) {
        string memory numStr = num.toString();
        bytes memory numBytes = bytes(numStr);
        
        if (numBytes.length >= length) {
            return numStr;
        }
        
        bytes memory padded = new bytes(length);
        uint256 padding = length - numBytes.length;
        
        for (uint256 i = 0; i < padding;) {
            padded[i] = '0';
            unchecked { ++i; }
        }
        
        for (uint256 i = 0; i < numBytes.length;) {
            padded[padding + i] = numBytes[i];
            unchecked { ++i; }
        }
        
        return string(padded);
    }
}
