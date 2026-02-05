// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {AgentRegistry} from "../v2/AgentRegistry.sol";
import {DDAttestation} from "../v2/DDAttestation.sol";
import {PitchRegistry} from "../PitchRegistry.sol";
import {AxiomVault} from "../AxiomVault.sol";
import {EscrowFactoryV2} from "./EscrowFactoryV2.sol";

/**
 * @title InvestmentRouterV2
 * @dev V2.1 - Enhanced orchestration layer with direct escrow creation and efficient lookups
 * @notice Provides seamless pipeline from agent registration to funded investments
 * @author Axiom Ventures
 */
contract InvestmentRouterV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice USDC token address (Base mainnet)
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice Contract dependencies
    AgentRegistry public immutable agentRegistry;
    DDAttestation public immutable ddAttestation;
    PitchRegistry public immutable pitchRegistry;
    AxiomVault public immutable axiomVault;
    EscrowFactoryV2 public immutable escrowFactory;

    /// @notice Minimum DD score required for funding (0-100)
    uint256 public minDDScore = 70;

    /// @notice Investment record structure
    struct InvestmentRecord {
        uint256 agentId;           // Agent NFT ID
        address escrowAddress;     // Deployed escrow contract
        uint256 fundedAt;          // Timestamp when funded
    }

    /// @notice Mapping from pitch ID to agent ID
    mapping(uint256 => uint256) public pitchToAgent;
    
    /// @notice Mapping from agent ID to their pitch IDs (for O(1) lookups)
    mapping(uint256 => uint256[]) public agentPitchIds;
    
    /// @notice Mapping from pitch ID to investment record
    mapping(uint256 => InvestmentRecord) public investments;
    
    /// @notice Array of all funded pitch IDs
    uint256[] public fundedPitches;
    
    /// @notice Mapping to check if pitch is funded
    mapping(uint256 => bool) public isPitchFunded;

    /// @dev Emitted when a pitch is submitted via router
    event PitchSubmitted(
        uint256 indexed pitchId,
        uint256 indexed agentId,
        address indexed submitter
    );
    
    /// @dev Emitted when an investment is funded
    event InvestmentFunded(
        uint256 indexed pitchId,
        uint256 indexed agentId,
        address indexed escrowAddress,
        uint256 amount
    );

    /// @dev Emitted when an escrow is linked to a pitch (legacy compatibility)
    event EscrowLinked(
        uint256 indexed pitchId,
        address indexed escrowAddress
    );

    /// @dev Emitted when minimum DD score is updated
    event MinDDScoreUpdated(uint256 oldScore, uint256 newScore);

    /// @dev Agent is not registered (doesn't hold identity NFT)
    error AgentNotRegistered();
    
    /// @dev Caller doesn't own the specified agent ID
    error NotAgentOwner();
    
    /// @dev Pitch status is not approved for funding
    error PitchNotApproved();
    
    /// @dev DD attestation doesn't exist for this pitch
    error NoAttestationFound();
    
    /// @dev DD score doesn't meet minimum requirement
    error InsufficientDDScore();
    
    /// @dev Pitch is already funded
    error PitchAlreadyFunded();
    
    /// @dev Invalid escrow creation parameters
    error InvalidEscrowParams();
    
    /// @dev Pitch doesn't exist
    error PitchNotFound();
    
    /// @dev Invalid DD score (must be 0-100)
    error InvalidScore();

    /**
     * @notice Initialize the investment router V2
     * @param _agentRegistry Agent registry contract
     * @param _ddAttestation DD attestation contract
     * @param _pitchRegistry Pitch registry contract (V1)
     * @param _axiomVault Axiom vault contract (V1)
     * @param _escrowFactory Escrow factory contract (V2.1)
     * @param initialOwner Address to set as owner (typically multisig)
     */
    constructor(
        AgentRegistry _agentRegistry,
        DDAttestation _ddAttestation,
        PitchRegistry _pitchRegistry,
        AxiomVault _axiomVault,
        EscrowFactoryV2 _escrowFactory,
        address initialOwner
    ) Ownable(initialOwner) {
        agentRegistry = _agentRegistry;
        ddAttestation = _ddAttestation;
        pitchRegistry = _pitchRegistry;
        axiomVault = _axiomVault;
        escrowFactory = _escrowFactory;
    }

    /**
     * @notice Submit a pitch through the router (requires agent identity)
     * @param agentId Agent NFT ID (caller must own this NFT)
     * @param ipfsHash IPFS hash containing detailed pitch data
     * @param title Brief title of the pitch
     * @param description Short description
     * @param fundingRequest Amount of funding requested (in USDC)
     * @return pitchId The ID of the submitted pitch
     */
    function submitPitch(
        uint256 agentId,
        string memory ipfsHash,
        string memory title,
        string memory description,
        uint256 fundingRequest
    ) external nonReentrant returns (uint256 pitchId) {
        // Verify caller owns the agent ID NFT
        if (agentRegistry.ownerOf(agentId) != msg.sender) revert NotAgentOwner();

        // Submit pitch through registry (handles fee collection)
        pitchId = pitchRegistry.submitPitch(
            ipfsHash,
            title,
            description,
            fundingRequest
        );

        // Record agent ID mapping
        pitchToAgent[pitchId] = agentId;
        
        // Add to agent's pitch list for efficient lookups
        agentPitchIds[agentId].push(pitchId);

        emit PitchSubmitted(pitchId, agentId, msg.sender);
    }

    /**
     * @notice Fund a pitch by creating an escrow directly
     * @param pitchId The pitch ID to fund
     * @param deadline Deadline for milestone completion
     * @param amounts Array of milestone amounts (in USDC)
     * @param descriptions Array of milestone descriptions
     * @dev Only owner can call this. Safe must separately fund the escrow after creation.
     */
    function fundPitch(
        uint256 pitchId,
        uint256 deadline,
        uint256[] memory amounts,
        string[] memory descriptions
    ) external onlyOwner nonReentrant {
        // Verify pitch exists
        if (!pitchRegistry.pitchExists(pitchId)) revert PitchNotFound();
        
        // Verify pitch is not already funded
        if (isPitchFunded[pitchId]) revert PitchAlreadyFunded();
        
        // Get pitch data
        PitchRegistry.Pitch memory pitch = pitchRegistry.getPitch(pitchId);
        
        // Verify pitch is approved
        if (pitch.status != PitchRegistry.PitchStatus.Approved) {
            revert PitchNotApproved();
        }
        
        // Verify agent is registered (defensive check)
        uint256 agentId = pitchToAgent[pitchId];
        if (agentId == 0) revert AgentNotRegistered();
        
        // Verify DD attestation exists and score meets minimum
        if (!ddAttestation.hasAttestation(pitchId)) revert NoAttestationFound();
        
        uint256 ddScore = ddAttestation.getScore(pitchId);
        if (ddScore < minDDScore) revert InsufficientDDScore();
        
        // Validate escrow parameters
        if (amounts.length == 0 || amounts.length != descriptions.length) {
            revert InvalidEscrowParams();
        }
        
        // Calculate total amount and validate
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) revert InvalidEscrowParams();
            totalAmount += amounts[i];
        }
        
        // Create escrow via factory (escrow will be owned by Safe)
        address escrowAddress = escrowFactory.createEscrow(
            pitch.submitter,  // recipient
            deadline,
            amounts,
            descriptions
        );

        // Note: Pitch status should be updated to Funded by the Safe owner separately
        // The router only validates and creates the escrow

        // Record investment
        investments[pitchId] = InvestmentRecord({
            agentId: agentId,
            escrowAddress: escrowAddress,
            fundedAt: block.timestamp
        });
        
        isPitchFunded[pitchId] = true;
        fundedPitches.push(pitchId);

        emit InvestmentFunded(pitchId, agentId, escrowAddress, totalAmount);
        emit EscrowLinked(pitchId, escrowAddress); // Legacy compatibility
    }

    /**
     * @notice Update minimum DD score requirement
     * @param newMinScore New minimum score (0-100)
     */
    function setMinDDScore(uint256 newMinScore) external onlyOwner {
        if (newMinScore > 100) revert InvalidScore();
        
        uint256 oldScore = minDDScore;
        minDDScore = newMinScore;
        
        emit MinDDScoreUpdated(oldScore, newMinScore);
    }

    /**
     * @notice Get pitches submitted by an agent (O(1) lookup)
     * @param agentId The agent NFT ID
     * @return pitchIds Array of pitch IDs submitted by this agent
     */
    function getAgentPitches(uint256 agentId) 
        external 
        view 
        returns (uint256[] memory pitchIds) 
    {
        return agentPitchIds[agentId];
    }

    /**
     * @notice Get complete investment audit trail for a pitch
     * @param pitchId The pitch ID to query
     * @return investment Complete investment details
     */
    function getInvestment(uint256 pitchId) 
        external 
        view 
        returns (
            InvestmentRecord memory investment,
            PitchRegistry.Pitch memory pitch,
            DDAttestation.Attestation memory attestation,
            address agentAddress
        ) 
    {
        if (!isPitchFunded[pitchId]) revert PitchNotFound();
        
        investment = investments[pitchId];
        pitch = pitchRegistry.getPitch(pitchId);
        
        // Get attestation if it exists
        if (ddAttestation.hasAttestation(pitchId)) {
            attestation = ddAttestation.getAttestation(pitchId);
        }
        
        // Get agent address from NFT
        agentAddress = agentRegistry.ownerOf(investment.agentId);
    }

    /**
     * @notice Get agent ID for a pitch
     * @param pitchId The pitch ID to query
     * @return agentId The agent NFT ID (0 if not submitted via router)
     */
    function getPitchAgent(uint256 pitchId) external view returns (uint256 agentId) {
        return pitchToAgent[pitchId];
    }

    /**
     * @notice Check if agent submitted a specific pitch
     * @param pitchId The pitch ID to check
     * @param agent The agent address to check
     * @return True if agent submitted this pitch
     */
    function didAgentSubmitPitch(uint256 pitchId, address agent) 
        external 
        view 
        returns (bool) 
    {
        uint256 agentId = pitchToAgent[pitchId];
        if (agentId == 0) return false; // Not submitted via router
        
        try agentRegistry.ownerOf(agentId) returns (address owner) {
            return owner == agent;
        } catch {
            return false; // NFT doesn't exist
        }
    }

    /**
     * @notice Get all funded pitch IDs
     * @return Array of funded pitch IDs
     */
    function getAllFundedPitches() external view returns (uint256[] memory) {
        return fundedPitches;
    }

    /**
     * @notice Get number of funded investments
     * @return Total count of funded pitches
     */
    function getFundedPitchCount() external view returns (uint256) {
        return fundedPitches.length;
    }

    /**
     * @notice Get funded pitches in a range
     * @param start Start index (inclusive)
     * @param end End index (exclusive)
     * @return pitchIds Array of pitch IDs in range
     */
    function getFundedPitchRange(uint256 start, uint256 end) 
        external 
        view 
        returns (uint256[] memory pitchIds) 
    {
        require(start < end && end <= fundedPitches.length, "Invalid range");
        
        pitchIds = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            pitchIds[i - start] = fundedPitches[i];
        }
    }

    /**
     * @notice Get investment record for a pitch
     * @param pitchId The pitch ID to query
     * @return investment The investment record
     */
    function getInvestmentRecord(uint256 pitchId) 
        external 
        view 
        returns (InvestmentRecord memory investment) 
    {
        if (!isPitchFunded[pitchId]) revert PitchNotFound();
        return investments[pitchId];
    }
}