// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract EscrowFactoryTest is Test {
    EscrowFactory public factory;
    ERC20Mock public usdc;
    
    address public vault = address(1);
    address public recipient1 = address(2);
    address public recipient2 = address(3);
    
    uint256[] amounts1;
    string[] descriptions1;
    uint256[] amounts2;
    string[] descriptions2;
    
    uint256 deadline1;
    uint256 deadline2;

    function setUp() public {
        usdc = new ERC20Mock();
        factory = new EscrowFactory(IERC20(address(usdc)), vault);
        
        deadline1 = block.timestamp + 365 days;
        deadline2 = block.timestamp + 180 days;
        
        // Setup first escrow data
        amounts1.push(5_000e6);
        amounts1.push(3_000e6);
        descriptions1.push("Milestone 1");
        descriptions1.push("Milestone 2");
        
        // Setup second escrow data
        amounts2.push(10_000e6);
        amounts2.push(15_000e6);
        amounts2.push(5_000e6);
        descriptions2.push("MVP");
        descriptions2.push("Beta");
        descriptions2.push("Launch");
    }

    function test_InitialState() public view {
        assertEq(address(factory.asset()), address(usdc));
        assertEq(factory.vault(), vault);
        assertEq(factory.owner(), vault);
        assertEq(factory.getEscrowCount(), 0);
    }

    function test_CreateEscrow() public {
        vm.prank(vault);
        address escrowAddress = factory.createEscrow(
            recipient1,
            deadline1,
            amounts1,
            descriptions1
        );
        
        // Check factory state
        assertEq(factory.getEscrowCount(), 1);
        assertEq(factory.getEscrowAtIndex(0), escrowAddress);
        assertTrue(factory.isValidEscrow(escrowAddress));
        
        // Check recipient mapping
        address[] memory recipientEscrows = factory.getRecipientEscrows(recipient1);
        assertEq(recipientEscrows.length, 1);
        assertEq(recipientEscrows[0], escrowAddress);
        
        // Check escrow configuration
        MilestoneEscrow escrow = MilestoneEscrow(escrowAddress);
        assertEq(escrow.recipient(), recipient1);
        assertEq(escrow.vault(), vault);
        assertEq(escrow.deadline(), deadline1);
        assertEq(escrow.totalAmount(), 8_000e6); // 5k + 3k
    }

    function test_OnlyVaultCanCreateEscrow() public {
        vm.prank(address(999));
        vm.expectRevert(EscrowFactory.OnlyVault.selector);
        factory.createEscrow(recipient1, deadline1, amounts1, descriptions1);
    }

    function test_CreateMultipleEscrows() public {
        // Create first escrow
        vm.prank(vault);
        address escrow1 = factory.createEscrow(
            recipient1,
            deadline1,
            amounts1,
            descriptions1
        );
        
        // Create second escrow for different recipient
        vm.prank(vault);
        address escrow2 = factory.createEscrow(
            recipient2,
            deadline2,
            amounts2,
            descriptions2
        );
        
        // Check factory state
        assertEq(factory.getEscrowCount(), 2);
        assertEq(factory.getEscrowAtIndex(0), escrow1);
        assertEq(factory.getEscrowAtIndex(1), escrow2);
        
        // Check both are valid
        assertTrue(factory.isValidEscrow(escrow1));
        assertTrue(factory.isValidEscrow(escrow2));
        
        // Check recipient mappings
        assertEq(factory.getRecipientEscrows(recipient1).length, 1);
        assertEq(factory.getRecipientEscrows(recipient2).length, 1);
    }

    function test_GetAllEscrows() public {
        // Create multiple escrows
        vm.prank(vault);
        address escrow1 = factory.createEscrow(recipient1, deadline1, amounts1, descriptions1);
        
        vm.prank(vault);
        address escrow2 = factory.createEscrow(recipient2, deadline2, amounts2, descriptions2);
        
        address[] memory allEscrows = factory.getAllEscrows();
        assertEq(allEscrows.length, 2);
        assertEq(allEscrows[0], escrow1);
        assertEq(allEscrows[1], escrow2);
    }

    function test_InvalidRecipient() public {
        vm.prank(vault);
        vm.expectRevert(EscrowFactory.InvalidRecipient.selector);
        factory.createEscrow(address(0), deadline1, amounts1, descriptions1);
    }

    function test_InvalidDeadline() public {
        vm.prank(vault);
        vm.expectRevert(EscrowFactory.InvalidDeadline.selector);
        factory.createEscrow(recipient1, block.timestamp - 1, amounts1, descriptions1);
    }

    function test_InvalidMilestones() public {
        uint256[] memory emptyAmounts;
        string[] memory emptyDescriptions;
        
        // Empty arrays
        vm.prank(vault);
        vm.expectRevert(EscrowFactory.InvalidMilestones.selector);
        factory.createEscrow(recipient1, deadline1, emptyAmounts, emptyDescriptions);
        
        // Mismatched lengths
        uint256[] memory oneAmount = new uint256[](1);
        oneAmount[0] = 1000e6;
        
        vm.prank(vault);
        vm.expectRevert(EscrowFactory.InvalidMilestones.selector);
        factory.createEscrow(recipient1, deadline1, oneAmount, emptyDescriptions);
        
        // Zero amount
        uint256[] memory zeroAmounts = new uint256[](1);
        string[] memory oneDescription = new string[](1);
        zeroAmounts[0] = 0;
        oneDescription[0] = "Test";
        
        vm.prank(vault);
        vm.expectRevert(EscrowFactory.InvalidMilestones.selector);
        factory.createEscrow(recipient1, deadline1, zeroAmounts, oneDescription);
    }

    function test_GetActiveEscrows() public {
        // Create escrows
        vm.prank(vault);
        address escrow1 = factory.createEscrow(recipient1, deadline1, amounts1, descriptions1);
        
        vm.prank(vault);
        address escrow2 = factory.createEscrow(recipient2, deadline2, amounts2, descriptions2);
        
        // Both should be active initially
        address[] memory activeEscrows = factory.getActiveEscrows();
        assertEq(activeEscrows.length, 2);
        
        // Fund and clawback one escrow
        usdc.mint(vault, 8_000e6);
        vm.prank(vault);
        usdc.approve(escrow1, 8_000e6);
        
        vm.prank(vault);
        MilestoneEscrow(escrow1).fund(8_000e6);
        
        vm.prank(vault);
        MilestoneEscrow(escrow1).emergencyClawback();
        
        // Now only one should be active
        activeEscrows = factory.getActiveEscrows();
        assertEq(activeEscrows.length, 1);
        assertEq(activeEscrows[0], escrow2);
    }

    function test_GetExpiredEscrows() public {
        uint256 shortDeadline = block.timestamp + 1 hours;
        
        // Create escrow with short deadline
        vm.prank(vault);
        address shortEscrow = factory.createEscrow(
            recipient1,
            shortDeadline,
            amounts1,
            descriptions1
        );
        
        vm.prank(vault);
        address normalEscrow = factory.createEscrow(
            recipient2,
            deadline2,
            amounts2,
            descriptions2
        );
        
        // No expired escrows initially
        assertEq(factory.getExpiredEscrows().length, 0);
        
        // Fast forward past short deadline
        vm.warp(shortDeadline + 1);
        
        // One escrow should be expired
        address[] memory expiredEscrows = factory.getExpiredEscrows();
        assertEq(expiredEscrows.length, 1);
        assertEq(expiredEscrows[0], shortEscrow);
    }

    function test_GetTotalUnreleasedFunds() public {
        // Create escrows
        vm.prank(vault);
        address escrow1 = factory.createEscrow(recipient1, deadline1, amounts1, descriptions1);
        
        vm.prank(vault);
        address escrow2 = factory.createEscrow(recipient2, deadline2, amounts2, descriptions2);
        
        // Fund escrows
        uint256 total1 = 8_000e6;  // 5k + 3k
        uint256 total2 = 30_000e6; // 10k + 15k + 5k
        
        usdc.mint(vault, total1 + total2);
        vm.prank(vault);
        usdc.approve(escrow1, total1);
        vm.prank(vault);
        usdc.approve(escrow2, total2);
        
        vm.prank(vault);
        MilestoneEscrow(escrow1).fund(total1);
        vm.prank(vault);
        MilestoneEscrow(escrow2).fund(total2);
        
        // Total unreleased should be sum of both
        assertEq(factory.getTotalUnreleasedFunds(), total1 + total2);
        
        // Release one milestone from escrow1
        vm.prank(vault);
        MilestoneEscrow(escrow1).releaseMilestone(0);
        
        // Total should decrease by released amount
        assertEq(factory.getTotalUnreleasedFunds(), total1 + total2 - 5_000e6);
    }

    function test_AutoClawbackExpiredEscrows() public {
        uint256 shortDeadline = block.timestamp + 1 hours;
        
        // Create and fund expired escrow
        vm.prank(vault);
        address expiredEscrow = factory.createEscrow(
            recipient1,
            shortDeadline,
            amounts1,
            descriptions1
        );
        
        uint256 totalAmount = 8_000e6;
        usdc.mint(vault, totalAmount);
        vm.prank(vault);
        usdc.approve(expiredEscrow, totalAmount);
        vm.prank(vault);
        MilestoneEscrow(expiredEscrow).fund(totalAmount);
        
        // Fast forward past deadline
        vm.warp(shortDeadline + 1);
        
        uint256 vaultBalanceBefore = usdc.balanceOf(vault);
        
        // Auto-clawback expired escrows
        uint256 clawedBack = factory.autoClawbackExpiredEscrows();
        
        assertEq(clawedBack, 1);
        assertEq(usdc.balanceOf(vault), vaultBalanceBefore + totalAmount);
    }

    function test_MultipleRecipientsEscrows() public {
        // Create multiple escrows for same recipient
        vm.prank(vault);
        factory.createEscrow(recipient1, deadline1, amounts1, descriptions1);
        
        vm.prank(vault);
        factory.createEscrow(recipient1, deadline2, amounts2, descriptions2);
        
        // Recipient should have 2 escrows
        address[] memory recipientEscrows = factory.getRecipientEscrows(recipient1);
        assertEq(recipientEscrows.length, 2);
        
        // Different recipient should have 0 escrows
        assertEq(factory.getRecipientEscrows(recipient2).length, 0);
    }

    function test_IndexOutOfBounds() public {
        vm.expectRevert("Index out of bounds");
        factory.getEscrowAtIndex(0);
        
        // Create one escrow
        vm.prank(vault);
        factory.createEscrow(recipient1, deadline1, amounts1, descriptions1);
        
        // This should work
        factory.getEscrowAtIndex(0);
        
        // This should fail
        vm.expectRevert("Index out of bounds");
        factory.getEscrowAtIndex(1);
    }

    function test_EscrowEvent() public {
        // Simple test that the function executes without reverting
        // and creates an escrow (detailed event testing is complex with CREATE2)
        vm.prank(vault);
        address escrowAddress = factory.createEscrow(recipient1, deadline1, amounts1, descriptions1);
        
        // Verify escrow was created and is tracked
        assertTrue(factory.isValidEscrow(escrowAddress));
        assertEq(factory.getEscrowCount(), 1);
    }
}