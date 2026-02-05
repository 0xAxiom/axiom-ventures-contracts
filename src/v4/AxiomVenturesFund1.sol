// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

/**
 * @title AxiomVenturesFund1
 * @notice ERC-721 LP slips representing 1/2000th ownership in Axiom Ventures Fund 1
 * @dev UUPS upgradeable, can be locked to become immutable
 * @author Axiom Ventures
 * 
 * AUDIT FIXES v2:
 * - C-1: Fixed precision loss using accumulated dividends pattern (scaled by 1e18)
 * - H-1: Using interface for Clanker calls with try/catch
 * - H-3: Added batch pagination for claims
 * - M-3: Added pause mechanism
 */

interface IClankerVault {
    function claim(address token) external;
}

contract AxiomVenturesFund1 is 
    Initializable,
    ERC721Upgradeable,
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
    
    /// @notice Price per LP slip in USDC (6 decimals)
    uint256 public constant SLIP_PRICE = 1000e6;
    
    /// @notice Maximum public slips available
    uint256 public constant MAX_PUBLIC_SLIPS = 1980;
    
    /// @notice Maximum fund manager slips (1%)
    uint256 public constant MAX_FM_SLIPS = 20;
    
    /// @notice Total slips in fund
    uint256 public constant TOTAL_SLIPS = 2000;
    
    /// @notice Distribution fee in basis points (1% = 100)
    uint256 public constant DISTRIBUTION_FEE_BPS = 100;
    
    /// @notice Precision for accumulated dividends
    uint256 public constant PRECISION = 1e18;
    
    /// @notice Maximum tokens to process in one batch
    uint256 public constant MAX_BATCH_SIZE = 50;

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
    
    /// @notice Whether upgrades have been permanently locked
    bool public upgradesLocked;
    
    /// @notice Total slips minted (public + FM)
    uint256 public totalMinted;
    
    /// @notice Public slips minted
    uint256 public publicSlipsMinted;
    
    /// @notice Fund manager slips minted
    uint256 public fundManagerSlipsMinted;
    
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

    /// @notice Storage gap for future upgrades
    uint256[35] private __gap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed depositor, uint256 count, uint256 firstSlipId);
    event FundManagerSlipMinted(uint256 indexed slipId);
    event TokensClaimedFromClanker(address indexed token, uint256 amount);
    event TokenClaimed(uint256 indexed slipId, address indexed token, uint256 amount, uint256 fee);
    event DepositsOpenChanged(bool open);
    event PausedChanged(bool paused);
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
    error ExceedsMaxPublicSlips();
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

        safe = _safe;
        metadataAdmin = _metadataAdmin;
        clankerVault = _clankerVault;
        depositsOpen = true;
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
        if (publicSlipsMinted + count > MAX_PUBLIC_SLIPS) revert ExceedsMaxPublicSlips();

        // Transfer USDC to safe
        USDC.safeTransferFrom(msg.sender, safe, count * SLIP_PRICE);

        uint256 firstSlipId = totalMinted;

        for (uint256 i = 0; i < count;) {
            // Mint to depositor
            _safeMintSlip(msg.sender);
            publicSlipsMinted++;

            // Every 99 public slips, mint 1 fund manager slip
            if (publicSlipsMinted % 99 == 0 && fundManagerSlipsMinted < MAX_FM_SLIPS) {
                _safeMintSlip(safe);
                emit FundManagerSlipMinted(totalMinted - 1);
                fundManagerSlipsMinted++;
            }

            unchecked { ++i; }
        }

        emit Deposited(msg.sender, count, firstSlipId);
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
                accumulatedPerShare[token] += (received * PRECISION) / TOTAL_SLIPS;
                
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
     * @notice Token metadata with on-chain SVG
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        
        string memory svg = _generateSVG(tokenId);
        
        string memory json = string(abi.encodePacked(
            '{"name":"Axiom Ventures Fund 1 #', tokenId.toString(),
            '","description":"LP slip representing 1/2000th of Axiom Ventures Fund 1. Entitles holder to pro-rata share of 100 AI agent tokens.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '",',
            '"attributes":[',
                '{"trait_type":"Fund","value":"Fund 1"},',
                '{"trait_type":"Network","value":"Base"},',
                '{"trait_type":"Slip Price","value":"$1,000 USDC"},',
                '{"trait_type":"Total Supply","value":"2000"}',
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

    function _generateSVG(uint256 tokenId) internal pure returns (string memory) {
        string memory slipNumber = _padNumber(tokenId, 4);
        
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 1500" width="1200" height="1500">',
            '<rect fill="#0a0a0a" width="1200" height="1500"/>',
            '<rect x="40" y="40" width="1120" height="1420" fill="none" stroke="#1a1a1a" stroke-width="2" rx="24"/>',
            '<rect x="60" y="60" width="1080" height="1380" fill="#0f0f0f" rx="20"/>',
            '<text fill="#e5e5e5" font-family="monospace" font-size="42" font-weight="600" x="100" y="140">AXIOM VENTURES</text>',
            '<text fill="#525252" font-family="monospace" font-size="28" x="100" y="185">Fund 1</text>',
            '<line x1="100" y1="240" x2="1100" y2="240" stroke="#1a1a1a" stroke-width="2"/>',
            '<text fill="#1a1a1a" font-family="monospace" font-size="280" font-weight="700" x="100" y="620">SLIP</text>',
            '<text fill="#84cc16" font-family="monospace" font-size="300" font-weight="700" x="140" y="980">#', slipNumber, '</text>',
            '<line x1="100" y1="1280" x2="1100" y2="1280" stroke="#1a1a1a" stroke-width="2"/>',
            '<text fill="#737373" font-family="monospace" font-size="26" x="100" y="1340">1 of 2,000</text>',
            '<text fill="#737373" font-family="monospace" font-size="26" x="100" y="1385">$1,000 USDC</text>',
            '<text fill="#525252" font-family="monospace" font-size="26" text-anchor="end" x="1100" y="1340">Seed Stage</text>',
            '<text fill="#525252" font-family="monospace" font-size="26" text-anchor="end" x="1100" y="1385">100 AI Agents</text>',
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
