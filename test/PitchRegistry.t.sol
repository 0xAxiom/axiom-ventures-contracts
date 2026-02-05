// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PitchRegistry} from "../src/PitchRegistry.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract PitchRegistryTest is Test {
    PitchRegistry public registry;
    ERC20Mock public usdc;
    
    address public owner = address(1);
    address public submitter1 = address(2);
    address public submitter2 = address(3);
    
    uint256 constant SUBMIT_FEE = 10e6; // $10 USDC
    uint256 constant FUNDING_REQUEST = 100_000e6; // $100k
    
    string constant IPFS_HASH = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
    string constant TITLE = "AI-Powered DeFi Protocol";
    string constant DESCRIPTION = "Revolutionary DeFi protocol using AI for yield optimization";

    function setUp() public {
        usdc = new ERC20Mock();
        registry = new PitchRegistry(IERC20(address(usdc)), SUBMIT_FEE, owner);
        
        // Fund submitters
        usdc.mint(submitter1, 1000e6);
        usdc.mint(submitter2, 1000e6);
        
        // Approve registry
        vm.prank(submitter1);
        usdc.approve(address(registry), type(uint256).max);
        
        vm.prank(submitter2);
        usdc.approve(address(registry), type(uint256).max);
    }

    function test_InitialState() public view {
        assertEq(address(registry.asset()), address(usdc));
        assertEq(registry.submitFee(), SUBMIT_FEE);
        assertEq(registry.owner(), owner);
        assertEq(registry.nextPitchId(), 1);
        assertEq(registry.getTotalPitchCount(), 0);
    }

    function test_SubmitPitch() public {
        uint256 submitterBalanceBefore = usdc.balanceOf(submitter1);
        uint256 registryBalanceBefore = usdc.balanceOf(address(registry));
        
        vm.prank(submitter1);
        uint256 pitchId = registry.submitPitch(
            IPFS_HASH,
            TITLE,
            DESCRIPTION,
            FUNDING_REQUEST
        );
        
        // Check pitch ID and counts
        assertEq(pitchId, 1);
        assertEq(registry.nextPitchId(), 2);
        assertEq(registry.getTotalPitchCount(), 1);
        
        // Check fee payment
        assertEq(usdc.balanceOf(submitter1), submitterBalanceBefore - SUBMIT_FEE);
        assertEq(usdc.balanceOf(address(registry)), registryBalanceBefore + SUBMIT_FEE);
        
        // Check pitch data
        PitchRegistry.Pitch memory pitch = registry.getPitch(pitchId);
        assertEq(pitch.submitter, submitter1);
        assertEq(pitch.ipfsHash, IPFS_HASH);
        assertEq(pitch.title, TITLE);
        assertEq(pitch.description, DESCRIPTION);
        assertEq(pitch.fundingRequest, FUNDING_REQUEST);
        assertEq(uint(pitch.status), uint(PitchRegistry.PitchStatus.Submitted));
        assertEq(pitch.submittedAt, block.timestamp);
        assertEq(pitch.lastUpdated, block.timestamp);
        assertEq(pitch.reviewer, address(0));
        assertEq(pitch.reviewNotes, "");
    }

    function test_SubmitMultiplePitches() public {
        // Submit first pitch
        vm.prank(submitter1);
        uint256 pitch1 = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        // Submit second pitch by different user
        vm.prank(submitter2);
        uint256 pitch2 = registry.submitPitch(
            "QmOtherHash",
            "DeFi 2.0 Platform",
            "Next generation DeFi",
            200_000e6
        );
        
        assertEq(pitch1, 1);
        assertEq(pitch2, 2);
        assertEq(registry.getTotalPitchCount(), 2);
        
        // Check submitter mappings
        uint256[] memory submitter1Pitches = registry.getPitchesBySubmitter(submitter1);
        uint256[] memory submitter2Pitches = registry.getPitchesBySubmitter(submitter2);
        
        assertEq(submitter1Pitches.length, 1);
        assertEq(submitter1Pitches[0], pitch1);
        
        assertEq(submitter2Pitches.length, 1);
        assertEq(submitter2Pitches[0], pitch2);
    }

    function test_UpdatePitchStatus() public {
        vm.prank(submitter1);
        uint256 pitchId = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        string memory reviewNotes = "Looks promising, needs more technical details";
        
        vm.prank(owner);
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.UnderReview, reviewNotes);
        
        PitchRegistry.Pitch memory pitch = registry.getPitch(pitchId);
        assertEq(uint(pitch.status), uint(PitchRegistry.PitchStatus.UnderReview));
        assertEq(pitch.reviewer, owner);
        assertEq(pitch.reviewNotes, reviewNotes);
        assertEq(pitch.lastUpdated, block.timestamp);
    }

    function test_StatusTransitions() public {
        vm.prank(submitter1);
        uint256 pitchId = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        // Submitted -> UnderReview
        vm.prank(owner);
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.UnderReview, "Reviewing");
        
        // UnderReview -> Approved
        vm.prank(owner);
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.Approved, "Approved for funding");
        
        // Approved -> Funded
        vm.prank(owner);
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.Funded, "Investment completed");
        
        PitchRegistry.Pitch memory pitch = registry.getPitch(pitchId);
        assertEq(uint(pitch.status), uint(PitchRegistry.PitchStatus.Funded));
    }

    function test_InvalidStatusTransitions() public {
        vm.prank(submitter1);
        uint256 pitchId = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        // Submitted cannot go directly to Funded
        vm.prank(owner);
        vm.expectRevert(PitchRegistry.StatusUpdateNotAllowed.selector);
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.Funded, "Invalid");
        
        // Set to UnderReview first
        vm.prank(owner);
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.UnderReview, "Reviewing");
        
        // Cannot go back to Submitted
        vm.prank(owner);
        vm.expectRevert(PitchRegistry.StatusUpdateNotAllowed.selector);
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.Submitted, "Invalid");
    }

    function test_OnlyOwnerCanUpdateStatus() public {
        vm.prank(submitter1);
        uint256 pitchId = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        vm.prank(submitter1);
        vm.expectRevert();
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.UnderReview, "Unauthorized");
    }

    function test_GetPitchesByStatus() public {
        // Submit multiple pitches
        vm.prank(submitter1);
        uint256 pitch1 = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        vm.prank(submitter2);
        uint256 pitch2 = registry.submitPitch("Hash2", "Title2", "Desc2", 50_000e6);
        
        // Both should be in Submitted status
        uint256[] memory submittedPitches = registry.getPitchesByStatus(PitchRegistry.PitchStatus.Submitted);
        assertEq(submittedPitches.length, 2);
        
        // Move one to UnderReview
        vm.prank(owner);
        registry.updatePitchStatus(pitch1, PitchRegistry.PitchStatus.UnderReview, "Reviewing");
        
        // Check status filtering
        submittedPitches = registry.getPitchesByStatus(PitchRegistry.PitchStatus.Submitted);
        assertEq(submittedPitches.length, 1);
        assertEq(submittedPitches[0], pitch2);
        
        uint256[] memory underReviewPitches = registry.getPitchesByStatus(PitchRegistry.PitchStatus.UnderReview);
        assertEq(underReviewPitches.length, 1);
        assertEq(underReviewPitches[0], pitch1);
    }

    function test_UpdateSubmitFee() public {
        uint256 newFee = 25e6; // $25 USDC
        
        vm.prank(owner);
        registry.updateSubmitFee(newFee);
        
        assertEq(registry.submitFee(), newFee);
        
        // Test new fee is required
        vm.prank(submitter1);
        registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        assertEq(usdc.balanceOf(address(registry)), newFee);
    }

    function test_WithdrawFees() public {
        // Submit a pitch to generate fees
        vm.prank(submitter1);
        registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        address recipient = address(999);
        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        
        vm.prank(owner);
        registry.withdrawFees(recipient);
        
        assertEq(usdc.balanceOf(address(registry)), 0);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + SUBMIT_FEE);
    }

    function test_ZeroFeeSubmission() public {
        // Deploy registry with zero fee
        PitchRegistry zeroFeeRegistry = new PitchRegistry(IERC20(address(usdc)), 0, owner);
        
        vm.prank(submitter1);
        uint256 pitchId = zeroFeeRegistry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        assertEq(pitchId, 1);
        assertEq(usdc.balanceOf(address(zeroFeeRegistry)), 0); // No fee collected
    }

    function test_InvalidSubmissions() public {
        // Empty title
        vm.prank(submitter1);
        vm.expectRevert(PitchRegistry.EmptyTitle.selector);
        registry.submitPitch(IPFS_HASH, "", DESCRIPTION, FUNDING_REQUEST);
        
        // Empty IPFS hash
        vm.prank(submitter1);
        vm.expectRevert(PitchRegistry.InvalidIPFS.selector);
        registry.submitPitch("", TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        // Zero funding request
        vm.prank(submitter1);
        vm.expectRevert(PitchRegistry.InvalidFundingRequest.selector);
        registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, 0);
    }

    function test_InsufficientFeePayment() public {
        // User with insufficient USDC
        address poorUser = address(999);
        usdc.mint(poorUser, SUBMIT_FEE - 1); // Not enough
        
        vm.prank(poorUser);
        usdc.approve(address(registry), type(uint256).max);
        
        vm.prank(poorUser);
        vm.expectRevert();
        registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
    }

    function test_PitchNotFound() public {
        vm.expectRevert(PitchRegistry.PitchNotFound.selector);
        registry.getPitch(999);
        
        vm.expectRevert(PitchRegistry.PitchNotFound.selector);
        registry.getPitch(0);
    }

    function test_PitchExists() public {
        assertFalse(registry.pitchExists(1));
        
        vm.prank(submitter1);
        uint256 pitchId = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        assertTrue(registry.pitchExists(pitchId));
        assertFalse(registry.pitchExists(pitchId + 1));
    }

    function test_GetPitchRange() public {
        // Submit multiple pitches
        vm.prank(submitter1);
        registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        vm.prank(submitter1);
        registry.submitPitch("Hash2", "Title2", "Desc2", FUNDING_REQUEST);
        
        vm.prank(submitter1);
        registry.submitPitch("Hash3", "Title3", "Desc3", FUNDING_REQUEST);
        
        // Get range
        uint256[] memory range = registry.getPitchRange(1, 3);
        assertEq(range.length, 2);
        assertEq(range[0], 2); // Second pitch
        assertEq(range[1], 3); // Third pitch
        
        // Invalid range
        vm.expectRevert("Invalid range");
        registry.getPitchRange(3, 2); // start > end
        
        vm.expectRevert("Invalid range");
        registry.getPitchRange(0, 5); // end > length
    }

    function test_GetTotalFundingRequested() public {
        uint256 request1 = 100_000e6;
        uint256 request2 = 200_000e6;
        uint256 request3 = 50_000e6;
        
        vm.prank(submitter1);
        uint256 pitch1 = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, request1);
        
        vm.prank(submitter1);
        uint256 pitch2 = registry.submitPitch("Hash2", "Title2", "Desc2", request2);
        
        vm.prank(submitter1);
        uint256 pitch3 = registry.submitPitch("Hash3", "Title3", "Desc3", request3);
        
        // All pitches are submitted
        uint256 totalSubmitted = registry.getTotalFundingRequested(PitchRegistry.PitchStatus.Submitted);
        assertEq(totalSubmitted, request1 + request2 + request3);
        
        // Move one to approved
        vm.prank(owner);
        registry.updatePitchStatus(pitch1, PitchRegistry.PitchStatus.UnderReview, "Reviewing");
        vm.prank(owner);
        registry.updatePitchStatus(pitch1, PitchRegistry.PitchStatus.Approved, "Approved");
        
        // Check approved total
        uint256 totalApproved = registry.getTotalFundingRequested(PitchRegistry.PitchStatus.Approved);
        assertEq(totalApproved, request1);
        
        // Submitted should be reduced
        totalSubmitted = registry.getTotalFundingRequested(PitchRegistry.PitchStatus.Submitted);
        assertEq(totalSubmitted, request2 + request3);
    }

    function test_GetAllPitchIds() public {
        vm.prank(submitter1);
        registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        vm.prank(submitter1);
        registry.submitPitch("Hash2", "Title2", "Desc2", FUNDING_REQUEST);
        
        uint256[] memory allIds = registry.getAllPitchIds();
        assertEq(allIds.length, 2);
        assertEq(allIds[0], 1);
        assertEq(allIds[1], 2);
    }

    function test_GetFeesBalance() public {
        assertEq(registry.getFeesBalance(), 0);
        
        vm.prank(submitter1);
        registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        assertEq(registry.getFeesBalance(), SUBMIT_FEE);
    }

    function test_Events() public {
        vm.expectEmit(true, true, false, true);
        emit PitchRegistry.PitchSubmitted(1, submitter1, TITLE, FUNDING_REQUEST, SUBMIT_FEE);
        
        vm.prank(submitter1);
        uint256 pitchId = registry.submitPitch(IPFS_HASH, TITLE, DESCRIPTION, FUNDING_REQUEST);
        
        vm.expectEmit(true, false, false, true);
        emit PitchRegistry.PitchStatusUpdated(
            pitchId,
            PitchRegistry.PitchStatus.Submitted,
            PitchRegistry.PitchStatus.UnderReview,
            owner,
            "Under review"
        );
        
        vm.prank(owner);
        registry.updatePitchStatus(pitchId, PitchRegistry.PitchStatus.UnderReview, "Under review");
    }
}