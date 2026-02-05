// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract MilestoneEscrowTest is Test {
    MilestoneEscrow public escrow;
    ERC20Mock public usdc;
    
    address public vault = address(1);
    address public recipient = address(2);
    uint256 public deadline;
    
    uint256[] amounts;
    string[] descriptions;
    
    uint256 constant TOTAL_AMOUNT = 30_000e6; // $30k

    function setUp() public {
        usdc = new ERC20Mock();
        deadline = block.timestamp + 365 days; // 1 year from now
        
        // Setup milestone data
        amounts.push(10_000e6); // $10k for milestone 1
        amounts.push(15_000e6); // $15k for milestone 2  
        amounts.push(5_000e6);  // $5k for milestone 3
        
        descriptions.push("MVP Development");
        descriptions.push("Beta Launch");
        descriptions.push("Market Validation");
        
        // Deploy escrow
        escrow = new MilestoneEscrow(
            IERC20(address(usdc)),
            vault,
            recipient,
            deadline,
            amounts,
            descriptions
        );
        
        // Fund vault and escrow
        usdc.mint(vault, TOTAL_AMOUNT);
        vm.prank(vault);
        usdc.approve(address(escrow), TOTAL_AMOUNT);
    }

    function test_InitialState() public view {
        assertEq(address(escrow.asset()), address(usdc));
        assertEq(escrow.vault(), vault);
        assertEq(escrow.recipient(), recipient);
        assertEq(escrow.deadline(), deadline);
        assertEq(escrow.totalAmount(), TOTAL_AMOUNT);
        assertEq(escrow.totalReleased(), 0);
        assertEq(escrow.getMilestoneCount(), 3);
        assertFalse(escrow.isClawedBack());
        assertFalse(escrow.isExpired());
    }

    function test_Funding() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        assertEq(usdc.balanceOf(address(escrow)), TOTAL_AMOUNT);
    }

    function test_GetMilestone() public view {
        MilestoneEscrow.Milestone memory milestone = escrow.getMilestone(0);
        
        assertEq(milestone.amount, 10_000e6);
        assertEq(milestone.description, "MVP Development");
        assertEq(uint(milestone.status), uint(MilestoneEscrow.MilestoneStatus.Pending));
        assertEq(milestone.releasedAt, 0);
    }

    function test_ReleaseMilestone() public {
        // Fund escrow first
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        
        // Release first milestone
        vm.prank(vault); // Only owner (vault) can release
        escrow.releaseMilestone(0);
        
        // Check state updates
        assertEq(escrow.totalReleased(), 10_000e6);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + 10_000e6);
        
        MilestoneEscrow.Milestone memory milestone = escrow.getMilestone(0);
        assertEq(uint(milestone.status), uint(MilestoneEscrow.MilestoneStatus.Released));
        assertEq(milestone.releasedAt, block.timestamp);
    }

    function test_ReleaseMultipleMilestones() public {
        // Fund escrow
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        uint256[] memory milestoneIds = new uint256[](2);
        milestoneIds[0] = 0;
        milestoneIds[1] = 1;
        
        vm.prank(vault);
        escrow.releaseMultipleMilestones(milestoneIds);
        
        assertEq(escrow.totalReleased(), 25_000e6); // $10k + $15k
        assertEq(usdc.balanceOf(recipient), 25_000e6);
    }

    function test_OnlyVaultCanRelease() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        // Non-vault address tries to release
        vm.prank(recipient);
        vm.expectRevert();
        escrow.releaseMilestone(0);
        
        // Random address tries to release
        vm.prank(address(999));
        vm.expectRevert();
        escrow.releaseMilestone(0);
    }

    function test_CannotReleaseAfterDeadline() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        // Fast forward past deadline
        vm.warp(deadline + 1);
        
        vm.prank(vault);
        vm.expectRevert(MilestoneEscrow.DeadlinePassed.selector);
        escrow.releaseMilestone(0);
    }

    function test_CannotReleaseSameMilestoneTwice() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        // Release first time
        vm.prank(vault);
        escrow.releaseMilestone(0);
        
        // Try to release again
        vm.prank(vault);
        vm.expectRevert(MilestoneEscrow.MilestoneAlreadyProcessed.selector);
        escrow.releaseMilestone(0);
    }

    function test_EmergencyClawback() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        // Release one milestone first
        vm.prank(vault);
        escrow.releaseMilestone(0);
        
        uint256 vaultBalanceBefore = usdc.balanceOf(vault);
        uint256 unreleasedAmount = escrow.getUnreleasedAmount();
        
        // Emergency clawback
        vm.prank(vault);
        escrow.emergencyClawback();
        
        assertEq(usdc.balanceOf(vault), vaultBalanceBefore + unreleasedAmount);
        assertTrue(escrow.isClawedBack());
        assertEq(escrow.getUnreleasedAmount(), 0);
        
        // Check that pending milestones are marked as clawed
        MilestoneEscrow.Milestone memory milestone1 = escrow.getMilestone(1);
        assertEq(uint(milestone1.status), uint(MilestoneEscrow.MilestoneStatus.Clawed));
    }

    function test_AutoClawback() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        // Fast forward past deadline
        vm.warp(deadline + 1);
        assertTrue(escrow.isExpired());
        
        uint256 vaultBalanceBefore = usdc.balanceOf(vault);
        
        // Anyone can trigger auto clawback after deadline
        vm.prank(address(999));
        escrow.autoClawback();
        
        assertEq(usdc.balanceOf(vault), vaultBalanceBefore + TOTAL_AMOUNT);
        assertTrue(escrow.isClawedBack());
    }

    function test_AutoClawbackBeforeDeadlineFails() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        vm.expectRevert(MilestoneEscrow.DeadlineNotPassed.selector);
        escrow.autoClawback();
    }

    function test_CannotOperateAfterClawback() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        // Emergency clawback
        vm.prank(vault);
        escrow.emergencyClawback();
        
        // Try to release milestone after clawback
        vm.prank(vault);
        vm.expectRevert(MilestoneEscrow.EscrowClawedBack.selector);
        escrow.releaseMilestone(0);
    }

    function test_GetAllMilestones() public view {
        MilestoneEscrow.Milestone[] memory milestones = escrow.getAllMilestones();
        
        assertEq(milestones.length, 3);
        assertEq(milestones[0].amount, 10_000e6);
        assertEq(milestones[1].amount, 15_000e6);
        assertEq(milestones[2].amount, 5_000e6);
    }

    function test_GetPendingMilestoneCount() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        assertEq(escrow.getPendingMilestoneCount(), 3);
        
        // Release one milestone
        vm.prank(vault);
        escrow.releaseMilestone(0);
        
        assertEq(escrow.getPendingMilestoneCount(), 2);
        assertEq(escrow.getReleasedMilestoneCount(), 1);
    }

    function test_InvalidMilestoneConstruction() public {
        uint256[] memory invalidAmounts = new uint256[](0);
        string[] memory invalidDescriptions = new string[](0);
        
        // Empty arrays should fail
        vm.expectRevert(MilestoneEscrow.InvalidMilestone.selector);
        new MilestoneEscrow(
            IERC20(address(usdc)),
            vault,
            recipient,
            deadline,
            invalidAmounts,
            invalidDescriptions
        );
        
        // Mismatched array lengths should fail
        uint256[] memory oneAmount = new uint256[](1);
        oneAmount[0] = 1000e6;
        vm.expectRevert(MilestoneEscrow.InvalidMilestone.selector);
        new MilestoneEscrow(
            IERC20(address(usdc)),
            vault,
            recipient,
            deadline,
            oneAmount,
            invalidDescriptions
        );
    }

    function test_InvalidDeadline() public {
        // Deadline in the past should fail
        vm.expectRevert(MilestoneEscrow.InvalidAmount.selector);
        new MilestoneEscrow(
            IERC20(address(usdc)),
            vault,
            recipient,
            block.timestamp - 1, // Past deadline
            amounts,
            descriptions
        );
    }

    function test_FundingWrongAmount() public {
        vm.prank(vault);
        vm.expectRevert(MilestoneEscrow.InvalidAmount.selector);
        escrow.fund(1000e6); // Wrong amount
    }

    function test_OnlyVaultCanFund() public {
        vm.prank(address(999));
        vm.expectRevert(MilestoneEscrow.OnlyVault.selector);
        escrow.fund(TOTAL_AMOUNT);
    }

    function test_InvalidMilestoneId() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        vm.prank(vault);
        vm.expectRevert(MilestoneEscrow.InvalidMilestone.selector);
        escrow.releaseMilestone(999); // Invalid milestone ID
    }

    function test_EmergencyClawbackWithNoUnreleasedFunds() public {
        vm.prank(vault);
        escrow.fund(TOTAL_AMOUNT);
        
        // Release all milestones
        vm.prank(vault);
        escrow.releaseMilestone(0);
        vm.prank(vault);
        escrow.releaseMilestone(1);
        vm.prank(vault);
        escrow.releaseMilestone(2);
        
        // Try emergency clawback with no funds left
        vm.prank(vault);
        vm.expectRevert(MilestoneEscrow.InsufficientBalance.selector);
        escrow.emergencyClawback();
    }
}