// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import {AgentRegistry} from "../../src/v2/AgentRegistry.sol";
import {DDAttestation} from "../../src/v2/DDAttestation.sol";
import {InvestmentRouter} from "../../src/v2/InvestmentRouter.sol";
import {FundTransparency} from "../../src/v2/FundTransparency.sol";
import {PitchRegistry} from "../../src/PitchRegistry.sol";
import {AxiomVault} from "../../src/AxiomVault.sol";
import {EscrowFactory} from "../../src/EscrowFactory.sol";
import {MilestoneEscrow} from "../../src/MilestoneEscrow.sol";

/**
 * @title IntegrationTest
 * @dev Full pipeline integration test: register → pitch → DD → fund → transparency
 * @notice Tests the complete V2 infrastructure working together
 */
contract IntegrationTest is Test {
    // V2 Contracts
    AgentRegistry public agentRegistry;
    DDAttestation public ddAttestation;
    InvestmentRouter public router;
    FundTransparency public transparency;
    
    // V1 Contracts (deployed)
    PitchRegistry public pitchRegistry;
    AxiomVault public axiomVault;
    EscrowFactory public escrowFactory;
    
    // Mock USDC for testing
    ERC20Mock public usdc;
    
    // Test actors
    address public owner = makeAddr("owner");
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public oracle = makeAddr("oracle");
    address public investor = makeAddr("investor");
    address public recipient = makeAddr("recipient");
    
    // Test constants
    string constant METADATA_URI = "ipfs://QmAgentMetadata123";
    string constant PITCH_TITLE = "Revolutionary AI Agent Platform";
    string constant PITCH_DESCRIPTION = "Building the future of autonomous agents";
    string constant IPFS_HASH = "QmPitchData456";
    uint256 constant FUNDING_REQUEST = 500000e6; // 500k USDC
    uint256 constant REGISTRATION_FEE = 50e6; // 50 USDC
    
    uint256 constant TOTAL_VAULT_ASSETS = 10000000e6; // 10M USDC
    uint8 constant MIN_DD_SCORE = 70;

    event AgentRegistered(uint256 indexed agentId, address indexed agent, string metadataURI);
    event PitchSubmitted(uint256 indexed pitchId, uint256 indexed agentId, address indexed submitter);
    event AttestationPosted(uint256 indexed pitchId, uint8 score, address indexed oracle);
    event InvestmentLinked(uint256 indexed pitchId, address indexed escrowAddress);

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock();
        
        // Setup balances
        usdc.mint(agent1, 10000e6);
        usdc.mint(agent2, 10000e6);
        usdc.mint(investor, TOTAL_VAULT_ASSETS);
        usdc.mint(address(this), TOTAL_VAULT_ASSETS);
        
        // Deploy V1 contracts (simplified for testing)
        vm.prank(owner);
        pitchRegistry = new PitchRegistry(usdc, 0, owner); // No submission fee for testing
        
        vm.prank(owner);
        axiomVault = new AxiomVault(usdc, owner);
        
        vm.prank(owner);
        escrowFactory = new EscrowFactory(usdc, address(axiomVault));
        
        // Deploy V2 contracts
        vm.prank(owner);
        agentRegistry = new AgentRegistry(owner);
        
        vm.prank(owner);
        ddAttestation = new DDAttestation(owner);
        
        vm.prank(owner);
        router = new InvestmentRouter(
            agentRegistry,
            ddAttestation,
            pitchRegistry,
            axiomVault,
            escrowFactory,
            owner
        );
        
        transparency = new FundTransparency(
            agentRegistry,
            ddAttestation,
            router,
            pitchRegistry,
            axiomVault,
            escrowFactory
        );
        
        // Setup initial state
        _setupInitialState();
    }

    function _setupInitialState() internal {
        // Set registration fee
        vm.prank(owner);
        agentRegistry.setRegistrationFee(REGISTRATION_FEE);
        
        // Add oracle
        vm.prank(owner);
        ddAttestation.addOracle(oracle);
        
        // Fund vault
        vm.prank(investor);
        usdc.approve(address(axiomVault), TOTAL_VAULT_ASSETS);
        
        vm.prank(investor);
        axiomVault.deposit(TOTAL_VAULT_ASSETS, investor);
        
        // Note: axiomVault is already owned by 'owner', no transfer needed
    }

    function testFullPipeline() public {
        console.log("=== Starting Full Pipeline Test ===");
        
        // Step 1: Agent Registration
        console.log("Step 1: Agent Registration");
        
        vm.prank(agent1);
        usdc.approve(address(agentRegistry), REGISTRATION_FEE);
        
        vm.prank(agent1);
        vm.expectEmit(true, true, false, true);
        emit AgentRegistered(1, agent1, METADATA_URI);
        
        uint256 agentId = agentRegistry.registerAgent(METADATA_URI);
        
        assertEq(agentId, 1);
        assertTrue(agentRegistry.isRegistered(agent1));
        console.log("Agent registered with ID:", agentId);
        
        // Step 2: Pitch Submission
        console.log("Step 2: Pitch Submission");
        
        vm.prank(agent1);
        vm.expectEmit(true, true, true, false);
        emit PitchSubmitted(1, agentId, agent1);
        
        uint256 pitchId = router.submitPitch(
            agentId,
            IPFS_HASH,
            PITCH_TITLE,
            PITCH_DESCRIPTION,
            FUNDING_REQUEST
        );
        
        assertEq(pitchId, 1);
        assertEq(router.getPitchAgent(pitchId), agentId);
        assertTrue(router.didAgentSubmitPitch(pitchId, agent1));
        console.log("Pitch submitted with ID:", pitchId);
        
        // Verify pitch is in registry
        PitchRegistry.Pitch memory pitch = pitchRegistry.getPitch(pitchId);
        assertEq(pitch.submitter, agent1);
        assertEq(pitch.title, PITCH_TITLE);
        assertEq(pitch.fundingRequest, FUNDING_REQUEST);
        assertEq(uint256(pitch.status), uint256(PitchRegistry.PitchStatus.Submitted));
        
        // Step 3: Due Diligence Attestation
        console.log("Step 3: Due Diligence");
        
        uint8[6] memory categoryScores = [85, 90, 80, 75, 85, 90]; // Strong scores
        uint8 expectedComposite = ddAttestation.calculateCompositeScore(categoryScores);
        bytes32 reportHash = keccak256("Comprehensive DD report for revolutionary platform");
        
        vm.prank(oracle);
        vm.expectEmit(true, false, true, true);
        emit AttestationPosted(pitchId, expectedComposite, oracle);
        
        ddAttestation.attest(pitchId, expectedComposite, categoryScores, reportHash);
        
        assertTrue(ddAttestation.hasAttestation(pitchId));
        assertTrue(ddAttestation.hasPassingScore(pitchId, MIN_DD_SCORE));
        assertEq(ddAttestation.getScore(pitchId), expectedComposite);
        console.log("DD attestation posted with score:", expectedComposite);
        
        // Step 4: Pitch Approval
        console.log("Step 4: Pitch Approval");
        
        vm.prank(owner);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.Approved,
            "Excellent DD score and promising technology"
        );
        
        // Verify status update
        pitch = pitchRegistry.getPitch(pitchId);
        assertEq(uint256(pitch.status), uint256(PitchRegistry.PitchStatus.Approved));
        
        // Step 5: Investment & Escrow Creation
        console.log("Step 5: Investment & Escrow Creation");
        
        // Create milestone structure
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 125000e6; // 25% for MVP
        amounts[1] = 150000e6; // 30% for Beta
        amounts[2] = 125000e6; // 25% for Launch
        amounts[3] = 100000e6; // 20% for Growth
        
        string[] memory descriptions = new string[](4);
        descriptions[0] = "MVP Development Complete";
        descriptions[1] = "Beta Testing & User Feedback";
        descriptions[2] = "Production Launch";
        descriptions[3] = "Growth Milestones Achieved";
        
        uint256 deadline = block.timestamp + 365 days;
        
        // Vault creates escrow (since EscrowFactory is onlyVault)
        vm.prank(owner);
        usdc.approve(address(escrowFactory), FUNDING_REQUEST);
        
        vm.prank(owner);
        address escrowAddress = escrowFactory.createEscrow(
            agent1,
            deadline,
            amounts,
            descriptions
        );
        
        // Fund the escrow
        vm.prank(owner);
        usdc.transfer(escrowAddress, FUNDING_REQUEST);
        
        // Link escrow to pitch via router
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit InvestmentLinked(pitchId, escrowAddress);
        
        router.linkEscrow(pitchId, escrowAddress);
        
        assertTrue(router.isPitchFunded(pitchId));
        console.log("Escrow created and linked:", escrowAddress);
        
        // Verify final pitch status
        pitch = pitchRegistry.getPitch(pitchId);
        assertEq(uint256(pitch.status), uint256(PitchRegistry.PitchStatus.Funded));
        
        // Step 6: Transparency & Audit
        console.log("Step 6: Transparency & Audit");
        
        // Test complete investment audit trail
        (
            InvestmentRouter.InvestmentRecord memory investment,
            PitchRegistry.Pitch memory pitchData,
            DDAttestation.Attestation memory attestation,
            address agentAddress
        ) = router.getInvestment(pitchId);
        
        assertEq(investment.agentId, agentId);
        assertEq(investment.escrowAddress, escrowAddress);
        assertEq(pitchData.title, PITCH_TITLE);
        assertEq(attestation.compositeScore, expectedComposite);
        assertEq(agentAddress, agent1);
        
        // Test portfolio view
        FundTransparency.PortfolioInvestment[] memory portfolio = transparency.getPortfolio();
        assertEq(portfolio.length, 1);
        assertEq(portfolio[0].pitchId, pitchId);
        assertEq(portfolio[0].agentId, agentId);
        assertEq(portfolio[0].ddScore, expectedComposite);
        assertEq(portfolio[0].totalEscrowed, FUNDING_REQUEST);
        
        // Test fund metrics
        FundTransparency.FundMetrics memory metrics = transparency.getFundMetrics();
        assertEq(metrics.totalInvestments, 1);
        assertEq(metrics.activeInvestments, 1);
        assertEq(metrics.totalDeployed, FUNDING_REQUEST);
        assertEq(metrics.registeredAgents, 1);
        
        // Test agent profile
        FundTransparency.AgentProfile memory profile = transparency.getAgentProfile(agentId);
        assertEq(profile.agentId, agentId);
        assertEq(profile.totalPitches, 1);
        assertEq(profile.fundedPitches, 1);
        assertEq(profile.averageScore, expectedComposite);
        
        console.log("=== Full Pipeline Test Complete ===");
        console.log("Total agents registered:", metrics.registeredAgents);
        console.log("Total investments:", metrics.totalInvestments);
        console.log("Total deployed:", metrics.totalDeployed / 1e6, "USDC");
    }

    function testMilestoneRelease() public {
        // Setup investment first (reuse pipeline setup)
        testFullPipeline();
        
        console.log("=== Testing Milestone Release ===");
        
        uint256 pitchId = 1;
        uint256 agentId = 1;
        
        // Get escrow address
        InvestmentRouter.InvestmentRecord memory investment = router.getInvestmentRecord(pitchId);
        MilestoneEscrow escrow = MilestoneEscrow(investment.escrowAddress);
        
        // Check initial state
        assertEq(escrow.totalAmount(), FUNDING_REQUEST);
        assertEq(escrow.totalReleased(), 0);
        assertEq(escrow.getUnreleasedAmount(), FUNDING_REQUEST);
        assertEq(escrow.getReleasedMilestoneCount(), 0);
        
        // Release first milestone (25% - MVP Complete)
        vm.prank(owner);
        escrow.releaseMilestone(0);
        
        // Verify release
        assertEq(escrow.totalReleased(), 125000e6);
        assertEq(escrow.getUnreleasedAmount(), 375000e6);
        assertEq(escrow.getReleasedMilestoneCount(), 1);
        
        // Check agent received funds
        assertGe(usdc.balanceOf(agent1), 125000e6);
        
        // Test updated transparency
        FundTransparency.InvestmentDetail memory detail = transparency.getInvestmentDetail(pitchId);
        assertEq(detail.released, 125000e6);
        assertEq(detail.unreleased, 375000e6);
        assertEq(detail.releasedMilestones, 1);
        
        FundTransparency.FundMetrics memory metrics = transparency.getFundMetrics();
        assertEq(metrics.totalReleased, 125000e6);
        
        console.log("Milestone 1 released successfully: 125k USDC");
    }

    function testMultipleAgentPipeline() public {
        console.log("=== Testing Multiple Agent Pipeline ===");
        
        // Register second agent
        vm.prank(agent2);
        usdc.approve(address(agentRegistry), REGISTRATION_FEE);
        
        vm.prank(agent2);
        uint256 agentId2 = agentRegistry.registerAgent(METADATA_URI);
        
        assertEq(agentId2, 2);
        
        // Both agents submit pitches
        vm.prank(agent1);
        usdc.approve(address(agentRegistry), REGISTRATION_FEE);
        vm.prank(agent1);
        uint256 agentId1 = agentRegistry.registerAgent(METADATA_URI);
        
        vm.prank(agent1);
        uint256 pitchId1 = router.submitPitch(agentId1, IPFS_HASH, "Agent 1 Pitch", PITCH_DESCRIPTION, 300000e6);
        
        vm.prank(agent2);
        uint256 pitchId2 = router.submitPitch(agentId2, IPFS_HASH, "Agent 2 Pitch", PITCH_DESCRIPTION, 400000e6);
        
        // DD attestations with different scores
        uint8[6] memory scores1 = [90, 85, 80, 85, 90, 80];
        uint8[6] memory scores2 = [75, 70, 85, 80, 75, 85];
        
        vm.prank(oracle);
        ddAttestation.attest(pitchId1, ddAttestation.calculateCompositeScore(scores1), scores1, keccak256("report1"));
        
        vm.prank(oracle);
        ddAttestation.attest(pitchId2, ddAttestation.calculateCompositeScore(scores2), scores2, keccak256("report2"));
        
        // Approve both pitches
        vm.prank(owner);
        pitchRegistry.updatePitchStatus(pitchId1, PitchRegistry.PitchStatus.Approved, "Strong technical team");
        
        vm.prank(owner);
        pitchRegistry.updatePitchStatus(pitchId2, PitchRegistry.PitchStatus.Approved, "Good market potential");
        
        // Fund both (simplified escrow setup)
        address escrow1 = makeAddr("escrow1");
        address escrow2 = makeAddr("escrow2");
        
        vm.mockCall(escrow1, abi.encodeWithSignature("totalAmount()"), abi.encode(300000e6));
        vm.mockCall(escrow2, abi.encodeWithSignature("totalAmount()"), abi.encode(400000e6));
        vm.mockCall(address(escrowFactory), abi.encodeWithSignature("isValidEscrow(address)"), abi.encode(true));
        
        vm.prank(owner);
        router.linkEscrow(pitchId1, escrow1);
        
        vm.prank(owner);
        router.linkEscrow(pitchId2, escrow2);
        
        // Test portfolio with multiple investments
        FundTransparency.PortfolioInvestment[] memory portfolio = transparency.getPortfolio();
        assertEq(portfolio.length, 2);
        
        // Test fund metrics
        FundTransparency.FundMetrics memory metrics = transparency.getFundMetrics();
        assertEq(metrics.totalInvestments, 2);
        assertEq(metrics.registeredAgents, 2);
        
        // Test top agents
        uint256[] memory topAgents = transparency.getTopAgents(2);
        assertEq(topAgents.length, 2);
        
        console.log("Multiple agent pipeline test complete");
        console.log("Total agents:", metrics.registeredAgents);
        console.log("Total investments:", metrics.totalInvestments);
    }

    function test_RevertWhen_UnauthorizedActions() public {
        // Test unauthorized pitch submission (no agent NFT)
        vm.prank(agent1);
        vm.expectRevert();
        router.submitPitch(999, IPFS_HASH, PITCH_TITLE, PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        // Test unauthorized DD attestation
        uint8[6] memory scores = [80, 80, 80, 80, 80, 80];
        vm.prank(agent1);
        vm.expectRevert(DDAttestation.OracleNotAuthorized.selector);
        ddAttestation.attest(1, 80, scores, keccak256("report"));
        
        // Test unauthorized escrow linking
        vm.prank(agent1);
        vm.expectRevert();
        router.linkEscrow(1, makeAddr("escrow"));
    }

    function testAccessControlEdgeCases() public {
        // Test registration fee edge cases
        vm.prank(owner);
        agentRegistry.setRegistrationFee(0);
        
        vm.prank(agent1);
        uint256 agentId = agentRegistry.registerAgent(METADATA_URI); // Should work with 0 fee
        
        assertTrue(agentRegistry.isRegistered(agent1));
        
        // Test double registration prevention
        vm.prank(agent1);
        vm.expectRevert(AgentRegistry.AgentAlreadyRegistered.selector);
        agentRegistry.registerAgent(METADATA_URI);
        
        // Test DD score edge cases
        vm.prank(owner);
        ddAttestation.addOracle(agent1);
        
        uint8[6] memory maxScores = [100, 100, 100, 100, 100, 100];
        vm.prank(agent1);
        ddAttestation.attest(1, 100, maxScores, keccak256("perfect"));
        
        assertTrue(ddAttestation.hasPassingScore(1, uint8(100)));
        assertFalse(ddAttestation.hasPassingScore(1, uint8(101))); // Edge case
    }

    // Console import provides console.log functionality
}