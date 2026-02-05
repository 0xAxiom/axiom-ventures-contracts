// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {InvestmentRouterV2} from "../../src/v2.1/InvestmentRouterV2.sol";
import {EscrowFactoryV2} from "../../src/v2.1/EscrowFactoryV2.sol";
import {AgentRegistry} from "../../src/v2/AgentRegistry.sol";
import {DDAttestation} from "../../src/v2/DDAttestation.sol";
import {PitchRegistry} from "../../src/PitchRegistry.sol";
import {AxiomVault} from "../../src/AxiomVault.sol";
import {MilestoneEscrow} from "../../src/MilestoneEscrow.sol";

contract InvestmentRouterV2Test is Test {
    InvestmentRouterV2 public router;
    EscrowFactoryV2 public escrowFactory;
    AgentRegistry public agentRegistry;
    DDAttestation public ddAttestation;
    PitchRegistry public pitchRegistry;
    AxiomVault public axiomVault;
    IERC20 public usdc;
    
    address public constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant SAFE_ADDRESS = 0x5766f573Cc516E3CA0D05a4848EF048636008271;
    
    address public deployer;
    address public agent;
    address public oracle;
    
    uint256 public agentId;
    uint256 public pitchId;

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork("https://mainnet.base.org");
        
        deployer = makeAddr("deployer");
        agent = makeAddr("agent");
        oracle = makeAddr("oracle");
        
        usdc = IERC20(USDC_ADDRESS);
        
        vm.startPrank(deployer);
        
        // Deploy contracts
        agentRegistry = new AgentRegistry(deployer);
        ddAttestation = new DDAttestation(deployer);
        pitchRegistry = new PitchRegistry(usdc, 0, deployer); // 0 fee for testing
        
        // Mock vault - deploy with deployer as initial owner
        axiomVault = new AxiomVault(usdc, deployer);
        
        escrowFactory = new EscrowFactoryV2(usdc, SAFE_ADDRESS, deployer);
        
        router = new InvestmentRouterV2(
            agentRegistry,
            ddAttestation,
            pitchRegistry,
            axiomVault,
            escrowFactory,
            deployer
        );
        
        // Set router as authorized in escrow factory
        escrowFactory.setRouter(address(router));
        
        // Transfer PitchRegistry ownership to deployer so tests can update status
        // In production, the Safe would have this permission
        // The router should NOT update pitch status - it should be done by the owner separately
        
        // Set up oracle
        ddAttestation.addOracle(oracle);
        
        vm.stopPrank();
        
        // Set up agent
        vm.prank(agent);
        agentId = agentRegistry.registerAgent("test-metadata-uri");
    }

    function test_Constructor() public {
        assertEq(address(router.agentRegistry()), address(agentRegistry));
        assertEq(address(router.ddAttestation()), address(ddAttestation));
        assertEq(address(router.pitchRegistry()), address(pitchRegistry));
        assertEq(address(router.axiomVault()), address(axiomVault));
        assertEq(address(router.escrowFactory()), address(escrowFactory));
        assertEq(router.owner(), deployer);
        assertEq(router.minDDScore(), 70);
    }

    function test_SubmitPitch() public {
        vm.startPrank(agent);
        
        pitchId = router.submitPitch(
            agentId,
            "QmTestIPFS",
            "Test Pitch",
            "Test Description",
            1000e6
        );
        
        vm.stopPrank();
        
        // Verify pitch was submitted
        assertEq(router.getPitchAgent(pitchId), agentId);
        assertTrue(pitchRegistry.pitchExists(pitchId));
        
        // Verify agent pitch mapping
        uint256[] memory agentPitches = router.getAgentPitches(agentId);
        assertEq(agentPitches.length, 1);
        assertEq(agentPitches[0], pitchId);
    }

    function test_SubmitPitch_NotAgentOwner() public {
        address notAgent = makeAddr("notAgent");
        
        vm.prank(notAgent);
        vm.expectRevert(InvestmentRouterV2.NotAgentOwner.selector);
        router.submitPitch(
            agentId,
            "QmTestIPFS", 
            "Test Pitch",
            "Test Description",
            1000e6
        );
    }

    function test_FundPitch() public {
        // Submit pitch first
        vm.prank(agent);
        pitchId = router.submitPitch(
            agentId,
            "QmTestIPFS",
            "Test Pitch", 
            "Test Description",
            1500e6
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
        
        // Add DD attestation with good score
        vm.prank(oracle);
        uint8[6] memory categoryScores = [80, 75, 85, 70, 60, 90];
        ddAttestation.attest(
            pitchId,
            80, // Composite score above minimum
            categoryScores,
            bytes32("QmDDReport")
        );
        
        // Fund pitch
        vm.startPrank(deployer);
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e6;
        amounts[1] = 500e6;
        
        string[] memory descriptions = new string[](2);
        descriptions[0] = "Milestone 1";
        descriptions[1] = "Milestone 2";
        
        router.fundPitch(
            pitchId,
            block.timestamp + 90 days,
            amounts,
            descriptions
        );
        
        // Manually update pitch status to funded (in production, Safe would do this)
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.Funded,
            "Funded via test"
        );
        
        vm.stopPrank();
        
        // Verify investment was created
        assertTrue(router.isPitchFunded(pitchId));
        assertEq(router.getFundedPitchCount(), 1);
        
        InvestmentRouterV2.InvestmentRecord memory investment = router.getInvestmentRecord(pitchId);
        assertEq(investment.agentId, agentId);
        assertTrue(investment.escrowAddress != address(0));
        assertEq(investment.fundedAt, block.timestamp);
        
        // Verify escrow was created with Safe as owner
        MilestoneEscrow escrow = MilestoneEscrow(investment.escrowAddress);
        assertEq(escrow.owner(), SAFE_ADDRESS);
        
        // Verify pitch status was updated
        PitchRegistry.Pitch memory pitch = pitchRegistry.getPitch(pitchId);
        assertEq(uint(pitch.status), uint(PitchRegistry.PitchStatus.Funded));
    }

    function test_FundPitch_PitchNotApproved() public {
        vm.prank(agent);
        pitchId = router.submitPitch(
            agentId,
            "QmTestIPFS",
            "Test Pitch",
            "Test Description", 
            1000e6
        );
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Test";
        
        vm.prank(deployer);
        vm.expectRevert(InvestmentRouterV2.PitchNotApproved.selector);
        router.fundPitch(pitchId, block.timestamp + 60 days, amounts, descriptions);
    }

    function test_FundPitch_NoAttestation() public {
        vm.prank(agent);
        pitchId = router.submitPitch(
            agentId,
            "QmTestIPFS",
            "Test Pitch",
            "Test Description",
            1000e6
        );
        
        // Move through proper status sequence
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.UnderReview,
            "Under review"
        );
        
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.Approved,
            "Approved"
        );
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Test";
        
        vm.prank(deployer);
        vm.expectRevert(InvestmentRouterV2.NoAttestationFound.selector);
        router.fundPitch(pitchId, block.timestamp + 60 days, amounts, descriptions);
    }

    function test_FundPitch_InsufficientDDScore() public {
        vm.prank(agent);
        pitchId = router.submitPitch(
            agentId,
            "QmTestIPFS",
            "Test Pitch",
            "Test Description",
            1000e6
        );
        
        // Move through proper status sequence
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.UnderReview,
            "Under review"
        );
        
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.Approved,
            "Approved"
        );
        
        // Add low DD score
        vm.prank(oracle);
        uint8[6] memory categoryScores = [50, 40, 60, 55, 45, 50];
        ddAttestation.attest(
            pitchId,
            50, // Below minimum of 70
            categoryScores,
            bytes32("QmDDReport")
        );
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Test";
        
        vm.prank(deployer);
        vm.expectRevert(InvestmentRouterV2.InsufficientDDScore.selector);
        router.fundPitch(pitchId, block.timestamp + 60 days, amounts, descriptions);
    }

    function test_FundPitch_AlreadyFunded() public {
        // Submit and fund pitch
        _setupAndFundPitch();
        
        // Try to fund again
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e6;
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Another milestone";
        
        vm.prank(deployer);
        vm.expectRevert(InvestmentRouterV2.PitchAlreadyFunded.selector);
        router.fundPitch(pitchId, block.timestamp + 60 days, amounts, descriptions);
    }

    function test_SetMinDDScore() public {
        vm.prank(deployer);
        router.setMinDDScore(80);
        assertEq(router.minDDScore(), 80);
    }

    function test_SetMinDDScore_OnlyOwner() public {
        vm.prank(agent);
        vm.expectRevert();
        router.setMinDDScore(80);
    }

    function test_SetMinDDScore_InvalidScore() public {
        vm.prank(deployer);
        vm.expectRevert(InvestmentRouterV2.InvalidScore.selector);
        router.setMinDDScore(101);
    }

    function test_GetAgentPitches_EfficientLookup() public {
        // Submit multiple pitches for same agent
        vm.startPrank(agent);
        
        uint256 pitch1 = router.submitPitch(agentId, "QmTest1", "Pitch 1", "Desc 1", 1000e6);
        uint256 pitch2 = router.submitPitch(agentId, "QmTest2", "Pitch 2", "Desc 2", 1500e6);
        uint256 pitch3 = router.submitPitch(agentId, "QmTest3", "Pitch 3", "Desc 3", 2000e6);
        
        vm.stopPrank();
        
        uint256[] memory agentPitches = router.getAgentPitches(agentId);
        assertEq(agentPitches.length, 3);
        assertEq(agentPitches[0], pitch1);
        assertEq(agentPitches[1], pitch2);
        assertEq(agentPitches[2], pitch3);
    }

    function test_GetInvestment() public {
        _setupAndFundPitch();
        
        (
            InvestmentRouterV2.InvestmentRecord memory investment,
            PitchRegistry.Pitch memory pitch,
            DDAttestation.Attestation memory attestation,
            address agentAddress
        ) = router.getInvestment(pitchId);
        
        assertEq(investment.agentId, agentId);
        assertTrue(investment.escrowAddress != address(0));
        assertEq(pitch.title, "Test Pitch");
        assertEq(attestation.compositeScore, 80);
        assertEq(agentAddress, agent);
    }

    function test_DidAgentSubmitPitch() public {
        vm.prank(agent);
        pitchId = router.submitPitch(
            agentId,
            "QmTestIPFS",
            "Test Pitch",
            "Test Description",
            1000e6
        );
        
        assertTrue(router.didAgentSubmitPitch(pitchId, agent));
        assertFalse(router.didAgentSubmitPitch(pitchId, deployer));
    }

    function test_GetFundedPitchRange() public {
        // Fund multiple pitches
        uint256[] memory pitchIds = new uint256[](5);
        for (uint i = 0; i < 5; i++) {
            pitchIds[i] = _createAndFundPitch(i);
        }
        
        // Test range
        uint256[] memory range = router.getFundedPitchRange(1, 4);
        assertEq(range.length, 3);
        assertEq(range[0], pitchIds[1]);
        assertEq(range[1], pitchIds[2]);
        assertEq(range[2], pitchIds[3]);
    }

    function test_OnlyOwnerFunctions() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Test";
        
        // Only owner can fund pitch
        vm.prank(agent);
        vm.expectRevert();
        router.fundPitch(1, block.timestamp + 60 days, amounts, descriptions);
    }

    // Helper functions
    function _setupAndFundPitch() internal {
        vm.prank(agent);
        pitchId = router.submitPitch(
            agentId,
            "QmTestIPFS",
            "Test Pitch",
            "Test Description",
            1500e6
        );
        
        // Move through proper status sequence
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.UnderReview,
            "Under review"
        );
        
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.Approved,
            "Approved"
        );
        
        vm.prank(oracle);
        uint8[6] memory categoryScores = [80, 75, 85, 70, 60, 90];
        ddAttestation.attest(pitchId, 80, categoryScores, bytes32("QmDDReport"));
        
        vm.startPrank(deployer);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e6;
        amounts[1] = 500e6;
        string[] memory descriptions = new string[](2);
        descriptions[0] = "Milestone 1";
        descriptions[1] = "Milestone 2";
        
        router.fundPitch(pitchId, block.timestamp + 90 days, amounts, descriptions);
        
        // Update pitch status manually (Safe would do this in production)
        pitchRegistry.updatePitchStatus(
            pitchId,
            PitchRegistry.PitchStatus.Funded,
            "Funded via test"
        );
        
        vm.stopPrank();
    }

    function _createAndFundPitch(uint256 index) internal returns (uint256 _pitchId) {
        vm.prank(agent);
        _pitchId = router.submitPitch(
            agentId,
            string(abi.encodePacked("QmTest", index)),
            string(abi.encodePacked("Pitch ", index)),
            string(abi.encodePacked("Desc ", index)),
            1000e6 + index * 100e6
        );
        
        // Move through proper status sequence
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            _pitchId,
            PitchRegistry.PitchStatus.UnderReview,
            "Under review"
        );
        
        vm.prank(deployer);
        pitchRegistry.updatePitchStatus(
            _pitchId,
            PitchRegistry.PitchStatus.Approved,
            "Approved"
        );
        
        vm.prank(oracle);
        uint8[6] memory categoryScores = [80, 75, 85, 70, 60, 90];
        ddAttestation.attest(_pitchId, 80, categoryScores, bytes32("QmDDReport"));
        
        vm.startPrank(deployer);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6 + index * 100e6;
        string[] memory descriptions = new string[](1);
        descriptions[0] = string(abi.encodePacked("Milestone ", index));
        
        router.fundPitch(_pitchId, block.timestamp + 90 days, amounts, descriptions);
        
        // Update pitch status manually (Safe would do this in production)
        pitchRegistry.updatePitchStatus(
            _pitchId,
            PitchRegistry.PitchStatus.Funded,
            "Funded via test"
        );
        
        vm.stopPrank();
    }
}