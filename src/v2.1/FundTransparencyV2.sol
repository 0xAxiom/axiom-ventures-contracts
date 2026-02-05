// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {AgentRegistry} from "../v2/AgentRegistry.sol";
import {DDAttestation} from "../v2/DDAttestation.sol";
import {InvestmentRouterV2} from "./InvestmentRouterV2.sol";
import {PitchRegistry} from "../PitchRegistry.sol";
import {AxiomVault} from "../AxiomVault.sol";
import {EscrowFactory} from "../EscrowFactory.sol";
import {EscrowFactoryV2} from "./EscrowFactoryV2.sol";
import {MilestoneEscrow} from "../MilestoneEscrow.sol";

/**
 * @title FundTransparencyV2
 * @dev V2.1 - Enhanced read-only aggregator supporting both V1 and V2 escrow factories
 * @notice Single entry point for auditing all investments across factory versions
 * @author Axiom Ventures
 */
contract FundTransparencyV2 {
    
    /// @notice USDC token address (Base mainnet)
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice Contract dependencies
    AgentRegistry public immutable agentRegistry;
    DDAttestation public immutable ddAttestation;
    InvestmentRouterV2 public immutable investmentRouter;
    PitchRegistry public immutable pitchRegistry;
    AxiomVault public immutable axiomVault;
    EscrowFactory public immutable escrowFactoryV1;
    EscrowFactoryV2 public immutable escrowFactoryV2;

    /// @notice Portfolio investment summary
    struct PortfolioInvestment {
        uint256 pitchId;
        uint256 agentId;
        address agentAddress;
        string pitchTitle;
        uint256 fundingRequest;
        uint8 ddScore;
        address escrowAddress;
        uint256 totalEscrowed;
        uint256 released;
        uint256 unreleased;
        bool isExpired;
        bool isClawedBack;
        PitchRegistry.PitchStatus pitchStatus;
        uint256 fundedAt;
        uint8 factoryVersion; // 1 or 2
    }

    /// @notice Fund metrics summary
    struct FundMetrics {
        uint256 totalAssets;        // Total USDC in vault
        uint256 totalDeployed;     // Total in active escrows (V1 + V2)
        uint256 totalReturned;     // Total clawed back (V1 + V2)
        uint256 totalReleased;     // Total released to agents (V1 + V2)
        uint256 activeInvestments; // Number of active investments (V1 + V2)
        uint256 totalInvestments;  // Total investments made (V1 + V2)
        uint256 registeredAgents;  // Total registered agents
        uint256 v1Escrows;         // Number of V1 escrows
        uint256 v2Escrows;         // Number of V2 escrows
    }

    /// @notice Agent profile summary
    struct AgentProfile {
        uint256 agentId;
        address agentAddress;
        string metadataURI;
        uint256 totalPitches;
        uint256 fundedPitches;
        uint256 totalFundingReceived;
        uint256 averageScore;
        uint256[] pitchIds;
    }

    /// @notice Complete investment audit trail
    struct InvestmentDetail {
        // Agent info
        uint256 agentId;
        address agentAddress;
        string agentMetadataURI;
        
        // Pitch info
        PitchRegistry.Pitch pitchData;
        
        // DD info
        bool hasAttestation;
        DDAttestation.Attestation attestation;
        
        // Investment info
        InvestmentRouterV2.InvestmentRecord investment;
        
        // Escrow info
        uint256 totalEscrowed;
        uint256 released;
        uint256 unreleased;
        bool isExpired;
        bool isClawedBack;
        uint256 milestoneCount;
        uint256 releasedMilestones;
        uint8 factoryVersion;
    }

    /**
     * @notice Initialize the transparency contract V2
     * @param _agentRegistry Agent registry contract
     * @param _ddAttestation DD attestation contract
     * @param _investmentRouter Investment router contract (V2.1)
     * @param _pitchRegistry Pitch registry contract (V1)
     * @param _axiomVault Axiom vault contract (V1)
     * @param _escrowFactoryV1 Escrow factory contract (V1)
     * @param _escrowFactoryV2 Escrow factory contract (V2.1)
     */
    constructor(
        AgentRegistry _agentRegistry,
        DDAttestation _ddAttestation,
        InvestmentRouterV2 _investmentRouter,
        PitchRegistry _pitchRegistry,
        AxiomVault _axiomVault,
        EscrowFactory _escrowFactoryV1,
        EscrowFactoryV2 _escrowFactoryV2
    ) {
        agentRegistry = _agentRegistry;
        ddAttestation = _ddAttestation;
        investmentRouter = _investmentRouter;
        pitchRegistry = _pitchRegistry;
        axiomVault = _axiomVault;
        escrowFactoryV1 = _escrowFactoryV1;
        escrowFactoryV2 = _escrowFactoryV2;
    }

    /**
     * @notice Get complete portfolio of funded investments from both factories
     * @return investments Array of portfolio investments
     */
    function getPortfolio() 
        external 
        view 
        returns (PortfolioInvestment[] memory investments) 
    {
        uint256[] memory fundedPitches = investmentRouter.getAllFundedPitches();
        investments = new PortfolioInvestment[](fundedPitches.length);
        
        for (uint256 i = 0; i < fundedPitches.length; i++) {
            investments[i] = _buildPortfolioInvestment(fundedPitches[i]);
        }
    }

    /**
     * @notice Get paginated portfolio across both factories
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return investments Array of portfolio investments
     */
    function getPortfolioPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (PortfolioInvestment[] memory investments)
    {
        uint256[] memory fundedPitches = investmentRouter.getAllFundedPitches();
        
        if (offset >= fundedPitches.length) {
            return new PortfolioInvestment[](0);
        }
        
        uint256 end = offset + limit;
        if (end > fundedPitches.length) {
            end = fundedPitches.length;
        }
        
        investments = new PortfolioInvestment[](end - offset);
        
        for (uint256 i = offset; i < end; i++) {
            investments[i - offset] = _buildPortfolioInvestment(fundedPitches[i]);
        }
    }

    /**
     * @notice Get complete investment detail with full audit trail
     * @param pitchId The pitch ID to query
     * @return detail Complete investment details
     */
    function getInvestmentDetail(uint256 pitchId) 
        external 
        view 
        returns (InvestmentDetail memory detail) 
    {
        // Get investment record from RouterV2
        detail.investment = investmentRouter.getInvestmentRecord(pitchId);
        detail.agentId = detail.investment.agentId;
        
        // Get agent info
        detail.agentAddress = agentRegistry.ownerOf(detail.agentId);
        detail.agentMetadataURI = agentRegistry.tokenURI(detail.agentId);
        
        // Get pitch info
        detail.pitchData = pitchRegistry.getPitch(pitchId);
        
        // Get DD info
        detail.hasAttestation = ddAttestation.hasAttestation(pitchId);
        if (detail.hasAttestation) {
            detail.attestation = ddAttestation.getAttestation(pitchId);
        }
        
        // Get escrow info
        MilestoneEscrow escrow = MilestoneEscrow(detail.investment.escrowAddress);
        detail.totalEscrowed = escrow.totalAmount();
        detail.released = escrow.totalReleased();
        detail.unreleased = escrow.getUnreleasedAmount();
        detail.isExpired = escrow.isExpired();
        detail.isClawedBack = escrow.isClawedBack();
        detail.milestoneCount = escrow.getMilestoneCount();
        detail.releasedMilestones = escrow.getReleasedMilestoneCount();
        
        // Determine factory version
        if (escrowFactoryV2.isValidEscrow(detail.investment.escrowAddress)) {
            detail.factoryVersion = 2;
        } else if (escrowFactoryV1.isValidEscrow(detail.investment.escrowAddress)) {
            detail.factoryVersion = 1;
        }
    }

    /**
     * @notice Get overall fund metrics across both factories
     * @return metrics Fund performance and allocation metrics
     */
    function getFundMetrics() 
        external 
        view 
        returns (FundMetrics memory metrics) 
    {
        // Vault metrics
        metrics.totalAssets = axiomVault.totalAssets();
        
        // Get escrow counts from both factories
        metrics.v1Escrows = escrowFactoryV1.getEscrowCount();
        metrics.v2Escrows = escrowFactoryV2.getEscrowCount();
        
        // Portfolio metrics from RouterV2 (which handles all funded investments)
        uint256[] memory fundedPitches = investmentRouter.getAllFundedPitches();
        metrics.totalInvestments = fundedPitches.length;
        
        uint256 totalDeployed = 0;
        uint256 totalReturned = 0;
        uint256 totalReleased = 0;
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < fundedPitches.length; i++) {
            InvestmentRouterV2.InvestmentRecord memory investment = 
                investmentRouter.getInvestmentRecord(fundedPitches[i]);
            
            MilestoneEscrow escrow = MilestoneEscrow(investment.escrowAddress);
            uint256 escrowTotal = escrow.totalAmount();
            uint256 released = escrow.totalReleased();
            
            totalDeployed += escrowTotal;
            totalReleased += released;
            
            if (escrow.isClawedBack()) {
                totalReturned += (escrowTotal - released);  // Amount that was clawed back
            } else if (!escrow.isExpired()) {
                activeCount++;
            }
        }
        
        metrics.totalDeployed = totalDeployed;
        metrics.totalReturned = totalReturned;
        metrics.totalReleased = totalReleased;
        metrics.activeInvestments = activeCount;
        metrics.registeredAgents = agentRegistry.getTotalAgents();
    }

    /**
     * @notice Get agent profile with investment history
     * @param agentId The agent NFT ID to query
     * @return profile Complete agent profile
     */
    function getAgentProfile(uint256 agentId) 
        external 
        view 
        returns (AgentProfile memory profile) 
    {
        profile.agentId = agentId;
        profile.agentAddress = agentRegistry.ownerOf(agentId);
        profile.metadataURI = agentRegistry.tokenURI(agentId);
        
        // Get all pitches by this agent from RouterV2 (uses efficient mapping)
        profile.pitchIds = investmentRouter.getAgentPitches(agentId);
        profile.totalPitches = profile.pitchIds.length;
        
        uint256 fundedCount = 0;
        uint256 totalReceived = 0;
        uint256 totalScore = 0;
        uint256 scoredPitches = 0;
        
        for (uint256 i = 0; i < profile.pitchIds.length; i++) {
            uint256 pitchId = profile.pitchIds[i];
            
            // Check if funded
            if (investmentRouter.isPitchFunded(pitchId)) {
                fundedCount++;
                
                InvestmentRouterV2.InvestmentRecord memory investment = 
                    investmentRouter.getInvestmentRecord(pitchId);
                MilestoneEscrow escrow = MilestoneEscrow(investment.escrowAddress);
                totalReceived += escrow.totalReleased();
            }
            
            // Check DD score
            if (ddAttestation.hasAttestation(pitchId)) {
                totalScore += ddAttestation.getScore(pitchId);
                scoredPitches++;
            }
        }
        
        profile.fundedPitches = fundedCount;
        profile.totalFundingReceived = totalReceived;
        profile.averageScore = scoredPitches > 0 ? totalScore / scoredPitches : 0;
    }

    /**
     * @notice Get agents ranked by performance
     * @param limit Maximum number of agents to return
     * @return agentIds Array of agent IDs ranked by performance
     */
    function getTopAgents(uint256 limit) 
        external 
        view 
        returns (uint256[] memory agentIds) 
    {
        uint256 totalAgents = agentRegistry.getTotalAgents();
        uint256 resultCount = limit > totalAgents ? totalAgents : limit;
        
        agentIds = new uint256[](resultCount);
        uint256[] memory scores = new uint256[](resultCount);
        
        // Simple ranking by funded pitches count
        for (uint256 agentId = 1; agentId <= totalAgents; agentId++) {
            try agentRegistry.ownerOf(agentId) returns (address) {
                uint256[] memory pitches = investmentRouter.getAgentPitches(agentId);
                uint256 fundedCount = 0;
                
                for (uint256 j = 0; j < pitches.length; j++) {
                    if (investmentRouter.isPitchFunded(pitches[j])) {
                        fundedCount++;
                    }
                }
                
                // Insert into sorted array (simple insertion sort for small arrays)
                for (uint256 k = 0; k < resultCount; k++) {
                    if (agentIds[k] == 0 || fundedCount > scores[k]) {
                        // Shift elements
                        for (uint256 l = resultCount - 1; l > k; l--) {
                            agentIds[l] = agentIds[l - 1];
                            scores[l] = scores[l - 1];
                        }
                        agentIds[k] = agentId;
                        scores[k] = fundedCount;
                        break;
                    }
                }
            } catch {
                // Skip if NFT doesn't exist
                continue;
            }
        }
    }

    /**
     * @notice Get all escrows from both factories
     * @return v1Escrows Array of escrows from V1 factory
     * @return v2Escrows Array of escrows from V2 factory
     */
    function getAllEscrows() 
        external 
        view 
        returns (address[] memory v1Escrows, address[] memory v2Escrows) 
    {
        v1Escrows = escrowFactoryV1.getAllEscrows();
        v2Escrows = escrowFactoryV2.getAllEscrows();
    }

    /**
     * @notice Get escrows from both factories with pagination
     * @param v1Start Starting index for V1 escrows
     * @param v1Count Count of V1 escrows to return
     * @param v2Start Starting index for V2 escrows  
     * @param v2Count Count of V2 escrows to return
     * @return v1Escrows Paginated V1 escrows
     * @return v2Escrows Paginated V2 escrows
     */
    function getEscrowsPaginated(
        uint256 v1Start,
        uint256 v1Count,
        uint256 v2Start,
        uint256 v2Count
    ) 
        external 
        view 
        returns (address[] memory v1Escrows, address[] memory v2Escrows) 
    {
        // V1 factory doesn't have pagination, so implement manually
        address[] memory allV1Escrows = escrowFactoryV1.getAllEscrows();
        if (v1Start >= allV1Escrows.length) {
            v1Escrows = new address[](0);
        } else {
            uint256 v1End = v1Start + v1Count;
            if (v1End > allV1Escrows.length) {
                v1End = allV1Escrows.length;
            }
            
            v1Escrows = new address[](v1End - v1Start);
            for (uint256 i = v1Start; i < v1End; i++) {
                v1Escrows[i - v1Start] = allV1Escrows[i];
            }
        }
        
        // V2 factory has native pagination
        v2Escrows = escrowFactoryV2.getEscrowsPaginated(v2Start, v2Count);
    }

    /**
     * @dev Internal function to build portfolio investment struct
     * @param pitchId The pitch ID to build data for
     * @return investment The portfolio investment struct
     */
    function _buildPortfolioInvestment(uint256 pitchId) 
        internal 
        view 
        returns (PortfolioInvestment memory investment) 
    {
        InvestmentRouterV2.InvestmentRecord memory record = 
            investmentRouter.getInvestmentRecord(pitchId);
        PitchRegistry.Pitch memory pitch = pitchRegistry.getPitch(pitchId);
        MilestoneEscrow escrow = MilestoneEscrow(record.escrowAddress);
        
        investment.pitchId = pitchId;
        investment.agentId = record.agentId;
        investment.agentAddress = agentRegistry.ownerOf(record.agentId);
        investment.pitchTitle = pitch.title;
        investment.fundingRequest = pitch.fundingRequest;
        investment.escrowAddress = record.escrowAddress;
        investment.totalEscrowed = escrow.totalAmount();
        investment.released = escrow.totalReleased();
        investment.unreleased = escrow.getUnreleasedAmount();
        investment.isExpired = escrow.isExpired();
        investment.isClawedBack = escrow.isClawedBack();
        investment.pitchStatus = pitch.status;
        investment.fundedAt = record.fundedAt;
        
        // Determine factory version
        if (escrowFactoryV2.isValidEscrow(record.escrowAddress)) {
            investment.factoryVersion = 2;
        } else if (escrowFactoryV1.isValidEscrow(record.escrowAddress)) {
            investment.factoryVersion = 1;
        }
        
        // Get DD score if available
        if (ddAttestation.hasAttestation(pitchId)) {
            investment.ddScore = ddAttestation.getScore(pitchId);
        }
    }
}