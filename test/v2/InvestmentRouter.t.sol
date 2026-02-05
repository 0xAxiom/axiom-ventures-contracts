// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import {InvestmentRouter} from "../../src/v2/InvestmentRouter.sol";
import {AgentRegistry} from "../../src/v2/AgentRegistry.sol";
import {DDAttestation} from "../../src/v2/DDAttestation.sol";
import {PitchRegistry} from "../../src/PitchRegistry.sol";
import {AxiomVault} from "../../src/AxiomVault.sol";
import {EscrowFactory} from "../../src/EscrowFactory.sol";

/**
 * @title InvestmentRouterTest
 * @dev Comprehensive tests for InvestmentRouter contract
 */
contract InvestmentRouterTest is Test {
    InvestmentRouter public router;
    AgentRegistry public agentRegistry;
    DDAttestation public ddAttestation;
    
    // Mock contracts
    address public mockPitchRegistry = makeAddr("pitchRegistry");
    address public mockAxiomVault = makeAddr("axiomVault");
    address public mockEscrowFactory = makeAddr("escrowFactory");
    address public mockEscrow = makeAddr("escrow");
    
    address public owner = makeAddr("owner");
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public nonAgent = makeAddr("nonAgent");
    address public oracle = makeAddr("oracle");
    
    uint256 constant AGENT_ID_1 = 1;
    uint256 constant AGENT_ID_2 = 2;
    uint256 constant PITCH_ID_1 = 1;
    uint256 constant PITCH_ID_2 = 2;
    uint256 constant FUNDING_REQUEST = 100000e6; // 100k USDC
    
    string constant METADATA_URI = "ipfs://QmTestHash123";
    string constant PITCH_TITLE = "Test Pitch";
    string constant PITCH_DESCRIPTION = "Test Description";
    string constant IPFS_HASH = "QmPitchHash456";

    event PitchSubmitted(uint256 indexed pitchId, uint256 indexed agentId, address indexed submitter);
    event InvestmentLinked(uint256 indexed pitchId, address indexed escrowAddress);

    function setUp() public {
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
        
        // Register agents
        vm.prank(owner);
        agentRegistry.grantIdentity(agent1, METADATA_URI);
        
        vm.prank(owner);
        agentRegistry.grantIdentity(agent2, METADATA_URI);
        
        // Add oracle
        vm.prank(owner);
        ddAttestation.addOracle(oracle);
        
        // Setup mock responses
        _setupMockResponses();
    }

    function _setupMockResponses() internal {
        // Mock PitchRegistry.submitPitch
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.submitPitch.selector),
            abi.encode(PITCH_ID_1)
        );
        
        // Mock PitchRegistry.pitchExists
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.pitchExists.selector),
            abi.encode(true)
        );
        
        // Mock EscrowFactory.isValidEscrow
        vm.mockCall(
            mockEscrowFactory,
            abi.encodeWithSelector(bytes4(keccak256("isValidEscrow(address)"))),
            abi.encode(true)
        );
        
        // Mock pitch data
        PitchRegistry.Pitch memory mockPitch = PitchRegistry.Pitch({
            submitter: agent1,
            ipfsHash: IPFS_HASH,
            title: PITCH_TITLE,
            description: PITCH_DESCRIPTION,
            fundingRequest: FUNDING_REQUEST,
            status: PitchRegistry.PitchStatus.Approved,
            submittedAt: block.timestamp,
            lastUpdated: block.timestamp,
            reviewer: address(0),
            reviewNotes: ""
        });
        
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.getPitch.selector, PITCH_ID_1),
            abi.encode(mockPitch)
        );
        
        // Mock updatePitchStatus
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.updatePitchStatus.selector),
            abi.encode()
        );
    }

    function testSubmitPitch() public {
        vm.prank(agent1);
        vm.expectEmit(true, true, true, false);
        emit PitchSubmitted(PITCH_ID_1, AGENT_ID_1, agent1);
        
        uint256 pitchId = router.submitPitch(
            AGENT_ID_1,
            IPFS_HASH,
            PITCH_TITLE,
            PITCH_DESCRIPTION,
            FUNDING_REQUEST
        );
        
        assertEq(pitchId, PITCH_ID_1);
        assertEq(router.getPitchAgent(PITCH_ID_1), AGENT_ID_1);
        assertTrue(router.didAgentSubmitPitch(PITCH_ID_1, agent1));
        assertFalse(router.didAgentSubmitPitch(PITCH_ID_1, agent2));
    }

    function test_RevertWhen_SubmitPitchNotAgentOwner() public {
        vm.prank(agent2); // agent2 doesn't own AGENT_ID_1
        vm.expectRevert(InvestmentRouter.NotAgentOwner.selector);
        router.submitPitch(
            AGENT_ID_1,
            IPFS_HASH,
            PITCH_TITLE,
            PITCH_DESCRIPTION,
            FUNDING_REQUEST
        );
    }

    function test_RevertWhen_SubmitPitchUnregisteredAgent() public {
        vm.prank(nonAgent);
        vm.expectRevert(); // Will revert when trying to call ownerOf on non-existent token
        router.submitPitch(
            999, // Non-existent agent ID
            IPFS_HASH,
            PITCH_TITLE,
            PITCH_DESCRIPTION,
            FUNDING_REQUEST
        );
    }

    function testLinkEscrow() public {
        // First submit a pitch
        vm.prank(agent1);
        router.submitPitch(
            AGENT_ID_1,
            IPFS_HASH,
            PITCH_TITLE,
            PITCH_DESCRIPTION,
            FUNDING_REQUEST
        );
        
        // Link escrow as owner
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit InvestmentLinked(PITCH_ID_1, mockEscrow);
        
        router.linkEscrow(PITCH_ID_1, mockEscrow);
        
        assertTrue(router.isPitchFunded(PITCH_ID_1));
        assertEq(router.getFundedPitchCount(), 1);
        
        InvestmentRouter.InvestmentRecord memory record = router.getInvestmentRecord(PITCH_ID_1);
        assertEq(record.agentId, AGENT_ID_1);
        assertEq(record.escrowAddress, mockEscrow);
        assertGt(record.fundedAt, 0);
    }

    function test_RevertWhen_LinkEscrowNonOwner() public {
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, IPFS_HASH, PITCH_TITLE, PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        vm.prank(agent1);
        vm.expectRevert();
        router.linkEscrow(PITCH_ID_1, mockEscrow);
    }

    function test_RevertWhen_LinkEscrowInvalidPitch() public {
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.pitchExists.selector, 999),
            abi.encode(false)
        );
        
        vm.prank(owner);
        vm.expectRevert(InvestmentRouter.PitchNotFound.selector);
        router.linkEscrow(999, mockEscrow);
    }

    function test_RevertWhen_LinkEscrowAlreadyFunded() public {
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, IPFS_HASH, PITCH_TITLE, PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        vm.prank(owner);
        router.linkEscrow(PITCH_ID_1, mockEscrow);
        
        vm.prank(owner);
        vm.expectRevert(InvestmentRouter.PitchAlreadyFunded.selector);
        router.linkEscrow(PITCH_ID_1, makeAddr("escrow2"));
    }

    function test_RevertWhen_LinkEscrowInvalidEscrow() public {
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, IPFS_HASH, PITCH_TITLE, PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        address invalidEscrow = makeAddr("invalidEscrow");
        vm.mockCall(
            mockEscrowFactory,
            abi.encodeWithSelector(bytes4(keccak256("isValidEscrow(address)")), invalidEscrow),
            abi.encode(false)
        );
        
        vm.prank(owner);
        vm.expectRevert(InvestmentRouter.InvalidEscrowAddress.selector);
        router.linkEscrow(PITCH_ID_1, invalidEscrow);
    }

    function test_RevertWhen_LinkEscrowInvalidStatus() public {
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, IPFS_HASH, PITCH_TITLE, PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        // Mock pitch with Submitted status
        PitchRegistry.Pitch memory mockPitch = PitchRegistry.Pitch({
            submitter: agent1,
            ipfsHash: IPFS_HASH,
            title: PITCH_TITLE,
            description: PITCH_DESCRIPTION,
            fundingRequest: FUNDING_REQUEST,
            status: PitchRegistry.PitchStatus.Submitted, // Invalid status
            submittedAt: block.timestamp,
            lastUpdated: block.timestamp,
            reviewer: address(0),
            reviewNotes: ""
        });
        
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.getPitch.selector, PITCH_ID_1),
            abi.encode(mockPitch)
        );
        
        vm.prank(owner);
        vm.expectRevert(InvestmentRouter.InvalidPitchStatus.selector);
        router.linkEscrow(PITCH_ID_1, mockEscrow);
    }

    function testGetInvestment() public {
        // Submit pitch
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, IPFS_HASH, PITCH_TITLE, PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        // Add DD attestation
        uint8[6] memory categoryScores = [90, 80, 85, 70, 95, 75];
        vm.prank(oracle);
        ddAttestation.attest(PITCH_ID_1, 85, categoryScores, keccak256("report"));
        
        // Link escrow
        vm.prank(owner);
        router.linkEscrow(PITCH_ID_1, mockEscrow);
        
        // Get investment details
        (
            InvestmentRouter.InvestmentRecord memory investment,
            PitchRegistry.Pitch memory pitch,
            DDAttestation.Attestation memory attestation,
            address agentAddress
        ) = router.getInvestment(PITCH_ID_1);
        
        assertEq(investment.agentId, AGENT_ID_1);
        assertEq(investment.escrowAddress, mockEscrow);
        assertEq(pitch.title, PITCH_TITLE);
        assertEq(attestation.compositeScore, 85);
        assertEq(agentAddress, agent1);
    }

    function testGetAgentPitches() public {
        // Submit multiple pitches
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.submitPitch.selector),
            abi.encode(PITCH_ID_1)
        );
        
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, IPFS_HASH, PITCH_TITLE, PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        // Mock second pitch
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.submitPitch.selector),
            abi.encode(PITCH_ID_2)
        );
        
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, IPFS_HASH, "Pitch 2", PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        // Mock nextPitchId (getAgentPitches now scans pitchToAgent mapping)
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSignature("nextPitchId()"),
            abi.encode(uint256(3)) // pitches 1 and 2 exist
        );
        
        uint256[] memory agentPitches = router.getAgentPitches(AGENT_ID_1);
        assertEq(agentPitches.length, 2);
        assertEq(agentPitches[0], PITCH_ID_1);
        assertEq(agentPitches[1], PITCH_ID_2);
    }

    function testGetFundedPitchRange() public {
        // Submit and fund multiple pitches
        vm.prank(agent1);
        router.submitPitch(AGENT_ID_1, IPFS_HASH, PITCH_TITLE, PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        vm.prank(owner);
        router.linkEscrow(PITCH_ID_1, mockEscrow);
        
        // Mock second pitch submission and funding
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.submitPitch.selector),
            abi.encode(PITCH_ID_2)
        );
        
        vm.prank(agent2);
        router.submitPitch(AGENT_ID_2, IPFS_HASH, "Pitch 2", PITCH_DESCRIPTION, FUNDING_REQUEST);
        
        vm.mockCall(
            mockPitchRegistry,
            abi.encodeWithSelector(PitchRegistry.getPitch.selector, PITCH_ID_2),
            abi.encode(PitchRegistry.Pitch({
                submitter: agent2,
                ipfsHash: IPFS_HASH,
                title: "Pitch 2",
                description: PITCH_DESCRIPTION,
                fundingRequest: FUNDING_REQUEST,
                status: PitchRegistry.PitchStatus.Approved,
                submittedAt: block.timestamp,
                lastUpdated: block.timestamp,
                reviewer: address(0),
                reviewNotes: ""
            }))
        );
        
        address mockEscrow2 = makeAddr("escrow2");
        vm.prank(owner);
        router.linkEscrow(PITCH_ID_2, mockEscrow2);
        
        assertEq(router.getFundedPitchCount(), 2);
        
        uint256[] memory range = router.getFundedPitchRange(0, 2);
        assertEq(range.length, 2);
        assertEq(range[0], PITCH_ID_1);
        assertEq(range[1], PITCH_ID_2);
        
        uint256[] memory partialRange = router.getFundedPitchRange(1, 2);
        assertEq(partialRange.length, 1);
        assertEq(partialRange[0], PITCH_ID_2);
    }

    function test_RevertWhen_GetFundedPitchRangeInvalid() public {
        vm.expectRevert("Invalid range");
        router.getFundedPitchRange(1, 0);
    }

    function test_RevertWhen_GetInvestmentNotFunded() public {
        vm.expectRevert(InvestmentRouter.PitchNotFound.selector);
        router.getInvestment(999);
    }

    function test_RevertWhen_GetInvestmentRecordNotFunded() public {
        vm.expectRevert(InvestmentRouter.PitchNotFound.selector);
        router.getInvestmentRecord(999);
    }

    function testDidAgentSubmitPitchWithNonexistentAgent() public {
        assertFalse(router.didAgentSubmitPitch(999, agent1));
    }

    function testPitchAgentMappingForNonRouterPitch() public {
        assertEq(router.getPitchAgent(999), 0);
    }
}