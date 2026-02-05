// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DDAttestation} from "../../src/v2/DDAttestation.sol";

/**
 * @title DDAttestationTest
 * @dev Comprehensive tests for DDAttestation contract
 */
contract DDAttestationTest is Test {
    DDAttestation public ddAttestation;
    
    address public owner = makeAddr("owner");
    address public oracle1 = makeAddr("oracle1");
    address public oracle2 = makeAddr("oracle2");
    address public nonOracle = makeAddr("nonOracle");
    
    uint256 constant PITCH_ID = 1;
    uint256 constant PITCH_ID_2 = 2;
    uint8 constant COMPOSITE_SCORE = 85;
    uint8[6] public categoryScores = [90, 80, 85, 70, 95, 75]; // revenue, code, onchain, market, team, ask
    bytes32 constant REPORT_HASH = keccak256("DD Report Content");

    event AttestationPosted(uint256 indexed pitchId, uint8 compositeScore, address indexed oracle);
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);

    function setUp() public {
        vm.prank(owner);
        ddAttestation = new DDAttestation(owner);
        
        // Add oracle
        vm.prank(owner);
        ddAttestation.addOracle(oracle1);
    }

    function testInitialState() public view {
        assertEq(ddAttestation.owner(), owner);
        assertEq(ddAttestation.isAuthorizedOracle(oracle1), true);
        assertEq(ddAttestation.isAuthorizedOracle(oracle2), false);
        assertEq(ddAttestation.hasAttestation(PITCH_ID), false);
        
        // Test category weights
        uint8[6] memory expectedWeights = [25, 20, 20, 15, 10, 10];
        uint8[6] memory actualWeights = ddAttestation.getAllCategoryWeights();
        for (uint i = 0; i < 6; i++) {
            assertEq(actualWeights[i], expectedWeights[i]);
        }
    }

    function testAttestSuccessfully() public {
        vm.prank(oracle1);
        vm.expectEmit(true, false, true, true);
        emit AttestationPosted(PITCH_ID, COMPOSITE_SCORE, oracle1);
        
        ddAttestation.attest(PITCH_ID, COMPOSITE_SCORE, categoryScores, REPORT_HASH);
        
        assertTrue(ddAttestation.hasAttestation(PITCH_ID));
        assertEq(ddAttestation.getScore(PITCH_ID), COMPOSITE_SCORE);
        assertTrue(ddAttestation.hasPassingScore(PITCH_ID, 80));
        assertFalse(ddAttestation.hasPassingScore(PITCH_ID, 90));
        
        DDAttestation.Attestation memory attestation = ddAttestation.getAttestation(PITCH_ID);
        assertEq(attestation.compositeScore, COMPOSITE_SCORE);
        assertEq(attestation.reportIPFS, REPORT_HASH);
        assertEq(attestation.oracle, oracle1);
        assertGt(attestation.attestedAt, 0);
        
        uint8[6] memory retrievedScores = ddAttestation.getCategoryScores(PITCH_ID);
        for (uint i = 0; i < 6; i++) {
            assertEq(retrievedScores[i], categoryScores[i]);
        }
    }

    function test_RevertWhen_UnauthorizedOracleAttest() public {
        vm.prank(nonOracle);
        vm.expectRevert(DDAttestation.OracleNotAuthorized.selector);
        ddAttestation.attest(PITCH_ID, COMPOSITE_SCORE, categoryScores, REPORT_HASH);
    }

    function test_RevertWhen_DoubleAttestation() public {
        vm.prank(oracle1);
        ddAttestation.attest(PITCH_ID, COMPOSITE_SCORE, categoryScores, REPORT_HASH);
        
        vm.prank(oracle1);
        vm.expectRevert(DDAttestation.AttestationAlreadyExists.selector);
        ddAttestation.attest(PITCH_ID, 90, categoryScores, REPORT_HASH);
    }

    function test_RevertWhen_InvalidCompositeScore() public {
        vm.prank(oracle1);
        vm.expectRevert(DDAttestation.InvalidScore.selector);
        ddAttestation.attest(PITCH_ID, 101, categoryScores, REPORT_HASH);
    }

    function test_RevertWhen_InvalidCategoryScore() public {
        uint8[6] memory invalidScores = [90, 80, 101, 70, 95, 75]; // onChainHistory = 101
        
        vm.prank(oracle1);
        vm.expectRevert(DDAttestation.InvalidScore.selector);
        ddAttestation.attest(PITCH_ID, COMPOSITE_SCORE, invalidScores, REPORT_HASH);
    }

    function test_RevertWhen_EmptyReportHash() public {
        vm.prank(oracle1);
        vm.expectRevert(DDAttestation.EmptyReportHash.selector);
        ddAttestation.attest(PITCH_ID, COMPOSITE_SCORE, categoryScores, bytes32(0));
    }

    function testAddOracle() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit OracleAdded(oracle2);
        
        ddAttestation.addOracle(oracle2);
        
        assertTrue(ddAttestation.isAuthorizedOracle(oracle2));
    }

    function test_RevertWhen_AddExistingOracle() public {
        vm.prank(owner);
        vm.expectRevert(DDAttestation.OracleAlreadyAuthorized.selector);
        ddAttestation.addOracle(oracle1);
    }

    function test_RevertWhen_NonOwnerAddOracle() public {
        vm.prank(nonOracle);
        vm.expectRevert();
        ddAttestation.addOracle(oracle2);
    }

    function testRemoveOracle() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit OracleRemoved(oracle1);
        
        ddAttestation.removeOracle(oracle1);
        
        assertFalse(ddAttestation.isAuthorizedOracle(oracle1));
    }

    function test_RevertWhen_RemoveNonexistentOracle() public {
        vm.prank(owner);
        vm.expectRevert(DDAttestation.OracleNotCurrentlyAuthorized.selector);
        ddAttestation.removeOracle(oracle2);
    }

    function test_RevertWhen_NonOwnerRemoveOracle() public {
        vm.prank(nonOracle);
        vm.expectRevert();
        ddAttestation.removeOracle(oracle1);
    }

    function testMultipleOracles() public {
        // Add second oracle
        vm.prank(owner);
        ddAttestation.addOracle(oracle2);
        
        // First oracle attests to pitch 1
        vm.prank(oracle1);
        ddAttestation.attest(PITCH_ID, COMPOSITE_SCORE, categoryScores, REPORT_HASH);
        
        // Second oracle attests to pitch 2
        uint8[6] memory scores2 = [80, 90, 75, 85, 80, 90];
        vm.prank(oracle2);
        ddAttestation.attest(PITCH_ID_2, 82, scores2, keccak256("Report 2"));
        
        assertTrue(ddAttestation.hasAttestation(PITCH_ID));
        assertTrue(ddAttestation.hasAttestation(PITCH_ID_2));
        
        DDAttestation.Attestation memory attestation1 = ddAttestation.getAttestation(PITCH_ID);
        DDAttestation.Attestation memory attestation2 = ddAttestation.getAttestation(PITCH_ID_2);
        
        assertEq(attestation1.oracle, oracle1);
        assertEq(attestation2.oracle, oracle2);
    }

    function testCalculateCompositeScore() public view {
        // Test with perfect weighted score
        uint8[6] memory perfectScores = [100, 100, 100, 100, 100, 100];
        uint8 result = ddAttestation.calculateCompositeScore(perfectScores);
        assertEq(result, 100);
        
        // Test with zeros
        uint8[6] memory zeroScores = [0, 0, 0, 0, 0, 0];
        result = ddAttestation.calculateCompositeScore(zeroScores);
        assertEq(result, 0);
        
        // Test with category scores: [90, 80, 85, 70, 95, 75]
        // Expected: (90*25 + 80*20 + 85*20 + 70*15 + 95*10 + 75*10) / 100
        // = (2250 + 1600 + 1700 + 1050 + 950 + 750) / 100 = 8300/100 = 83
        result = ddAttestation.calculateCompositeScore(categoryScores);
        assertEq(result, 83);
    }

    function test_RevertWhen_CalculateInvalidScore() public {
        uint8[6] memory invalidScores = [101, 80, 85, 70, 95, 75];
        vm.expectRevert();
        ddAttestation.calculateCompositeScore(invalidScores);
    }

    function testGetCategoryWeight() public view {
        assertEq(ddAttestation.getCategoryWeight(0), 25); // revenue
        assertEq(ddAttestation.getCategoryWeight(1), 20); // code quality
        assertEq(ddAttestation.getCategoryWeight(2), 20); // onchain history
        assertEq(ddAttestation.getCategoryWeight(3), 15); // market position
        assertEq(ddAttestation.getCategoryWeight(4), 10); // team quality
        assertEq(ddAttestation.getCategoryWeight(5), 10); // ask reasonableness
    }

    function test_RevertWhen_InvalidCategoryIndex() public {
        vm.expectRevert();
        ddAttestation.getCategoryWeight(6);
    }

    function testGetAttestationForNonexistent() public {
        vm.expectRevert(DDAttestation.NoAttestationFound.selector);
        ddAttestation.getAttestation(999);
    }

    function testGetCategoryScoresForNonexistent() public {
        vm.expectRevert(DDAttestation.NoAttestationFound.selector);
        ddAttestation.getCategoryScores(999);
    }

    function testHasPassingScoreForNonexistent() public view {
        assertFalse(ddAttestation.hasPassingScore(999, 50));
    }

    function testGetScoreForNonexistent() public view {
        assertEq(ddAttestation.getScore(999), 0);
    }

    function testEdgeCaseScores() public {
        // Test with minimum scores
        uint8[6] memory minScores = [0, 0, 0, 0, 0, 0];
        vm.prank(oracle1);
        ddAttestation.attest(PITCH_ID, 0, minScores, REPORT_HASH);
        
        assertEq(ddAttestation.getScore(PITCH_ID), 0);
        assertFalse(ddAttestation.hasPassingScore(PITCH_ID, 1));
        assertTrue(ddAttestation.hasPassingScore(PITCH_ID, 0));
    }

    function testMaxScores() public {
        // Test with maximum scores
        uint8[6] memory maxScores = [100, 100, 100, 100, 100, 100];
        vm.prank(oracle1);
        ddAttestation.attest(PITCH_ID, 100, maxScores, REPORT_HASH);
        
        assertEq(ddAttestation.getScore(PITCH_ID), 100);
        assertTrue(ddAttestation.hasPassingScore(PITCH_ID, 100));
        assertFalse(ddAttestation.hasPassingScore(PITCH_ID, 101)); // Invalid but handled
    }
}