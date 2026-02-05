// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgentRegistry
 * @dev ERC-721 soulbound NFT for on-chain agent identity verification
 * @notice Agents must hold an identity NFT to submit pitches. Non-transferable except mint/burn.
 * @author Axiom Ventures
 */
contract AgentRegistry is ERC721, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice USDC token address (Base mainnet)
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    
    /// @notice Registration fee in USDC
    uint256 public registrationFee;
    
    /// @notice Next token ID to mint
    uint256 public nextTokenId = 1;
    
    /// @notice Mapping from agent address to their token ID (0 if not registered)
    mapping(address => uint256) public agentToTokenId;
    
    /// @notice Mapping from token ID to metadata URI
    mapping(uint256 => string) public tokenURIs;

    /// @dev Emitted when an agent registers and receives their identity NFT
    event AgentRegistered(
        uint256 indexed agentId,
        address indexed agent,
        string metadataURI
    );
    
    /// @dev Emitted when registration fee is updated
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    
    /// @dev Emitted when collected fees are withdrawn
    event FeesWithdrawn(uint256 amount, address recipient);

    /// @dev Agent already holds an identity NFT
    error AgentAlreadyRegistered();
    
    /// @dev Attempted transfer of soulbound token
    error TokenNotTransferable();
    
    /// @dev Empty metadata URI provided
    error EmptyMetadataURI();
    
    /// @dev Insufficient registration fee provided
    error InsufficientFee();

    /**
     * @notice Initialize the agent registry
     * @param initialOwner Address to set as owner (typically multisig)
     */
    constructor(address initialOwner) 
        ERC721("Axiom Agent Identity", "AXIOM-AGENT") 
        Ownable(initialOwner) 
    {
        registrationFee = 0; // Default to 0 for launch
    }

    /**
     * @notice Register an agent with payment of registration fee
     * @param metadataURI IPFS URI containing agent details
     * @return agentId The newly minted token ID
     */
    function registerAgent(string memory metadataURI) 
        external 
        nonReentrant 
        returns (uint256 agentId) 
    {
        if (bytes(metadataURI).length == 0) revert EmptyMetadataURI();
        if (agentToTokenId[msg.sender] != 0) revert AgentAlreadyRegistered();

        // Collect registration fee if required
        if (registrationFee > 0) {
            USDC.safeTransferFrom(msg.sender, address(this), registrationFee);
        }

        agentId = _mintAgentNFT(msg.sender, metadataURI);
    }

    /**
     * @notice Grant agent identity for free (owner only)
     * @param agent Address to grant identity to
     * @param metadataURI IPFS URI containing agent details
     * @return agentId The newly minted token ID
     */
    function grantIdentity(address agent, string memory metadataURI) 
        external 
        onlyOwner 
        returns (uint256 agentId) 
    {
        if (bytes(metadataURI).length == 0) revert EmptyMetadataURI();
        if (agentToTokenId[agent] != 0) revert AgentAlreadyRegistered();

        agentId = _mintAgentNFT(agent, metadataURI);
    }

    /**
     * @notice Check if an agent is registered
     * @param agent Address to check
     * @return True if agent holds an identity NFT
     */
    function isRegistered(address agent) external view returns (bool) {
        return agentToTokenId[agent] != 0;
    }

    /**
     * @notice Get agent's token ID
     * @param agent Address to query
     * @return Token ID owned by agent (0 if not registered)
     */
    function getAgentId(address agent) external view returns (uint256) {
        return agentToTokenId[agent];
    }

    /**
     * @notice Update registration fee (owner only)
     * @param newFee New registration fee in USDC
     */
    function setRegistrationFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = registrationFee;
        registrationFee = newFee;
        emit RegistrationFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Withdraw collected registration fees (owner only)
     * @param recipient Address to receive the fees
     */
    function withdrawFees(address recipient) external onlyOwner {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance > 0) {
            USDC.safeTransfer(recipient, balance);
            emit FeesWithdrawn(balance, recipient);
        }
    }

    /**
     * @notice Get total number of registered agents
     * @return Total supply of identity NFTs
     */
    function getTotalAgents() external view returns (uint256) {
        return nextTokenId - 1;
    }

    /**
     * @notice Get collected fees balance
     * @return Current USDC balance
     */
    function getFeesBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /**
     * @notice Override tokenURI to return stored metadata URI
     * @param tokenId Token ID to query
     * @return The metadata URI for the token
     */
    function tokenURI(uint256 tokenId) 
        public 
        view 
        override 
        returns (string memory) 
    {
        _requireOwned(tokenId);
        return tokenURIs[tokenId];
    }

    /**
     * @dev Override _update to make tokens soulbound (non-transferable)
     * Only allows minting (from = address(0)) and burning (to = address(0))
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        
        // Allow mint and burn, but not transfers
        if (from != address(0) && to != address(0)) {
            revert TokenNotTransferable();
        }

        // Update mapping when burning
        if (to == address(0)) {
            agentToTokenId[from] = 0;
        }

        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Internal function to mint agent NFT
     * @param agent Address to mint to
     * @param metadataURI IPFS URI for metadata
     * @return agentId The newly minted token ID
     */
    function _mintAgentNFT(address agent, string memory metadataURI) 
        internal 
        returns (uint256 agentId) 
    {
        agentId = nextTokenId++;
        agentToTokenId[agent] = agentId;
        tokenURIs[agentId] = metadataURI;
        
        _mint(agent, agentId);
        
        emit AgentRegistered(agentId, agent, metadataURI);
    }
}