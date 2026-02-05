// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {AgentRegistry} from "./AgentRegistry.sol";
import {DDAttestation} from "./DDAttestation.sol";
import {PitchRegistry} from "../PitchRegistry.sol";
import {AxiomVault} from "../AxiomVault.sol";
import {EscrowFactory} from "../EscrowFactory.sol";

/**
 * @title InvestmentRouter
 * @dev Orchestration layer connecting agent identity, pitch submission, DD attestation, and investment
 * @notice Provides seamless pipeline from agent registration to funded investments
 * @author Axiom Ventures
 */
contract InvestmentRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice USDC token address (Base mainnet)
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice Contract dependencies
    AgentRegistry public immutable agentRegistry;
    DDAttestation public immutable ddAttestation;
    PitchRegistry public immutable pitchRegistry;
    AxiomVault public immutable axiomVault;
    EscrowFactory public immutable escrowFactory;

    /// @notice Investment record structure
    struct InvestmentRecord {
        uint256 agentId;           // Agent NFT ID
        address escrowAddress;     // Deployed escrow contract
        uint256 fundedAt;          // Timestamp when funded
    }

    /// @notice Mapping from pitch ID to agent ID
    mapping(uint256 => uint256) public pitchToAgent;
    
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
    
    /// @dev Emitted when an escrow is linked to a pitch
    event InvestmentLinked(
        uint256 indexed pitchId,
        address indexed escrowAddress
    );

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
    
    /// @dev Escrow address is not valid (not from factory)
    error InvalidEscrowAddress();
    
    /// @dev Pitch doesn't exist
    error PitchNotFound();
    
    /// @dev Pitch status is not valid for escrow linking
    error InvalidPitchStatus();

    /**
     * @notice Initialize the investment router
     * @param _agentRegistry Agent registry contract
     * @param _ddAttestation DD attestation contract
     * @param _pitchRegistry Pitch registry contract (V1)
     * @param _axiomVault Axiom vault contract (V1)
     * @param _escrowFactory Escrow factory contract (V1)
     * @param initialOwner Address to set as owner (typically multisig)
     */
    constructor(
        AgentRegistry _agentRegistry,
        DDAttestation _ddAttestation,
        PitchRegistry _pitchRegistry,
        AxiomVault _axiomVault,
        EscrowFactory _escrowFactory,
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

        emit PitchSubmitted(pitchId, agentId, msg.sender);
    }

    /**
     * @notice Link an escrow to a funded pitch (owner only)
     * @param pitchId The pitch ID to link
     * @param escrowAddress The escrow contract address
     */
    function linkEscrow(
        uint256 pitchId, 
        address escrowAddress
    ) external onlyOwner {
        // Verify pitch exists
        if (!pitchRegistry.pitchExists(pitchId)) revert PitchNotFound();
        
        // Verify pitch is not already funded
        if (isPitchFunded[pitchId]) revert PitchAlreadyFunded();
        
        // Verify escrow is valid (created by factory)
        if (!escrowFactory.isValidEscrow(escrowAddress)) revert InvalidEscrowAddress();
        
        // Get pitch status
        PitchRegistry.Pitch memory pitch = pitchRegistry.getPitch(pitchId);
        if (pitch.status != PitchRegistry.PitchStatus.Approved && 
            pitch.status != PitchRegistry.PitchStatus.Funded) {
            revert InvalidPitchStatus();
        }

        // Update pitch status to funded if not already
        if (pitch.status != PitchRegistry.PitchStatus.Funded) {
            pitchRegistry.updatePitchStatus(
                pitchId, 
                PitchRegistry.PitchStatus.Funded,
                "Investment linked via router"
            );
        }

        // Record investment
        uint256 agentId = pitchToAgent[pitchId];
        investments[pitchId] = InvestmentRecord({
            agentId: agentId,
            escrowAddress: escrowAddress,
            fundedAt: block.timestamp
        });
        
        isPitchFunded[pitchId] = true;
        fundedPitches.push(pitchId);

        emit InvestmentLinked(pitchId, escrowAddress);
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

    /**
     * @notice Get pitches submitted by an agent
     * @param agentId The agent NFT ID
     * @return pitchIds Array of pitch IDs submitted by this agent
     */
    function getAgentPitches(uint256 agentId) 
        external 
        view 
        returns (uint256[] memory pitchIds) 
    {
        address agent = agentRegistry.ownerOf(agentId);
        uint256[] memory allPitches = pitchRegistry.getPitchesBySubmitter(agent);
        
        // Count pitches submitted via router
        uint256 routerPitchCount = 0;
        for (uint256 i = 0; i < allPitches.length; i++) {
            if (pitchToAgent[allPitches[i]] == agentId) {
                routerPitchCount++;
            }
        }
        
        // Populate result array
        pitchIds = new uint256[](routerPitchCount);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < allPitches.length; i++) {
            if (pitchToAgent[allPitches[i]] == agentId) {
                pitchIds[currentIndex] = allPitches[i];
                currentIndex++;
            }
        }
    }
}