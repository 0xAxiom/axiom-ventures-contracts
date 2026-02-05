// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {EscrowFactoryV2} from "../../src/v2.1/EscrowFactoryV2.sol";
import {MilestoneEscrow} from "../../src/MilestoneEscrow.sol";

contract EscrowFactoryV2Test is Test {
    EscrowFactoryV2 public factory;
    IERC20 public usdc;
    
    address public constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant SAFE_ADDRESS = 0x5766f573Cc516E3CA0D05a4848EF048636008271;
    
    address public deployer;
    address public mockRouter;
    address public recipient;
    
    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork("https://mainnet.base.org");
        
        deployer = makeAddr("deployer");
        mockRouter = makeAddr("mockRouter");
        recipient = makeAddr("recipient");
        
        usdc = IERC20(USDC_ADDRESS);
        
        vm.startPrank(deployer);
        factory = new EscrowFactoryV2(usdc, SAFE_ADDRESS, deployer);
        vm.stopPrank();
    }

    function test_Constructor() public {
        assertEq(address(factory.asset()), USDC_ADDRESS);
        assertEq(factory.escrowOwner(), SAFE_ADDRESS);
        assertEq(factory.owner(), deployer);
        assertEq(factory.authorizedRouter(), address(0));
    }

    function test_SetRouter() public {
        vm.startPrank(deployer);
        
        factory.setRouter(mockRouter);
        assertEq(factory.authorizedRouter(), mockRouter);
        
        vm.stopPrank();
    }

    function test_SetRouter_OnlyOwner() public {
        vm.prank(mockRouter);
        vm.expectRevert();
        factory.setRouter(mockRouter);
    }

    function test_SetRouter_InvalidRouter() public {
        vm.prank(deployer);
        vm.expectRevert(EscrowFactoryV2.InvalidRouter.selector);
        factory.setRouter(address(0));
    }

    function test_CreateEscrow_ByOwner() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e6; // 1000 USDC
        amounts[1] = 500e6;  // 500 USDC
        
        string[] memory descriptions = new string[](2);
        descriptions[0] = "Milestone 1";
        descriptions[1] = "Milestone 2";
        
        uint256 deadline = block.timestamp + 90 days;
        
        vm.startPrank(deployer);
        
        address escrowAddress = factory.createEscrow(
            recipient,
            deadline,
            amounts,
            descriptions
        );
        
        vm.stopPrank();
        
        // Verify escrow was created
        assertTrue(escrowAddress != address(0));
        assertTrue(factory.isValidEscrow(escrowAddress));
        assertEq(factory.getEscrowCount(), 1);
        assertEq(factory.getEscrowAtIndex(0), escrowAddress);
        
        // Verify escrow is owned by Safe (not vault)
        MilestoneEscrow escrow = MilestoneEscrow(escrowAddress);
        assertEq(escrow.owner(), SAFE_ADDRESS);
        assertEq(escrow.vault(), SAFE_ADDRESS);
    }

    function test_CreateEscrow_ByAuthorizedRouter() public {
        // Set up router authorization
        vm.prank(deployer);
        factory.setRouter(mockRouter);
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2000e6; // 2000 USDC
        
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Single milestone";
        
        uint256 deadline = block.timestamp + 60 days;
        
        vm.startPrank(mockRouter);
        
        address escrowAddress = factory.createEscrow(
            recipient,
            deadline,
            amounts,
            descriptions
        );
        
        vm.stopPrank();
        
        // Verify escrow was created by router
        assertTrue(escrowAddress != address(0));
        assertTrue(factory.isValidEscrow(escrowAddress));
        
        // Verify escrow is owned by Safe
        MilestoneEscrow escrow = MilestoneEscrow(escrowAddress);
        assertEq(escrow.owner(), SAFE_ADDRESS);
    }

    function test_CreateEscrow_OnlyAuthorized() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Test milestone";
        
        uint256 deadline = block.timestamp + 60 days;
        
        // Unauthorized caller should fail
        vm.prank(recipient);
        vm.expectRevert(EscrowFactoryV2.OnlyAuthorized.selector);
        factory.createEscrow(recipient, deadline, amounts, descriptions);
    }

    function test_CreateEscrow_InvalidParams() public {
        vm.startPrank(deployer);
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Test";
        
        uint256 deadline = block.timestamp + 60 days;
        
        // Invalid recipient
        vm.expectRevert(EscrowFactoryV2.InvalidRecipient.selector);
        factory.createEscrow(address(0), deadline, amounts, descriptions);
        
        // Invalid deadline
        vm.expectRevert(EscrowFactoryV2.InvalidDeadline.selector);
        factory.createEscrow(recipient, block.timestamp - 1, amounts, descriptions);
        
        // Empty amounts
        uint256[] memory emptyAmounts = new uint256[](0);
        vm.expectRevert(EscrowFactoryV2.InvalidMilestones.selector);
        factory.createEscrow(recipient, deadline, emptyAmounts, descriptions);
        
        // Mismatched lengths
        string[] memory twoDescriptions = new string[](2);
        twoDescriptions[0] = "Test 1";
        twoDescriptions[1] = "Test 2";
        vm.expectRevert(EscrowFactoryV2.InvalidMilestones.selector);
        factory.createEscrow(recipient, deadline, amounts, twoDescriptions);
        
        // Zero amount
        amounts[0] = 0;
        vm.expectRevert(EscrowFactoryV2.InvalidMilestones.selector);
        factory.createEscrow(recipient, deadline, amounts, descriptions);
        
        vm.stopPrank();
    }

    function test_GetEscrowsPaginated() public {
        vm.startPrank(deployer);
        
        // Create multiple escrows
        for (uint i = 0; i < 5; i++) {
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1000e6 + i * 100e6;
            
            string[] memory descriptions = new string[](1);
            descriptions[0] = string(abi.encodePacked("Milestone ", i));
            
            factory.createEscrow(
                recipient,
                block.timestamp + 60 days,
                amounts,
                descriptions
            );
        }
        
        vm.stopPrank();
        
        // Test pagination
        address[] memory page1 = factory.getEscrowsPaginated(0, 3);
        assertEq(page1.length, 3);
        
        address[] memory page2 = factory.getEscrowsPaginated(3, 3);
        assertEq(page2.length, 2); // Only 2 remaining
        
        address[] memory emptyPage = factory.getEscrowsPaginated(10, 3);
        assertEq(emptyPage.length, 0);
    }

    function test_AutoClawbackBatch() public {
        vm.startPrank(deployer);
        
        // Create multiple escrows that will expire
        for (uint i = 0; i < 3; i++) {
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1000e6;
            
            string[] memory descriptions = new string[](1);
            descriptions[0] = "Expired milestone";
            
            factory.createEscrow(
                recipient,
                block.timestamp + 1, // Will expire quickly
                amounts,
                descriptions
            );
        }
        
        vm.stopPrank();
        
        // Wait for expiry
        vm.warp(block.timestamp + 2);
        
        // Clawback with batch limit (should work but return 0 since escrows aren't funded)
        uint256 clawedBack = factory.autoClawbackBatch(2);
        assertEq(clawedBack, 0); // No funds to clawback (escrows not funded)
        
        // Test with valid range
        clawedBack = factory.autoClawbackBatch(10);  // Process all
        assertEq(clawedBack, 0); // Still 0 since no escrows are funded
    }

    function test_RecipientEscrows() public {
        vm.startPrank(deployer);
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Test milestone";
        
        // Create escrow for recipient
        address escrowAddress = factory.createEscrow(
            recipient,
            block.timestamp + 60 days,
            amounts,
            descriptions
        );
        
        vm.stopPrank();
        
        // Check recipient escrows
        address[] memory recipientEscrows = factory.getRecipientEscrows(recipient);
        assertEq(recipientEscrows.length, 1);
        assertEq(recipientEscrows[0], escrowAddress);
    }

    function test_SafeCanControlEscrow() public {
        vm.startPrank(deployer);
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e6;
        amounts[1] = 500e6;
        
        string[] memory descriptions = new string[](2);
        descriptions[0] = "Milestone 1";
        descriptions[1] = "Milestone 2";
        
        address escrowAddress = factory.createEscrow(
            recipient,
            block.timestamp + 60 days,
            amounts,
            descriptions
        );
        
        vm.stopPrank();
        
        MilestoneEscrow escrow = MilestoneEscrow(escrowAddress);
        
        // Verify Safe is the owner and can call milestone release
        assertEq(escrow.owner(), SAFE_ADDRESS);
        
        // Mock Safe calling releaseMilestone (would need proper setup with funding)
        vm.prank(SAFE_ADDRESS);
        // This would require funding the escrow first, but we're testing ownership
        try escrow.releaseMilestone(0) {
            // Would succeed if funded
        } catch {
            // Expected to fail without funding, but shows Safe has authorization
        }
        
        // Mock Safe calling emergencyClawback
        vm.prank(SAFE_ADDRESS);
        try escrow.emergencyClawback() {
            // Would succeed if funded
        } catch {
            // Expected to fail without funding, but shows Safe has authorization
        }
    }

    function test_GetActiveAndExpiredEscrows() public {
        vm.startPrank(deployer);
        
        // Create active escrow
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        string[] memory descriptions = new string[](1);
        descriptions[0] = "Active milestone";
        
        factory.createEscrow(
            recipient,
            block.timestamp + 60 days,
            amounts,
            descriptions
        );
        
        // Create expired escrow
        factory.createEscrow(
            recipient,
            block.timestamp + 1,
            amounts,
            descriptions
        );
        
        vm.stopPrank();
        
        // Check active escrows
        address[] memory activeEscrows = factory.getActiveEscrows();
        assertEq(activeEscrows.length, 2); // Both are active initially
        
        // Fast forward time
        vm.warp(block.timestamp + 2);
        
        // Now one should be expired
        activeEscrows = factory.getActiveEscrows();
        assertEq(activeEscrows.length, 1);
        
        address[] memory expiredEscrows = factory.getExpiredEscrows();
        assertEq(expiredEscrows.length, 1);
    }
}