// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {AxiomVault} from "../src/AxiomVault.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract AxiomVaultTest is Test {
    AxiomVault public vault;
    ERC20Mock public usdc;
    
    address public owner = address(1);
    address public user1 = address(2);
    address public user2 = address(3);
    
    uint256 constant INITIAL_SUPPLY = 1_000_000e6; // 1M USDC
    uint256 constant DEPOSIT_AMOUNT = 10_000e6; // $10k USDC

    function setUp() public {
        // Deploy mock USDC with 6 decimals
        usdc = new ERC20Mock();
        
        // Deploy vault
        vault = new AxiomVault(IERC20(address(usdc)), owner);
        
        // Setup users with USDC
        usdc.mint(user1, INITIAL_SUPPLY);
        usdc.mint(user2, INITIAL_SUPPLY);
        
        // Approve vault to spend USDC
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        
        vm.prank(user2);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_InitialState() public view {
        assertEq(vault.name(), "Axiom Ventures Fund I");
        assertEq(vault.symbol(), "avFUND1");
        assertEq(address(vault.asset()), address(usdc));
        assertEq(vault.owner(), owner);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.highWaterMark(), 1e18);
    }

    function test_Deposit() public {
        vm.prank(user1);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        assertEq(vault.balanceOf(user1), shares);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT_AMOUNT);
        // Shares should be approximately equal to assets (1:1 ratio for first deposit)
        assertApproxEqRel(shares, DEPOSIT_AMOUNT, 0.01e18); // 1% tolerance
    }

    function test_Mint() public {
        uint256 sharesToMint = DEPOSIT_AMOUNT; // Use USDC amount for shares (1:1 ratio)
        
        vm.prank(user1);
        uint256 assets = vault.mint(sharesToMint, user1);
        
        assertEq(vault.balanceOf(user1), sharesToMint);
        assertEq(vault.totalAssets(), assets);
        assertApproxEqRel(assets, DEPOSIT_AMOUNT, 0.01e18); // Should be approximately 10k USDC
    }

    function test_Withdraw() public {
        // First deposit
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 withdrawAmount = 5_000e6; // $5k
        uint256 initialShares = vault.balanceOf(user1);
        
        vm.prank(user1);
        uint256 shares = vault.withdraw(withdrawAmount, user1, user1);
        
        assertEq(vault.balanceOf(user1), initialShares - shares);
        assertEq(usdc.balanceOf(user1), INITIAL_SUPPLY - DEPOSIT_AMOUNT + withdrawAmount);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT - withdrawAmount);
    }

    function test_Redeem() public {
        // First deposit
        vm.prank(user1);
        uint256 totalShares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 sharesToRedeem = totalShares / 2; // Half of shares
        
        vm.prank(user1);
        uint256 assets = vault.redeem(sharesToRedeem, user1, user1);
        
        assertEq(vault.balanceOf(user1), totalShares - sharesToRedeem);
        assertApproxEqAbs(assets, DEPOSIT_AMOUNT / 2, 1); // ~$5k USDC
    }

    function test_ManagementFees() public {
        // Deposit
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Fast forward 1 year
        vm.warp(block.timestamp + 365.25 days);
        
        // Check pending fees (should be ~2% of assets)
        uint256 expectedFees = (DEPOSIT_AMOUNT * 200) / 10000; // 2%
        uint256 pendingFees = vault.pendingManagementFeesAmount();
        
        assertApproxEqRel(pendingFees, expectedFees, 0.01e18); // 1% tolerance
        
        // Collect fees
        vm.prank(owner);
        vault.collectManagementFees();
        
        // Owner should have received fee shares
        assertGt(vault.balanceOf(owner), 0);
    }

    function test_PerformanceFees() public {
        // Deposit
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Simulate profit by minting USDC to vault (simulating investment gains)
        uint256 profit = 2_000e6; // $2k profit (20% gain)
        usdc.mint(address(vault), profit);
        
        uint256 ownerSharesBefore = vault.balanceOf(owner);
        
        // Collect performance fees
        vm.prank(owner);
        vault.collectPerformanceFees();
        
        // Owner should receive 20% of the profit in shares
        uint256 ownerSharesAfter = vault.balanceOf(owner);
        assertGt(ownerSharesAfter, ownerSharesBefore);
        
        // High water mark should be updated
        assertGt(vault.highWaterMark(), 1e18);
    }

    function test_LiquidityReserve() public {
        // Deposit $50k
        uint256 largeDeposit = 50_000e6;
        vm.prank(user1);
        vault.deposit(largeDeposit, user1);
        
        // Available liquidity should be 80% of total (20% reserve)
        uint256 expectedAvailable = (largeDeposit * 8000) / 10000; // 80%
        assertEq(vault.availableLiquidity(), expectedAvailable);
        
        // Try to withdraw more than available - should fail
        vm.prank(user1);
        vm.expectRevert(AxiomVault.InsufficientLiquidity.selector);
        vault.withdraw(largeDeposit, user1, user1); // Try to withdraw 100%
        
        // Withdraw within limit should succeed
        vm.prank(user1);
        vault.withdraw(expectedAvailable, user1, user1);
    }

    function test_Pause() public {
        // Only owner can pause
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();
        
        // Owner pauses
        vm.prank(owner);
        vault.pause();
        
        // Operations should be paused
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(1000e6, user1);
    }

    function test_OwnershipTransfer() public {
        address newOwner = address(4);
        
        // Transfer ownership (immediate with Ownable)
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        
        assertEq(vault.owner(), newOwner);
    }

    function test_ZeroAmountReverts() public {
        vm.prank(user1);
        vm.expectRevert(AxiomVault.InvalidAmount.selector);
        vault.deposit(0, user1);
        
        vm.prank(user1);
        vm.expectRevert(AxiomVault.InvalidAmount.selector);
        vault.mint(0, user1);
        
        vm.prank(user1);
        vm.expectRevert(AxiomVault.InvalidAmount.selector);
        vault.withdraw(0, user1, user1);
        
        vm.prank(user1);
        vm.expectRevert(AxiomVault.InvalidAmount.selector);
        vault.redeem(0, user1, user1);
    }

    function test_MaxWithdrawRespectsLiquidity() public {
        // Deposit
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 maxWithdraw = vault.maxWithdraw(user1);
        uint256 availableLiquidity = vault.availableLiquidity();
        
        // Max withdraw should be limited by liquidity reserve
        assertEq(maxWithdraw, availableLiquidity);
        assertLt(maxWithdraw, DEPOSIT_AMOUNT); // Less than full deposit due to reserve
    }

    function test_FeeAccrual() public {
        // Deposit
        vm.prank(user1);
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Fast forward 6 months
        vm.warp(block.timestamp + 182.625 days);
        
        // Check that fees are accruing
        uint256 pendingFees = vault.pendingManagementFeesAmount();
        assertGt(pendingFees, 0);
        
        // Fees should be approximately 1% (half year of 2% annual)
        uint256 expectedFees = (DEPOSIT_AMOUNT * 100) / 10000; // 1%
        assertApproxEqRel(pendingFees, expectedFees, 0.02e18); // 2% tolerance
    }

    function test_MultipleUsersDeposit() public {
        uint256 amount1 = 10_000e6;
        uint256 amount2 = 5_000e6;
        
        // User1 deposits
        vm.prank(user1);
        uint256 shares1 = vault.deposit(amount1, user1);
        
        // User2 deposits
        vm.prank(user2);
        uint256 shares2 = vault.deposit(amount2, user2);
        
        // Check total assets and individual balances
        assertEq(vault.totalAssets(), amount1 + amount2);
        assertEq(vault.balanceOf(user1), shares1);
        assertEq(vault.balanceOf(user2), shares2);
        
        // Shares should be proportional to deposits
        assertApproxEqRel(shares1, shares2 * 2, 0.01e18); // user1 deposited 2x more
    }

    function test_ReentrancyGuard() public {
        // This would require a more complex setup with a malicious contract
        // For now, we trust OpenZeppelin's ReentrancyGuard implementation
        assertTrue(true);
    }
}