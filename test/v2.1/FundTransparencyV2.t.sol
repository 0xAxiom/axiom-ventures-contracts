// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {FundTransparencyV2} from "../../src/v2.1/FundTransparencyV2.sol";
import {InvestmentRouterV2} from "../../src/v2.1/InvestmentRouterV2.sol";
import {EscrowFactoryV2} from "../../src/v2.1/EscrowFactoryV2.sol";
import {AgentRegistry} from "../../src/v2/AgentRegistry.sol";
import {DDAttestation} from "../../src/v2/DDAttestation.sol";
import {PitchRegistry} from "../../src/PitchRegistry.sol";
import {AxiomVault} from "../../src/AxiomVault.sol";
import {EscrowFactory} from "../../src/EscrowFactory.sol";
import {MilestoneEscrow} from "../../src/MilestoneEscrow.sol";

contract FundTransparencyV2Test is Test {
    FundTransparencyV2 public transparency;
    InvestmentRouterV2 public router;
    EscrowFactoryV2 public escrowFactoryV2;
    EscrowFactory public escrowFactoryV1;
    AgentRegistry public agentRegistry;
    DDAttestation public ddAttestation;
    PitchRegistry public pitchRegistry;
    AxiomVault public axiomVault;
    IERC20 public usdc;
    
    address public constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant SAFE_ADDRESS = 0x5766f573Cc516E3CA0D05a4848EF048636008271;
    
    address public deployer;
    address public agent1;
    address public agent2;
    address public oracle;
    
    uint256 public agent1Id;
    uint256 public agent2Id;

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork("https://mainnet.base.org");
        
        deployer = makeAddr("deployer");
        agent1 = makeAddr("agent1");
        agent2 = makeAddr("agent2");
        oracle = makeAddr("oracle");
        
        usdc = IERC20(USDC_ADDRESS);
        
        vm.startPrank(deployer);
        
        // Deploy all contracts
        agentRegistry = new AgentRegistry(deployer);
        ddAttestation = new DDAttestation(deployer);
        pitchRegistry = new PitchRegistry(usdc, 0, deployer);
        axiomVault = new AxiomVault(usdc, deployer);
        
        // Deploy both factory versions
        escrowFactoryV1 = new EscrowFactory(usdc, address(axiomVault));
        escrowFactoryV2 = new EscrowFactoryV2(usdc, SAFE_ADDRESS, deployer);
        
        router = new InvestmentRouterV2(
            agentRegistry,
            ddAttestation,
            pitchRegistry,
            axiomVault,
            escrowFactoryV2,
            deployer
        );
        
        transparency = new FundTransparencyV2(
            agentRegistry,
            ddAttestation,
            router,
            pitchRegistry,
            axiomVault,
            escrowFactoryV1,
            escrowFactoryV2
        );
        
        // Set up router authorization
        escrowFactoryV2.setRouter(address(router));
        
        // Set up oracle
        ddAttestation.addOracle(oracle);
        
        vm.stopPrank();
        
        // Register agents
        vm.prank(agent1);
        agent1Id = agentRegistry.registerAgent("agent1-metadata");
        
        vm.prank(agent2);
        agent2Id = agentRegistry.registerAgent("agent2-metadata");
    }

    function test_Constructor() public {
        assertEq(address(transparency.agentRegistry()), address(agentRegistry));
        assertEq(address(transparency.ddAttestation()), address(ddAttestation));
        assertEq(address(transparency.investmentRouter()), address(router));
        assertEq(address(transparency.pitchRegistry()), address(pitchRegistry));
        assertEq(address(transparency.axiomVault()), address(axiomVault));
        assertEq(address(transparency.escrowFactoryV1()), address(escrowFactoryV1));
        assertEq(address(transparency.escrowFactoryV2()), address(escrowFactoryV2));
    }

    function test_GetPortfolio() public {
        // Create and fund some pitches
        _createAndFundPitch(agent1, agent1Id, "Pitch 1", 1000e6);
        _createAndFundPitch(agent2, agent2Id, "Pitch 2", 1500e6);
        
        FundTransparencyV2.PortfolioInvestment[] memory portfolio = transparency.getPortfolio();
        
        assertEq(portfolio.length, 2);
        
        // Verify first investment
        assertEq(portfolio[0].agentId, agent1Id);
        assertEq(portfolio[0].agentAddress, agent1);
        assertEq(portfolio[0].pitchTitle, "Pitch 1");
        assertEq(portfolio[0].fundingRequest, 1000e6);
        assertEq(portfolio[0].ddScore, 80);
        assertTrue(portfolio[0].escrowAddress != address(0));
        assertEq(portfolio[0].factoryVersion, 2); // V2 factory
        
        // Verify second investment
        assertEq(portfolio[1].agentId, agent2Id);
        assertEq(portfolio[1].agentAddress, agent2);
        assertEq(portfolio[1].pitchTitle, "Pitch 2");
        assertEq(portfolio[1].fundingRequest, 1500e6);
    }

    function test_GetPortfolioPaginated() public {
        // Create multiple investments
        for (uint i = 0; i < 5; i++) {
            _createAndFundPitch(
                agent1, 
                agent1Id, 
                string(abi.encodePacked("Pitch ", i)), 
                1000e6 + i * 100e6
            );
        }
        
        // Test pagination
        FundTransparencyV2.PortfolioInvestment[] memory page1 = transparency.getPortfolioPaginated(0, 3);
        assertEq(page1.length, 3);
        
        FundTransparencyV2.PortfolioInvestment[] memory page2 = transparency.getPortfolioPaginated(3, 3);
        assertEq(page2.length, 2);
        
        FundTransparencyV2.PortfolioInvestment[] memory emptyPage = transparency.getPortfolioPaginated(10, 3);
        assertEq(emptyPage.length, 0);
    }

    function test_GetInvestmentDetail() public {
        uint256 pitchId = _createAndFundPitch(agent1, agent1Id, "Detailed Pitch", 2000e6);
        
        FundTransparencyV2.InvestmentDetail memory detail = transparency.getInvestmentDetail(pitchId);
        
        // Verify agent info
        assertEq(detail.agentId, agent1Id);
        assertEq(detail.agentAddress, agent1);
        assertEq(detail.agentMetadataURI, "agent1-metadata");
        
        // Verify pitch info
        assertEq(detail.pitchData.title, "Detailed Pitch");
        assertEq(detail.pitchData.fundingRequest, 2000e6);
        assertEq(detail.pitchData.submitter, agent1);
        
        // Verify DD info
        assertTrue(detail.hasAttestation);
        assertEq(detail.attestation.compositeScore, 80);
        assertEq(detail.attestation.oracle, oracle);
        
        // Verify investment info
        assertEq(detail.investment.agentId, agent1Id);
        assertTrue(detail.investment.escrowAddress != address(0));
        
        // Verify escrow info
        assertEq(detail.totalEscrowed, 2000e6);
        assertEq(detail.released, 0); // No milestones released yet
        assertEq(detail.unreleased, 2000e6);
        assertFalse(detail.isExpired);
        assertFalse(detail.isClawedBack);
        assertEq(detail.factoryVersion, 2);
    }

    function test_GetFundMetrics() public {
        // Fund some investments
        _createAndFundPitch(agent1, agent1Id, "Pitch 1", 1000e6);
        _createAndFundPitch(agent2, agent2Id, "Pitch 2", 1500e6);
        
        FundTransparencyV2.FundMetrics memory metrics = transparency.getFundMetrics();
        
        // Should have 2 total investments
        assertEq(metrics.totalInvestments, 2);
        assertEq(metrics.activeInvestments, 2); // Both are active
        
        // Should have total deployed funds
        assertEq(metrics.totalDeployed, 2500e6); // 1000 + 1500
        assertEq(metrics.totalReleased, 0); // No releases yet
        assertEq(metrics.totalReturned, 0); // No clawbacks yet
        
        // Should have registered agents
        assertEq(metrics.registeredAgents, agentRegistry.getTotalAgents());
        
        // Should track both factory versions
        assertEq(metrics.v1Escrows, 0); // No V1 escrows created
        assertEq(metrics.v2Escrows, 2); // 2 V2 escrows created
    }

    function test_GetAgentProfile() public {
        // Create multiple pitches for agent1
        uint256 pitch1 = _createAndFundPitch(agent1, agent1Id, "Funded Pitch", 1000e6);
        
        vm.prank(agent1);
        uint256 pitch2 = router.submitPitch(agent1Id, "QmUnfunded", "Unfunded Pitch", "Description", 500e6);
        
        FundTransparencyV2.AgentProfile memory profile = transparency.getAgentProfile(agent1Id);
        
        assertEq(profile.agentId, agent1Id);
        assertEq(profile.agentAddress, agent1);
        assertEq(profile.metadataURI, "agent1-metadata");
        assertEq(profile.totalPitches, 2);
        assertEq(profile.fundedPitches, 1);
        assertEq(profile.totalFundingReceived, 0); // No milestones released
        assertEq(profile.averageScore, 80); // One scored pitch
        
        // Verify pitch IDs
        assertEq(profile.pitchIds.length, 2);
        assertEq(profile.pitchIds[0], pitch1);
        assertEq(profile.pitchIds[1], pitch2);
    }

    function test_GetTopAgents() public {
        // Fund different numbers of pitches for each agent
        _createAndFundPitch(agent1, agent1Id, "Agent1 Pitch1", 1000e6);
        _createAndFundPitch(agent1, agent1Id, "Agent1 Pitch2", 1200e6);
        
        _createAndFundPitch(agent2, agent2Id, "Agent2 Pitch1", 1500e6);
        
        uint256[] memory topAgents = transparency.getTopAgents(2);
        
        // agent1 should be ranked higher (2 funded pitches vs 1)
        assertEq(topAgents.length, 2);
        assertEq(topAgents[0], agent1Id); // More funded pitches
        assertEq(topAgents[1], agent2Id);
    }

    function test_GetAllEscrows() public {
        // Create escrows in both factories
        _createAndFundPitch(agent1, agent1Id, "V2 Pitch", 1000e6);
        
        // Create V1 escrow (manually for testing)
        vm.startPrank(address(axiomVault));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e6;
        string[] memory descriptions = new string[](1);
        descriptions[0] = "V1 Milestone";
        
        address v1Escrow = escrowFactoryV1.createEscrow(
            agent2,
            block.timestamp + 60 days,
            amounts,
            descriptions
        );
        vm.stopPrank();
        
        (address[] memory v1Escrows, address[] memory v2Escrows) = transparency.getAllEscrows();
        
        assertEq(v1Escrows.length, 1);
        assertEq(v2Escrows.length, 1);
        assertEq(v1Escrows[0], v1Escrow);
    }

    function test_GetEscrowsPaginated() public {
        // Create multiple escrows in V2 factory
        for (uint i = 0; i < 3; i++) {
            _createAndFundPitch(
                agent1, 
                agent1Id, 
                string(abi.encodePacked("Pitch ", i)), 
                1000e6
            );
        }
        
        (address[] memory v1Escrows, address[] memory v2Escrows) = transparency.getEscrowsPaginated(0, 0, 0, 2);
        
        assertEq(v1Escrows.length, 0); // No V1 escrows requested
        assertEq(v2Escrows.length, 2); // First 2 V2 escrows
    }

    function test_FactoryVersionDetection() public {
        uint256 pitchId = _createAndFundPitch(agent1, agent1Id, "Test Pitch", 1000e6);
        
        FundTransparencyV2.PortfolioInvestment[] memory portfolio = transparency.getPortfolio();
        assertEq(portfolio[0].factoryVersion, 2); // Should detect V2 factory
        
        FundTransparencyV2.InvestmentDetail memory detail = transparency.getInvestmentDetail(pitchId);
        assertEq(detail.factoryVersion, 2); // Should detect V2 factory
    }

    // Helper function to create and fund a pitch
    function _createAndFundPitch(
        address agentAddress, 
        uint256 agentNftId, 
        string memory title, 
        uint256 amount
    ) internal returns (uint256 pitchId) {
        // Submit pitch
        vm.prank(agentAddress);
        pitchId = router.submitPitch(
            agentNftId,
            string(abi.encodePacked("Qm", title)),
            title,
            "Test description",
            amount
        );
        
        // Move pitch through proper status sequence: Submitted → UnderReview → Approved
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.UnderReview,
            "Under review for testing"
        );
        
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.Approved,
            "Approved for testing"
        );
        
        // Add DD attestation
        vm.prank(oracle);
        uint8[6] memory categoryScores = [80, 75, 85, 70, 60, 90];
        ddAttestation.attest(pitchId, 80, categoryScores, bytes32("QmDDReport"));
        
        // Fund pitch
        vm.startPrank(deployer);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Milestone 1";
        
        router.fundPitch(pitchId, block.timestamp + 90 days, amounts, descriptions);
        
        // Update pitch status manually (Safe would do this in production)
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.Funded,
            "Funded via test"
        );
        
        vm.stopPrank();
    }
}