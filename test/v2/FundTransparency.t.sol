// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {FundTransparency} from "../../src/v2/FundTransparency.sol";
import {AgentRegistry} from "../../src/v2/AgentRegistry.sol";
import {DDAttestation} from "../../src/v2/DDAttestation.sol";
import {InvestmentRouter} from "../../src/v2/InvestmentRouter.sol";
import {PitchRegistry} from "../../src/PitchRegistry.sol";
import {AxiomVault} from "../../src/AxiomVault.sol";
import {EscrowFactory} from "../../src/EscrowFactory.sol";

/**
 * @title FundTransparencyTest
 * @dev Comprehensive tests for FundTransparency contract
 */
contract FundTransparencyTest is Test {
    FundTransparency public transparency;
    AgentRegistry public agentRegistry;
    DDAttestation public ddAttestation;
    InvestmentRouter public router;
    
    // Mock contracts
    address public mockPitchRegistry = makeAddr("pitchRegistry");
    address public mockAxiomVault = makeAddr("axiomVault");
    address public mockEscrowFactory = makeAddr("escrowFactory");
    address public mockEscrow1 = makeAddr("escrow1");
    address public mockEscrow2 = makeAddr("escrow2");
    
    address public owner = makeAddr("owner");
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public oracle = makeAddr("oracle");
    
    uint256 constant AGENT_ID_1 = 1;
    uint256 constant AGENT_ID_2 = 2;
    uint256 constant PITCH_ID_1 = 1;
    uint256 constant PITCH_ID_2 = 2;
    uint256 constant FUNDING_REQUEST_1 = 100000e6; // 100k USDC
    uint256 constant FUNDING_REQUEST_2 = 200000e6; // 200k USDC
    
    string constant METADATA_URI = "ipfs://QmTestHash123";
    string constant PITCH_TITLE_1 = "Test Pitch 1";
    string constant PITCH_TITLE_2 = "Test Pitch 2";

    function setUp() public {
        // Set block timestamp to avoid underflow in test data setup
        vm.warp(2000);
        
        // Deploy V2 contracts
        vm.prank(owner);
        agentRegistry = new AgentRegistry(owner);
        
        vm.prank(owner);
        ddAttestation = new DDAttestation(owner);
        
        vm.prank(owner);
        router = new InvestmentRouter(
            agentRegistry,
            ddAttestation,
            PitchRegistry(mockPitchRegistry),
            AxiomVault(mockAxiomVault),
            EscrowFactory(mockEscrowFactory),
            owner
        );
        
        transparency = new FundTransparency(
            agentRegistry,
            ddAttestation,
            router,
            PitchRegistry(mockPitchRegistry),
            AxiomVault(mockAxiomVault),
            EscrowFactory(mockEscrowFactory)
        );
        
        _setupTestData();
    }

    function _setupTestData() internal {
        // Register agents
        vm.prank(owner);
        agentRegistry.grantIdentity(agent1, METADATA_URI);
        
        vm.prank(owner);
        agentRegistry.grantIdentity(agent2, METADATA_URI);
        
        // Add oracle
        vm.prank(owner);
        ddAttestation.addOracle(oracle);
        
        // Setup mock responses for pitches
        _setupPitchMocks();
        _setupEscrowMocks();
        _setupVaultMocks();
    }

    function _setupPitchMocks() internal {
        // Mock nextPitchId (used by getAgentPitches to scan pitch range)
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSignature("nextPitchId()"),
            abi.encode(uint256(3)) // pitches 1 and 2 exist
        );
        
        // Mock PitchRegistry responses
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.submitPitch.selector),
            abi.encode(PITCH_ID_1)
        );
        
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.pitchExists.selector),
            abi.encode(true)
        );
        
        // Mock getPitchesBySubmitter for agent1 — returns pitch 1
        uint256[] memory agent1Pitches = new uint256[](1);
        agent1Pitches[0] = PITCH_ID_1;
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.getPitchesBySubmitter.selector, agent1),
            abi.encode(agent1Pitches)
        );

        // Mock getPitchesBySubmitter for agent2 — returns pitch 2
        uint256[] memory agent2Pitches = new uint256[](1);
        agent2Pitches[0] = PITCH_ID_2;
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.getPitchesBySubmitter.selector, agent2),
            abi.encode(agent2Pitches)
        );
        
        // Mock pitch data
        PitchRegistry.Pitch memory pitch1 = PitchRegistry.Pitch({
            submitter: agent1,
            ipfsHash: "QmHash1",
            title: PITCH_TITLE_1,
            description: "Description 1",
            fundingRequest: FUNDING_REQUEST_1,
            status: PitchRegistry.PitchStatus.Funded,
            submittedAt: block.timestamp - 1000,
            lastUpdated: block.timestamp - 500,
            reviewer: owner,
            reviewNotes: "Approved"
        });
        
        PitchRegistry.Pitch memory pitch2 = PitchRegistry.Pitch({
            submitter: agent2,
            ipfsHash: "QmHash2",
            title: PITCH_TITLE_2,
            description: "Description 2",
            fundingRequest: FUNDING_REQUEST_2,
            status: PitchRegistry.PitchStatus.Funded,
            submittedAt: block.timestamp - 800,
            lastUpdated: block.timestamp - 400,
            reviewer: owner,
            reviewNotes: "Approved"
        });
        
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.getPitch.selector, PITCH_ID_1),
            abi.encode(pitch1)
        );
        
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.getPitch.selector, PITCH_ID_2),
            abi.encode(pitch2)
        );
        
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.updatePitchStatus.selector),
            abi.encode()
        );
    }

    function _setupEscrowMocks() internal {
        vm.mockCall(
            mockEscrowFactory,
            abi.encodeWithSignature("isValidEscrow(address)"),
            abi.encode(true)
        );
        
        // Mock escrow 1 data
        vm.mockCall(
            mockEscrow1,
            abi.encodeWithSignature("totalAmount()"),
            abi.encode(FUNDING_REQUEST_1)
        );
        vm.mockCall(
            mockEscrow1,
            abi.encodeWithSignature("totalReleased()"),
            abi.encode(30000e6) // 30% released
        );
        vm.mockCall(
            mockEscrow1,
            abi.encodeWithSignature("getUnreleasedAmount()"),
            abi.encode(70000e6) // 70% unreleased
        );
        vm.mockCall(
            mockEscrow1,
            abi.encodeWithSignature("isExpired()"),
            abi.encode(false)
        );
        vm.mockCall(
            mockEscrow1,
            abi.encodeWithSignature("isClawedBack()"),
            abi.encode(false)
        );
        vm.mockCall(
            mockEscrow1,
            abi.encodeWithSignature("getMilestoneCount()"),
            abi.encode(4)
        );
        vm.mockCall(
            mockEscrow1,
            abi.encodeWithSignature("getReleasedMilestoneCount()"),
            abi.encode(1)
        );
        
        // Mock escrow 2 data
        vm.mockCall(
            mockEscrow2,
            abi.encodeWithSignature("totalAmount()"),
            abi.encode(FUNDING_REQUEST_2)
        );
        vm.mockCall(
            mockEscrow2,
            abi.encodeWithSignature("totalReleased()"),
            abi.encode(50000e6) // 25% released
        );
        vm.mockCall(
            mockEscrow2,
            abi.encodeWithSignature("getUnreleasedAmount()"),
            abi.encode(150000e6) // 75% unreleased
        );
        vm.mockCall(
            mockEscrow2,
            abi.encodeWithSignature("isExpired()"),
            abi.encode(false)
        );
        vm.mockCall(
            mockEscrow2,
            abi.encodeWithSignature("isClawedBack()"),
            abi.encode(false)
        );
        vm.mockCall(
            mockEscrow2,
            abi.encodeWithSignature("getMilestoneCount()"),
            abi.encode(5)
        );
        vm.mockCall(
            mockEscrow2,
            abi.encodeWithSignature("getReleasedMilestoneCount()"),
            abi.encode(1)
        );
    }

    function _setupVaultMocks() internal {
        vm.mockCall(
            mockAxiomVault,
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(1000000e6) // 1M USDC
        );
    }

    function _createTestInvestments() internal {
        // Submit pitches via router
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, "QmHash1", PITCH_TITLE_1, "Description 1", FUNDING_REQUEST_1);
        
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.submitPitch.selector),
            abi.encode(PITCH_ID_2)
        );
        
        vm.prank(agent2);
        router.submitPitch(AGENT_ID_2, "QmHash2", PITCH_TITLE_2, "Description 2", FUNDING_REQUEST_2);
        
        // Add DD attestations
        uint8[6] memory categoryScores1 = [90, 80, 85, 70, 95, 75];
        vm.prank(oracle);
        ddAttestation.attest(PITCH_ID_1, 85, categoryScores1, keccak256("report1"));
        
        uint8[6] memory categoryScores2 = [85, 90, 80, 80, 85, 90];
        vm.prank(oracle);
        ddAttestation.attest(PITCH_ID_2, 86, categoryScores2, keccak256("report2"));
        
        // Link escrows
        vm.prank(owner);
        router.linkEscrow(PITCH_ID_1, mockEscrow1);
        
        vm.prank(owner);
        router.linkEscrow(PITCH_ID_2, mockEscrow2);
    }

    function testGetPortfolio() public {
        _createTestInvestments();
        
        FundTransparency.PortfolioInvestment[] memory portfolio = transparency.getPortfolio();
        
        assertEq(portfolio.length, 2);
        
        // Check first investment
        assertEq(portfolio[0].pitchId, PITCH_ID_1);
        assertEq(portfolio[0].agentId, AGENT_ID_1);
        assertEq(portfolio[0].agentAddress, agent1);
        assertEq(portfolio[0].pitchTitle, PITCH_TITLE_1);
        assertEq(portfolio[0].fundingRequest, FUNDING_REQUEST_1);
        assertEq(portfolio[0].ddScore, 85);
        assertEq(portfolio[0].escrowAddress, mockEscrow1);
        assertEq(portfolio[0].totalEscrowed, FUNDING_REQUEST_1);
        assertEq(portfolio[0].released, 30000e6);
        assertEq(portfolio[0].unreleased, 70000e6);
        assertFalse(portfolio[0].isExpired);
        assertFalse(portfolio[0].isClawedBack);
        
        // Check second investment
        assertEq(portfolio[1].pitchId, PITCH_ID_2);
        assertEq(portfolio[1].agentId, AGENT_ID_2);
        assertEq(portfolio[1].agentAddress, agent2);
        assertEq(portfolio[1].ddScore, 86);
    }

    function testGetPortfolioPaginated() public {
        _createTestInvestments();
        
        // Test full range
        FundTransparency.PortfolioInvestment[] memory fullPortfolio = 
            transparency.getPortfolioPaginated(0, 10);
        assertEq(fullPortfolio.length, 2);
        
        // Test partial range
        FundTransparency.PortfolioInvestment[] memory partialPortfolio = 
            transparency.getPortfolioPaginated(1, 2);
        assertEq(partialPortfolio.length, 1);
        assertEq(partialPortfolio[0].pitchId, PITCH_ID_2);
        
        // Test offset beyond range
        FundTransparency.PortfolioInvestment[] memory emptyPortfolio = 
            transparency.getPortfolioPaginated(5, 10);
        assertEq(emptyPortfolio.length, 0);
        
        // Test limit beyond available
        FundTransparency.PortfolioInvestment[] memory limitedPortfolio = 
            transparency.getPortfolioPaginated(0, 1);
        assertEq(limitedPortfolio.length, 1);
        assertEq(limitedPortfolio[0].pitchId, PITCH_ID_1);
    }

    function testGetInvestmentDetail() public {
        _createTestInvestments();
        
        FundTransparency.InvestmentDetail memory detail = 
            transparency.getInvestmentDetail(PITCH_ID_1);
        
        // Check agent info
        assertEq(detail.agentId, AGENT_ID_1);
        assertEq(detail.agentAddress, agent1);
        assertEq(detail.agentMetadataURI, METADATA_URI);
        
        // Check pitch info
        assertEq(detail.pitchData.title, PITCH_TITLE_1);
        assertEq(detail.pitchData.fundingRequest, FUNDING_REQUEST_1);
        assertEq(uint256(detail.pitchData.status), uint256(PitchRegistry.PitchStatus.Funded));
        
        // Check DD info
        assertTrue(detail.hasAttestation);
        assertEq(detail.attestation.compositeScore, 85);
        assertEq(detail.attestation.oracle, oracle);
        
        // Check investment info
        assertEq(detail.investment.agentId, AGENT_ID_1);
        assertEq(detail.investment.escrowAddress, mockEscrow1);
        
        // Check escrow info
        assertEq(detail.totalEscrowed, FUNDING_REQUEST_1);
        assertEq(detail.released, 30000e6);
        assertEq(detail.unreleased, 70000e6);
        assertFalse(detail.isExpired);
        assertFalse(detail.isClawedBack);
        assertEq(detail.milestoneCount, 4);
        assertEq(detail.releasedMilestones, 1);
    }

    function testGetFundMetrics() public {
        _createTestInvestments();
        
        FundTransparency.FundMetrics memory metrics = transparency.getFundMetrics();
        
        assertEq(metrics.totalAssets, 1000000e6);
        assertEq(metrics.totalDeployed, FUNDING_REQUEST_1 + FUNDING_REQUEST_2);
        assertEq(metrics.totalReleased, 80000e6); // 30k + 50k
        assertEq(metrics.totalReturned, 0); // No clawbacks
        assertEq(metrics.activeInvestments, 2);
        assertEq(metrics.totalInvestments, 2);
        assertEq(metrics.registeredAgents, 2);
    }

    function testGetFundMetricsWithClawback() public {
        _createTestInvestments();
        
        // Mock one escrow as clawed back
        vm.mockCall(
            mockEscrow2,
            abi.encodeWithSignature("isClawedBack()"),
            abi.encode(true)
        );
        
        FundTransparency.FundMetrics memory metrics = transparency.getFundMetrics();
        
        assertEq(metrics.totalReturned, 150000e6); // Clawed back unreleased amount
        assertEq(metrics.activeInvestments, 1); // Only one active now
    }

    function testGetAgentProfile() public {
        _createTestInvestments();
        
        // Mock router.getAgentPitches to return the pitch
        uint256[] memory agentPitches = new uint256[](1);
        agentPitches[0] = PITCH_ID_1;
        
        vm.mockCall(
            address(router),
            abi.encodeWithSelector(InvestmentRouter.getAgentPitches.selector, AGENT_ID_1),
            abi.encode(agentPitches)
        );
        
        FundTransparency.AgentProfile memory profile = transparency.getAgentProfile(AGENT_ID_1);
        
        assertEq(profile.agentId, AGENT_ID_1);
        assertEq(profile.agentAddress, agent1);
        assertEq(profile.metadataURI, METADATA_URI);
        assertEq(profile.totalPitches, 1);
        assertEq(profile.fundedPitches, 1);
        assertEq(profile.totalFundingReceived, 30000e6); // Released amount
        assertEq(profile.averageScore, 85);
        assertEq(profile.pitchIds[0], PITCH_ID_1);
    }

    function testGetAgentProfileMultiplePitches() public {
        _createTestInvestments();
        
        // Mock agent with multiple pitches, one funded, one not
        uint256[] memory agentPitches = new uint256[](2);
        agentPitches[0] = PITCH_ID_1;
        agentPitches[1] = 999; // Unfunded pitch
        
        vm.mockCall(
            address(router),
            abi.encodeWithSelector(InvestmentRouter.getAgentPitches.selector, AGENT_ID_1),
            abi.encode(agentPitches)
        );
        
        vm.mockCall(
            address(router),
            abi.encodeWithSignature("isPitchFunded(uint256)", 999),
            abi.encode(false)
        );
        
        FundTransparency.AgentProfile memory profile = transparency.getAgentProfile(AGENT_ID_1);
        
        assertEq(profile.totalPitches, 2);
        assertEq(profile.fundedPitches, 1);
        assertEq(profile.averageScore, 85); // Only one pitch scored
    }

    function testGetTopAgents() public {
        _createTestInvestments();
        
        // Mock router responses for agent ranking
        uint256[] memory agent1Pitches = new uint256[](1);
        agent1Pitches[0] = PITCH_ID_1;
        
        uint256[] memory agent2Pitches = new uint256[](1);
        agent2Pitches[0] = PITCH_ID_2;
        
        vm.mockCall(
            address(router),
            abi.encodeWithSelector(InvestmentRouter.getAgentPitches.selector, AGENT_ID_1),
            abi.encode(agent1Pitches)
        );
        
        vm.mockCall(
            address(router),
            abi.encodeWithSelector(InvestmentRouter.getAgentPitches.selector, AGENT_ID_2),
            abi.encode(agent2Pitches)
        );
        
        uint256[] memory topAgents = transparency.getTopAgents(10);
        
        assertEq(topAgents.length, 2);
        // Both agents have 1 funded pitch, so order might vary
        assertTrue(topAgents[0] == AGENT_ID_1 || topAgents[0] == AGENT_ID_2);
        assertTrue(topAgents[1] == AGENT_ID_1 || topAgents[1] == AGENT_ID_2);
        assertTrue(topAgents[0] != topAgents[1]);
    }

    function testGetTopAgentsLimited() public {
        _createTestInvestments();
        
        uint256[] memory topAgents = transparency.getTopAgents(1);
        assertEq(topAgents.length, 1);
    }

    function testEmptyPortfolio() public {
        FundTransparency.PortfolioInvestment[] memory portfolio = transparency.getPortfolio();
        assertEq(portfolio.length, 0);
        
        FundTransparency.FundMetrics memory metrics = transparency.getFundMetrics();
        assertEq(metrics.totalInvestments, 0);
        assertEq(metrics.activeInvestments, 0);
        assertEq(metrics.totalDeployed, 0);
    }

    function testContractReferences() public view {
        assertEq(address(transparency.agentRegistry()), address(agentRegistry));
        assertEq(address(transparency.ddAttestation()), address(ddAttestation));
        assertEq(address(transparency.investmentRouter()), address(router));
        assertEq(address(transparency.pitchRegistry()), mockPitchRegistry);
        assertEq(address(transparency.axiomVault()), mockAxiomVault);
        assertEq(address(transparency.escrowFactory()), mockEscrowFactory);
    }
}