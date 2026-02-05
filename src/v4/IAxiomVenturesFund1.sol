// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAxiomVenturesFund1
 * @notice Interface for Axiom Ventures Fund 1 LP slips
 */
interface IAxiomVenturesFund1 {
    // Events
    event Deposited(address indexed depositor, uint256 count, uint256 firstSlipId);
    event FundManagerSlipMinted(uint256 indexed slipId);
    event TokensClaimedFromClanker(address indexed token, uint256 amount);
    event TokenClaimed(uint256 indexed slipId, address indexed token, uint256 amount, uint256 fee);
    event DepositsOpenChanged(bool open);
    event ClankerVaultUpdated(address indexed oldVault, address indexed newVault);
    event MetadataAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event AgentTokenAdded(address indexed token);
    event UpgradesPermanentlyLocked();

    // Errors
    error OnlySafe();
    error OnlyMetadataAdmin();
    error DepositsNotOpen();
    error ExceedsMaxPublicSlips();
    error InvalidCount();
    error NotSlipOwner();
    error NothingToClaim();
    error UpgradesAreLocked();
    error ZeroAddress();
    error TokenAlreadyTracked();

    // Deposit
    function deposit(uint256 count) external;

    // Clanker claims
    function claimFromClanker(address token) external;
    function claimAllFromClanker() external;

    // LP claims
    function claimSingleToken(uint256 slipId, address token) external;
    function claimAllTokens(uint256 slipId) external;

    // View functions
    function getAgentTokens() external view returns (address[] memory);
    function getAgentTokenCount() external view returns (uint256);
    function getClaimable(uint256 slipId) external view returns (address[] memory tokens, uint256[] memory amounts);
    function getClaimableAmount(uint256 slipId, address token) external view returns (uint256);
    function owner() external view returns (address);
    function contractURI() external view returns (string memory);

    // State getters
    function safe() external view returns (address);
    function metadataAdmin() external view returns (address);
    function clankerVault() external view returns (address);
    function depositsOpen() external view returns (bool);
    function upgradesLocked() external view returns (bool);
    function totalMinted() external view returns (uint256);
    function publicSlipsMinted() external view returns (uint256);
    function fundManagerSlipsMinted() external view returns (uint256);
    function isAgentToken(address token) external view returns (bool);
    function totalReceived(address token) external view returns (uint256);
    function claimed(uint256 slipId, address token) external view returns (uint256);

    // Admin functions
    function setClankerVault(address vault) external;
    function setMetadataAdmin(address admin) external;
    function setDepositsOpen(bool open) external;
    function setContractURI(string calldata uri) external;
    function addAgentToken(address token) external;
    function lockUpgrades() external;
}
