// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {AgentRegistry} from "./AgentRegistry.sol";
import {DDAttestation} from "./DDAttestation.sol";
import {InvestmentRouter} from "./InvestmentRouter.sol";
import {PitchRegistry} from "../PitchRegistry.sol";
import {AxiomVault} from "../AxiomVault.sol";
import {EscrowFactory} from "../EscrowFactory.sol";
import {MilestoneEscrow} from "../MilestoneEscrow.sol";

/**
 * @title FundTransparency
 * @dev Read-only aggregator providing complete portfolio transparency for LPs
 * @notice Single entry point for auditing all investments, agent profiles, and fund metrics
 * @author Axiom Ventures
 */
contract FundTransparency {
    
    /// @notice USDC token address (Base mainnet)
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice Contract dependencies
    AgentRegistry public immutable agentRegistry;
    DDAttestation public immutable ddAttestation;
    InvestmentRouter public immutable investmentRouter;
    PitchRegistry public immutable pitchRegistry;
    AxiomVault public immutable axiomVault;
    EscrowFactory public immutable escrowFactory;

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
    }

    /// @notice Fund metrics summary
    struct FundMetrics {
        uint256 totalAssets;        // Total USDC in vault
        uint256 totalDeployed;     // Total in active escrows
        uint256 totalReturned;     // Total clawed back
        uint256 totalReleased;     // Total released to agents
        uint256 activeInvestments; // Number of active investments
        uint256 totalInvestments;  // Total investments made
        uint256 registeredAgents;  // Total registered agents
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
        InvestmentRouter.InvestmentRecord investment;
        
        // Escrow info
        uint256 totalEscrowed;
        uint256 released;
        uint256 unreleased;
        bool isExpired;
        bool isClawedBack;
        uint256 milestoneCount;
        uint256 releasedMilestones;
    }

    /**
     * @notice Initialize the transparency contract
     * @param _agentRegistry Agent registry contract
     * @param _ddAttestation DD attestation contract
     * @param _investmentRouter Investment router contract
     * @param _pitchRegistry Pitch registry contract (V1)
     * @param _axiomVault Axiom vault contract (V1)
     * @param _escrowFactory Escrow factory contract (V1)
     */
    constructor(
        AgentRegistry _agentRegistry,
        DDAttestation _ddAttestation,
        InvestmentRouter _investmentRouter,
        PitchRegistry _pitchRegistry,
        AxiomVault _axiomVault,
        EscrowFactory _escrowFactory
    ) {
        agentRegistry = _agentRegistry;
        ddAttestation = _ddAttestation;
        investmentRouter = _investmentRouter;
        pitchRegistry = _pitchRegistry;
        axiomVault = _axiomVault;
        escrowFactory = _escrowFactory;
    }

    /**
     * @notice Get complete portfolio of funded investments
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
     * @notice Get paginated portfolio
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
        // Get investment record
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
    }

    /**
     * @notice Get overall fund metrics
     * @return metrics Fund performance and allocation metrics
     */
    function getFundMetrics() 
        external 
        view 
        returns (FundMetrics memory metrics) 
    {
        // Vault metrics
        metrics.totalAssets = axiomVault.totalAssets();
        
        // Portfolio metrics
        uint256[] memory fundedPitches = investmentRouter.getAllFundedPitches();
        metrics.totalInvestments = fundedPitches.length;
        
        uint256 totalDeployed = 0;
        uint256 totalReturned = 0;
        uint256 totalReleased = 0;
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < fundedPitches.length; i++) {
            InvestmentRouter.InvestmentRecord memory investment = 
                investmentRouter.getInvestmentRecord(fundedPitches[i]);
            
            MilestoneEscrow escrow = MilestoneEscrow(investment.escrowAddress);
            uint256 escrowTotal = escrow.totalAmount();
            uint256 released = escrow.totalReleased();
            
            totalDeployed += escrowTotal;
            totalReleased += released;
            
            if (escrow.isClawedBack()) {
                totalReturned += escrow.getUnreleasedAmount();
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
        
        // Get all pitches by this agent
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
                
                InvestmentRouter.InvestmentRecord memory investment = 
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
        
        // Simple ranking by funded pitches count (could be enhanced)
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
     * @dev Internal function to build portfolio investment struct
     * @param pitchId The pitch ID to build data for
     * @return investment The portfolio investment struct
     */
    function _buildPortfolioInvestment(uint256 pitchId) 
        internal 
        view 
        returns (PortfolioInvestment memory investment) 
    {
        InvestmentRouter.InvestmentRecord memory record = 
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
        
        // Get DD score if available
        if (ddAttestation.hasAttestation(pitchId)) {
            investment.ddScore = ddAttestation.getScore(pitchId);
        }
    }
}