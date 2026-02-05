// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {TokenWarrant} from "../src/v2.1/TokenWarrant.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 with configurable decimals
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TokenWarrantTest is Test {
    TokenWarrant public warrant;
    MockERC20 public usdc;
    MockERC20 public agentToken18; // 18 decimals
    MockERC20 public agentToken6;  // 6 decimals  
    MockERC20 public agentToken8;  // 8 decimals
    
    address public owner = address(1);
    address public agent = address(2);
    address public beneficiary = address(3);
    address public user = address(4);
    
    uint256 constant PITCH_ID = 123;
    uint256 constant TOKEN_AMOUNT_18 = 1000e18; // 1000 tokens with 18 decimals
    uint256 constant TOKEN_AMOUNT_6 = 1000e6;   // 1000 tokens with 6 decimals
    uint256 constant TOKEN_AMOUNT_8 = 1000e8;   // 1000 tokens with 8 decimals
    uint256 constant SNAPSHOT_PRICE = 50e6;     // $50 per token (6 decimals USDC)
    uint256 constant DISCOUNT_BPS = 5000;       // 50% discount
    uint256 constant EXERCISE_DEADLINE = 365 days;
    
    uint256 warrantId;

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        agentToken18 = new MockERC20("Agent Token 18", "AGT18", 18);
        agentToken6 = new MockERC20("Agent Token 6", "AGT6", 6);
        agentToken8 = new MockERC20("Agent Token 8", "AGT8", 8);
        
        // Deploy warrant contract
        warrant = new TokenWarrant(owner, IERC20(address(usdc)));
        
        // Mint tokens
        agentToken18.mint(agent, TOKEN_AMOUNT_18 * 10); // Extra for multiple tests
        agentToken6.mint(agent, TOKEN_AMOUNT_6 * 10);
        agentToken8.mint(agent, TOKEN_AMOUNT_8 * 10);
        usdc.mint(beneficiary, 1_000_000e6); // $1M USDC
        
        // Approve tokens
        vm.prank(agent);
        agentToken18.approve(address(warrant), type(uint256).max);
        vm.prank(agent);
        agentToken6.approve(address(warrant), type(uint256).max);
        vm.prank(agent);
        agentToken8.approve(address(warrant), type(uint256).max);
        
        vm.prank(beneficiary);
        usdc.approve(address(warrant), type(uint256).max);
    }

    function test_InitialState() public view {
        assertEq(warrant.nextWarrantId(), 1);
        assertEq(warrant.getWarrantCount(), 0);
        assertEq(warrant.owner(), owner);
        assertEq(address(warrant.USDC()), address(usdc));
    }

    function test_CreateWarrant() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(
            PITCH_ID,
            address(agentToken18),
            TOKEN_AMOUNT_18,
            SNAPSHOT_PRICE,
            DISCOUNT_BPS,
            block.timestamp + EXERCISE_DEADLINE,
            agent,
            beneficiary
        );
        
        assertEq(warrantId, 1);
        assertEq(warrant.nextWarrantId(), 2);
        assertEq(warrant.getWarrantCount(), 1);
        assertEq(warrant.getWarrantByPitch(PITCH_ID), warrantId);
        
        TokenWarrant.Warrant memory w = warrant.getWarrant(warrantId);
        assertEq(w.pitchId, PITCH_ID);
        assertEq(w.token, address(agentToken18));
        assertEq(w.tokenAmount, TOKEN_AMOUNT_18);
        assertEq(w.snapshotPrice, SNAPSHOT_PRICE);
        assertEq(w.discountBps, DISCOUNT_BPS);
        assertEq(w.agent, agent);
        assertEq(w.beneficiary, beneficiary);
        assertFalse(w.deposited);
        assertFalse(w.exercised);
        assertFalse(w.cancelled);
    }

    function test_CreateWarrant_RevertInvalidParameters() public {
        // Invalid pitch ID
        vm.expectRevert(TokenWarrant.InvalidPitchId.selector);
        vm.prank(owner);
        warrant.createWarrant(0, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        // Zero token amount
        vm.expectRevert(TokenWarrant.InvalidTokenAmount.selector);
        vm.prank(owner);
        warrant.createWarrant(PITCH_ID, address(agentToken18), 0, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        // Invalid discount (> 100%)
        vm.expectRevert(TokenWarrant.InvalidDiscountBps.selector);
        vm.prank(owner);
        warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, 10001, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        // Past deadline
        vm.expectRevert(TokenWarrant.InvalidExerciseDeadline.selector);
        vm.prank(owner);
        warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp - 1, agent, beneficiary);
    }

    function test_CreateWarrant_RevertNotOwner() public {
        vm.expectRevert();
        vm.prank(user);
        warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
    }

    function test_CreateWarrant_RevertDuplicatePitchId() public {
        vm.prank(owner);
        warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.expectRevert(TokenWarrant.DuplicatePitchId.selector);
        vm.prank(owner);
        warrant.createWarrant(PITCH_ID, address(agentToken6), TOKEN_AMOUNT_6, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
    }

    function test_DepositTokens() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        uint256 balanceBefore = agentToken18.balanceOf(agent);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        TokenWarrant.Warrant memory w = warrant.getWarrant(warrantId);
        assertTrue(w.deposited);
        assertEq(agentToken18.balanceOf(address(warrant)), TOKEN_AMOUNT_18);
        assertEq(agentToken18.balanceOf(agent), balanceBefore - TOKEN_AMOUNT_18);
    }

    function test_DepositTokens_RevertNotAgent() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.expectRevert(TokenWarrant.NotAuthorized.selector);
        vm.prank(user);
        warrant.depositTokens(warrantId);
    }

    function test_DepositTokens_RevertAlreadyDeposited() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        vm.expectRevert(TokenWarrant.TokensAlreadyDeposited.selector);
        vm.prank(agent);
        warrant.depositTokens(warrantId);
    }

    function test_ExerciseWarrant() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        uint256 exerciseCost = warrant.getExerciseCost(warrantId);
        uint256 usdcBalanceBefore = usdc.balanceOf(beneficiary);
        uint256 tokenBalanceBefore = agentToken18.balanceOf(beneficiary);
        
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);
        
        TokenWarrant.Warrant memory w = warrant.getWarrant(warrantId);
        assertTrue(w.exercised);
        assertEq(usdc.balanceOf(beneficiary), usdcBalanceBefore - exerciseCost);
        assertEq(agentToken18.balanceOf(beneficiary), tokenBalanceBefore + TOKEN_AMOUNT_18);
        assertEq(usdc.balanceOf(address(warrant)), exerciseCost);
        assertEq(agentToken18.balanceOf(address(warrant)), 0);
    }

    function test_ExerciseWarrant_RevertNotBeneficiary() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        vm.expectRevert(TokenWarrant.NotAuthorized.selector);
        vm.prank(user);
        warrant.exerciseWarrant(warrantId);
    }

    function test_ExerciseWarrant_RevertTokensNotDeposited() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.expectRevert(TokenWarrant.TokensNotDeposited.selector);
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);
    }

    function test_ExerciseWarrant_RevertExpired() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        // Fast forward past deadline
        vm.warp(block.timestamp + EXERCISE_DEADLINE + 1);
        
        vm.expectRevert(TokenWarrant.WarrantExpired.selector);
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);
    }

    function test_ExerciseWarrant_RevertAlreadyExercised() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);
        
        vm.expectRevert(TokenWarrant.WarrantAlreadyExercised.selector);
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);
    }

    function test_CancelWarrant() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        uint256 agentBalanceBefore = agentToken18.balanceOf(agent);
        
        vm.prank(owner);
        warrant.cancelWarrant(warrantId);
        
        TokenWarrant.Warrant memory w = warrant.getWarrant(warrantId);
        assertTrue(w.cancelled);
        assertEq(agentToken18.balanceOf(agent), agentBalanceBefore + TOKEN_AMOUNT_18);
        assertEq(agentToken18.balanceOf(address(warrant)), 0);
    }

    function test_CancelWarrant_NotDeposited() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(owner);
        warrant.cancelWarrant(warrantId);
        
        TokenWarrant.Warrant memory w = warrant.getWarrant(warrantId);
        assertTrue(w.cancelled);
    }

    function test_CancelWarrant_RevertNotOwner() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.expectRevert();
        vm.prank(user);
        warrant.cancelWarrant(warrantId);
    }

    function test_CancelWarrant_RevertAlreadyExercised() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);
        
        vm.expectRevert(TokenWarrant.WarrantAlreadyExercised.selector);
        vm.prank(owner);
        warrant.cancelWarrant(warrantId);
    }

    // ═══ Seize Tokens Tests ═══

    function test_SeizeTokens() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);

        uint256 beneficiaryBalBefore = agentToken18.balanceOf(beneficiary);

        vm.prank(owner);
        warrant.seizeTokens(warrantId);

        // Tokens go to beneficiary (fund), NOT back to agent
        assertEq(agentToken18.balanceOf(beneficiary), beneficiaryBalBefore + TOKEN_AMOUNT_18);
        // Warrant contract should have zero tokens left
        assertEq(agentToken18.balanceOf(address(warrant)), 0);
        
        TokenWarrant.Warrant memory w = warrant.getWarrant(warrantId);
        assertTrue(w.cancelled);
    }

    function test_SeizeTokens_RevertNotOwner() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);

        vm.expectRevert();
        vm.prank(agent);
        warrant.seizeTokens(warrantId);
    }

    function test_SeizeTokens_RevertNotDeposited() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);

        vm.expectRevert(TokenWarrant.TokensNotDeposited.selector);
        vm.prank(owner);
        warrant.seizeTokens(warrantId);
    }

    function test_SeizeTokens_RevertAlreadyExercised() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);

        vm.expectRevert(TokenWarrant.WarrantAlreadyExercised.selector);
        vm.prank(owner);
        warrant.seizeTokens(warrantId);
    }

    // ═══ Exercise Cost Tests ═══

    function test_GetExerciseCost_18Decimals() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        uint256 exerciseCost = warrant.getExerciseCost(warrantId);
        
        // Expected: (1000e18 * 50e6 * (10000 - 5000)) / (10000 * 1e18) = 25000e6 (50% of $50k)
        uint256 expected = 25000e6;
        assertEq(exerciseCost, expected);
    }

    function test_GetExerciseCost_6Decimals() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID + 1, address(agentToken6), TOKEN_AMOUNT_6, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        uint256 exerciseCost = warrant.getExerciseCost(warrantId);
        
        // Expected: (1000e6 * 50e6 * (10000 - 5000)) / (10000 * 1e6) = 25000e6 (50% of $50k)
        uint256 expected = 25000e6;
        assertEq(exerciseCost, expected);
    }

    function test_GetExerciseCost_8Decimals() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID + 2, address(agentToken8), TOKEN_AMOUNT_8, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        uint256 exerciseCost = warrant.getExerciseCost(warrantId);
        
        // Expected: (1000e8 * 50e6 * (10000 - 5000)) / (10000 * 1e8) = 25000e6 (50% of $50k)
        uint256 expected = 25000e6;
        assertEq(exerciseCost, expected);
    }

    function test_GetExerciseCost_ZeroDiscount() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, 0, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        uint256 exerciseCost = warrant.getExerciseCost(warrantId);
        
        // Expected: (1000e18 * 50e6 * 10000) / (10000 * 1e18) = 50000e6 (100% of $50k)
        uint256 expected = 50000e6;
        assertEq(exerciseCost, expected);
    }

    function test_GetExerciseCost_MaxDiscount() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, 10000, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        uint256 exerciseCost = warrant.getExerciseCost(warrantId);
        
        // Expected: (1000e18 * 50e6 * 0) / (10000 * 1e18) = 0 (free)
        assertEq(exerciseCost, 0);
    }

    function test_GetActiveWarrants() public {
        // Create multiple warrants
        vm.prank(owner);
        uint256 w1 = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(owner);
        uint256 w2 = warrant.createWarrant(PITCH_ID + 1, address(agentToken6), TOKEN_AMOUNT_6, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(owner);
        uint256 w3 = warrant.createWarrant(PITCH_ID + 2, address(agentToken8), TOKEN_AMOUNT_8, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        // No warrants are active yet (not deposited)
        uint256[] memory active = warrant.getActiveWarrants();
        assertEq(active.length, 0);
        
        // Deposit tokens for w1 and w3
        vm.prank(agent);
        warrant.depositTokens(w1);
        vm.prank(agent);
        warrant.depositTokens(w3);
        
        // Now 2 warrants should be active
        active = warrant.getActiveWarrants();
        assertEq(active.length, 2);
        assertEq(active[0], w1);
        assertEq(active[1], w3);
        
        // Exercise w1
        vm.prank(beneficiary);
        warrant.exerciseWarrant(w1);
        
        // Now only 1 warrant should be active
        active = warrant.getActiveWarrants();
        assertEq(active.length, 1);
        assertEq(active[0], w3);
        
        // Cancel w3
        vm.prank(owner);
        warrant.cancelWarrant(w3);
        
        // No warrants should be active
        active = warrant.getActiveWarrants();
        assertEq(active.length, 0);
    }

    function test_GetWarrantsPaginated() public {
        // Create 5 warrants
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(owner);
            warrant.createWarrant(PITCH_ID + i, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        }
        
        // Get first 3
        uint256[] memory warrants1 = warrant.getWarrantsPaginated(0, 3);
        assertEq(warrants1.length, 3);
        assertEq(warrants1[0], 1);
        assertEq(warrants1[1], 2);
        assertEq(warrants1[2], 3);
        
        // Get next 2
        uint256[] memory warrants2 = warrant.getWarrantsPaginated(3, 3);
        assertEq(warrants2.length, 2);
        assertEq(warrants2[0], 4);
        assertEq(warrants2[1], 5);
        
        // Get beyond range
        uint256[] memory warrants3 = warrant.getWarrantsPaginated(10, 5);
        assertEq(warrants3.length, 0);
    }

    function test_WithdrawUSDC() public {
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);
        
        uint256 contractBalance = usdc.balanceOf(address(warrant));
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);
        
        vm.prank(owner);
        warrant.withdrawUSDC(owner, contractBalance);
        
        assertEq(usdc.balanceOf(address(warrant)), 0);
        assertEq(usdc.balanceOf(owner), ownerBalanceBefore + contractBalance);
    }

    function test_WithdrawUSDC_RevertNotOwner() public {
        vm.expectRevert();
        vm.prank(user);
        warrant.withdrawUSDC(user, 100e6);
    }

    function test_EdgeCase_VerySmallAmounts() public {
        uint256 smallAmount = 1; // 1 wei of token
        uint256 smallPrice = 1;  // 1 wei of USDC per token
        
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), smallAmount, smallPrice, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        uint256 exerciseCost = warrant.getExerciseCost(warrantId);
        
        // Should not revert and should give reasonable result
        assertTrue(exerciseCost >= 0);
    }

    function test_EdgeCase_VeryLargeAmounts() public {
        uint256 largeAmount = type(uint128).max; // Very large but not max uint256
        uint256 largePrice = 1000e6; // $1000 per token
        
        agentToken18.mint(agent, largeAmount);
        
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), largeAmount, largePrice, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        // Should not revert
        uint256 exerciseCost = warrant.getExerciseCost(warrantId);
        assertTrue(exerciseCost > 0);
    }

    function test_FullWorkflow() public {
        // Create warrant
        vm.prank(owner);
        warrantId = warrant.createWarrant(PITCH_ID, address(agentToken18), TOKEN_AMOUNT_18, SNAPSHOT_PRICE, DISCOUNT_BPS, block.timestamp + EXERCISE_DEADLINE, agent, beneficiary);
        
        // Verify warrant is in all warrants list
        uint256[] memory allWarrants = warrant.getAllWarrants();
        assertEq(allWarrants.length, 1);
        assertEq(allWarrants[0], warrantId);
        
        // Agent deposits tokens
        vm.prank(agent);
        warrant.depositTokens(warrantId);
        
        // Verify warrant is now active
        uint256[] memory activeWarrants = warrant.getActiveWarrants();
        assertEq(activeWarrants.length, 1);
        assertEq(activeWarrants[0], warrantId);
        
        // Beneficiary exercises warrant
        vm.prank(beneficiary);
        warrant.exerciseWarrant(warrantId);
        
        // Verify warrant is no longer active
        activeWarrants = warrant.getActiveWarrants();
        assertEq(activeWarrants.length, 0);
        
        // Owner withdraws USDC
        uint256 usdcBalance = warrant.getUSDCBalance();
        vm.prank(owner);
        warrant.withdrawUSDC(owner, usdcBalance);
        
        assertEq(warrant.getUSDCBalance(), 0);
    }
}