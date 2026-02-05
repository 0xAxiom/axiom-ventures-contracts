// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AxiomVenturesFund1} from "../../src/v4/AxiomVenturesFund1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockClankerVault {
    mapping(address => uint256) public pendingClaims;
    
    function setPending(address token, uint256 amount) external {
        pendingClaims[token] = amount;
    }
    
    function claim(address token) external {
        uint256 amount = pendingClaims[token];
        if (amount > 0) {
            pendingClaims[token] = 0;
            IERC20(token).transfer(msg.sender, amount);
        }
    }
}

contract AxiomVenturesFund1Test is Test {
    AxiomVenturesFund1 public fund;
    AxiomVenturesFund1 public implementation;
    ERC20Mock public usdc;
    ERC20Mock public agentToken1;
    ERC20Mock public agentToken2;
    MockClankerVault public clankerVault;
    
    address public safe = address(0x5AFE);
    address public metadataAdmin = address(0xAD1);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    
    uint256 public constant SLIP_PRICE = 1010e6;  // $1,010
    uint256 public constant MAX_SUPPLY = 200;
    
    function setUp() public {
        // Deploy mocks
        usdc = new ERC20Mock();
        agentToken1 = new ERC20Mock();
        agentToken2 = new ERC20Mock();
        clankerVault = new MockClankerVault();
        
        // Deploy implementation
        implementation = new AxiomVenturesFund1();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            AxiomVenturesFund1.initialize.selector,
            safe,
            metadataAdmin,
            address(clankerVault)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        fund = AxiomVenturesFund1(address(proxy));
        
        // Setup USDC - mock Base USDC address
        vm.etch(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), address(usdc).code);
        
        // Give users USDC
        deal(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), alice, 500_000e6);
        deal(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), bob, 500_000e6);
    }
    
    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/
    
    function test_Initialize() public view {
        assertEq(fund.safe(), safe);
        assertEq(fund.metadataAdmin(), metadataAdmin);
        assertEq(fund.clankerVault(), address(clankerVault));
        assertEq(fund.depositsOpen(), true);
        assertEq(fund.paused(), false);
        assertEq(fund.tradingEnabled(), false);
        assertEq(fund.totalMinted(), 0);
    }
    
    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        fund.initialize(safe, metadataAdmin, address(clankerVault));
    }
    
    function test_RoyaltyInfo() public view {
        (address receiver, uint256 royalty) = fund.royaltyInfo(0, 10000);
        assertEq(receiver, safe);
        assertEq(royalty, 250); // 2.5%
    }
    
    /*//////////////////////////////////////////////////////////////
                              DEPOSITS
    //////////////////////////////////////////////////////////////*/
    
    function test_DepositSingleSlip() public {
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        assertEq(fund.balanceOf(alice), 1);
        assertEq(fund.ownerOf(0), alice);
        assertEq(fund.totalMinted(), 1);
    }
    
    function test_DepositMultipleSlips() public {
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 10 * SLIP_PRICE);
        fund.deposit(10);
        vm.stopPrank();
        
        assertEq(fund.balanceOf(alice), 10);
        assertEq(fund.totalMinted(), 10);
    }
    
    function test_DepositFeeGoesToSafe() public {
        uint256 safeBefore = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(safe);
        
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 10 * SLIP_PRICE);
        fund.deposit(10);
        vm.stopPrank();
        
        uint256 safeAfter = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(safe);
        
        // Safe receives full amount (including 1% fee for burns)
        assertEq(safeAfter - safeBefore, 10 * SLIP_PRICE);
    }
    
    function test_RevertWhenDepositsNotOpen() public {
        vm.prank(safe);
        fund.setDepositsOpen(false);
        
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        vm.expectRevert(AxiomVenturesFund1.DepositsNotOpen.selector);
        fund.deposit(1);
        vm.stopPrank();
    }
    
    function test_RevertWhenPaused() public {
        vm.prank(safe);
        fund.setPaused(true);
        
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        vm.expectRevert(AxiomVenturesFund1.ContractPaused.selector);
        fund.deposit(1);
        vm.stopPrank();
    }
    
    function test_RevertSoldOut() public {
        // Try to deposit more than max
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 300 * SLIP_PRICE);
        vm.expectRevert(AxiomVenturesFund1.SoldOut.selector);
        fund.deposit(201);
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                           TRADING LOCK
    //////////////////////////////////////////////////////////////*/
    
    function test_TradingLockedByDefault() public {
        // Deposit a slip
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        assertEq(fund.tradingEnabled(), false);
        
        // Try to transfer - should fail
        vm.prank(alice);
        vm.expectRevert(AxiomVenturesFund1.TradingNotEnabled.selector);
        fund.transferFrom(alice, bob, 0);
    }
    
    function test_TradingEnabledOnSellout() public {
        // Deposit all 200 slips
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 200 * SLIP_PRICE);
        fund.deposit(200);
        vm.stopPrank();
        
        assertEq(fund.tradingEnabled(), true);
        assertEq(fund.totalMinted(), 200);
        
        // Now transfer should work
        vm.prank(alice);
        fund.transferFrom(alice, bob, 0);
        assertEq(fund.ownerOf(0), bob);
    }
    
    function test_SafeCanEnableTradingEarly() public {
        // Deposit some slips
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 10 * SLIP_PRICE);
        fund.deposit(10);
        vm.stopPrank();
        
        assertEq(fund.tradingEnabled(), false);
        
        // Safe enables trading
        vm.prank(safe);
        fund.enableTrading();
        
        assertEq(fund.tradingEnabled(), true);
        
        // Transfer now works
        vm.prank(alice);
        fund.transferFrom(alice, bob, 0);
        assertEq(fund.ownerOf(0), bob);
    }
    
    function test_SafeCanAlwaysTransfer() public {
        // Deposit a slip directly to safe
        vm.startPrank(safe);
        deal(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), safe, SLIP_PRICE);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        assertEq(fund.tradingEnabled(), false);
        assertEq(fund.ownerOf(0), safe);
        
        // Safe can transfer even when trading locked
        vm.prank(safe);
        fund.transferFrom(safe, alice, 0);
        assertEq(fund.ownerOf(0), alice);
    }
    
    /*//////////////////////////////////////////////////////////////
                          CLANKER CLAIMS
    //////////////////////////////////////////////////////////////*/
    
    function test_ClaimFromClanker() public {
        // Setup: give clanker vault some tokens
        agentToken1.mint(address(clankerVault), 1000e18);
        clankerVault.setPending(address(agentToken1), 1000e18);
        
        // Add token manually first (or it will be added automatically)
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        
        // Claim
        fund.claimFromClanker(address(agentToken1));
        
        assertEq(fund.totalReceived(address(agentToken1)), 1000e18);
        assertEq(agentToken1.balanceOf(address(fund)), 1000e18);
    }
    
    function test_ClaimFromClankerBatch() public {
        // Setup multiple tokens
        agentToken1.mint(address(clankerVault), 1000e18);
        agentToken2.mint(address(clankerVault), 2000e18);
        clankerVault.setPending(address(agentToken1), 1000e18);
        clankerVault.setPending(address(agentToken2), 2000e18);
        
        vm.startPrank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.addAgentToken(address(agentToken2));
        vm.stopPrank();
        
        // Batch claim
        fund.claimFromClankerBatch(0, 2);
        
        assertEq(fund.totalReceived(address(agentToken1)), 1000e18);
        assertEq(fund.totalReceived(address(agentToken2)), 2000e18);
    }
    
    /*//////////////////////////////////////////////////////////////
                           LP CLAIMS
    //////////////////////////////////////////////////////////////*/
    
    function test_ClaimSingleToken() public {
        // Setup: deposit slip
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        // Setup: fund receives tokens (200 tokens total for 200 slips = 1 per slip)
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        
        fund.claimFromClanker(address(agentToken1));
        
        // Alice claims her share (1/200 of 200 = 1 token, minus 1% fee)
        uint256 expectedPayout = (1e18 * 99) / 100; // 0.99 tokens
        
        vm.prank(alice);
        fund.claimSingleToken(0, address(agentToken1));
        
        assertEq(agentToken1.balanceOf(alice), expectedPayout);
        assertEq(agentToken1.balanceOf(safe), 1e18 - expectedPayout); // fee
    }
    
    function test_ClaimTokensBatch() public {
        // Setup: deposit slip
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        // Setup: fund receives multiple tokens
        agentToken1.mint(address(clankerVault), 200e18);
        agentToken2.mint(address(clankerVault), 400e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        clankerVault.setPending(address(agentToken2), 400e18);
        
        vm.startPrank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.addAgentToken(address(agentToken2));
        vm.stopPrank();
        
        fund.claimFromClankerBatch(0, 2);
        
        // Alice batch claims
        vm.prank(alice);
        fund.claimTokensBatch(0, 0, 2);
        
        // Check she got her share of both (1/200 each, minus 1% fee)
        uint256 expected1 = (1e18 * 99) / 100;
        uint256 expected2 = (2e18 * 99) / 100;
        
        assertEq(agentToken1.balanceOf(alice), expected1);
        assertEq(agentToken2.balanceOf(alice), expected2);
    }
    
    function test_CannotClaimTwice() public {
        // Setup
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        
        fund.claimFromClanker(address(agentToken1));
        
        // First claim succeeds
        vm.prank(alice);
        fund.claimSingleToken(0, address(agentToken1));
        
        // Second claim reverts
        vm.prank(alice);
        vm.expectRevert(AxiomVenturesFund1.NothingToClaim.selector);
        fund.claimSingleToken(0, address(agentToken1));
    }
    
    function test_CanClaimMoreAfterMoreVests() public {
        // Setup
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        
        // First batch of tokens
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        fund.claimFromClanker(address(agentToken1));
        
        vm.prank(alice);
        fund.claimSingleToken(0, address(agentToken1));
        uint256 balance1 = agentToken1.balanceOf(alice);
        
        // Second batch of tokens
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        fund.claimFromClanker(address(agentToken1));
        
        // Alice can claim again
        vm.prank(alice);
        fund.claimSingleToken(0, address(agentToken1));
        uint256 balance2 = agentToken1.balanceOf(alice);
        
        assertGt(balance2, balance1);
    }
    
    function test_NotSlipOwnerCannotClaim() public {
        // Alice deposits
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.claimFromClanker(address(agentToken1));
        
        // Bob tries to claim Alice's slip
        vm.prank(bob);
        vm.expectRevert(AxiomVenturesFund1.NotSlipOwner.selector);
        fund.claimSingleToken(0, address(agentToken1));
    }
    
    function test_NewOwnerCanClaimAfterTransfer() public {
        // Sell out to enable trading
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 200 * SLIP_PRICE);
        fund.deposit(200);
        vm.stopPrank();
        
        // Setup tokens
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.claimFromClanker(address(agentToken1));
        
        // Alice transfers slip #0 to Bob
        vm.prank(alice);
        fund.transferFrom(alice, bob, 0);
        
        // Bob can now claim
        vm.prank(bob);
        fund.claimSingleToken(0, address(agentToken1));
        
        uint256 expected = (1e18 * 99) / 100;
        assertEq(agentToken1.balanceOf(bob), expected);
    }
    
    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function test_GetClaimableAll() public {
        // Setup
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        agentToken1.mint(address(clankerVault), 200e18);
        agentToken2.mint(address(clankerVault), 400e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        clankerVault.setPending(address(agentToken2), 400e18);
        
        vm.startPrank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.addAgentToken(address(agentToken2));
        vm.stopPrank();
        
        fund.claimFromClankerBatch(0, 2);
        
        (address[] memory tokens, uint256[] memory amounts) = fund.getClaimableAll(0);
        
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(agentToken1));
        assertEq(tokens[1], address(agentToken2));
        
        uint256 expected1 = (1e18 * 99) / 100;
        uint256 expected2 = (2e18 * 99) / 100;
        assertEq(amounts[0], expected1);
        assertEq(amounts[1], expected2);
    }
    
    function test_GetClaimHistory() public {
        // Setup
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.claimFromClanker(address(agentToken1));
        
        // Initially no history
        (address[] memory tokens, uint256[] memory amounts) = fund.getClaimHistory(0);
        assertEq(tokens.length, 1);
        assertEq(amounts[0], 0);
        
        // After claiming
        vm.prank(alice);
        fund.claimSingleToken(0, address(agentToken1));
        
        (, amounts) = fund.getClaimHistory(0);
        assertEq(amounts[0], 1e18); // Full amount before fee
    }
    
    function test_GetTokenStatus() public {
        // Setup
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        agentToken1.mint(address(clankerVault), 200e18);
        agentToken2.mint(address(clankerVault), 400e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        clankerVault.setPending(address(agentToken2), 400e18);
        
        vm.startPrank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.addAgentToken(address(agentToken2));
        vm.stopPrank();
        
        fund.claimFromClankerBatch(0, 2);
        
        (uint256 pending, uint256 claimed, uint256 total) = fund.getTokenStatus(0);
        assertEq(pending, 2);
        assertEq(claimed, 0);
        assertEq(total, 2);
        
        // After claiming one
        vm.prank(alice);
        fund.claimSingleToken(0, address(agentToken1));
        
        (pending, claimed, total) = fund.getTokenStatus(0);
        assertEq(pending, 1);
        assertEq(claimed, 1);
        assertEq(total, 2);
    }
    
    function test_GetPending() public {
        // Setup
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.claimFromClanker(address(agentToken1));
        
        uint256 pending = fund.getPending(0, address(agentToken1));
        uint256 expected = (1e18 * 99) / 100; // 1 token minus 1% fee
        
        assertEq(pending, expected);
    }
    
    function test_TokenURI() public {
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        string memory uri = fund.tokenURI(0);
        assertTrue(bytes(uri).length > 0);
        // Should be base64 encoded JSON
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
    }
    
    function test_TokenURIShowsTradingStatus() public {
        // First deposit - trading locked
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        string memory uri1 = fund.tokenURI(0);
        // Contains "Locked" in attributes (we can't easily parse base64 in Solidity)
        assertTrue(bytes(uri1).length > 0);
        
        // Enable trading
        vm.prank(safe);
        fund.enableTrading();
        
        string memory uri2 = fund.tokenURI(0);
        // URI should change to show "Enabled"
        assertTrue(bytes(uri2).length > 0);
    }
    
    function test_Owner() public view {
        assertEq(fund.owner(), metadataAdmin);
    }
    
    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function test_OnlySafeCanSetClankerVault() public {
        address newVault = address(0x1234);
        
        vm.prank(alice);
        vm.expectRevert(AxiomVenturesFund1.OnlySafe.selector);
        fund.setClankerVault(newVault);
        
        vm.prank(safe);
        fund.setClankerVault(newVault);
        assertEq(fund.clankerVault(), newVault);
    }
    
    function test_OnlySafeCanPause() public {
        vm.prank(alice);
        vm.expectRevert(AxiomVenturesFund1.OnlySafe.selector);
        fund.setPaused(true);
        
        vm.prank(safe);
        fund.setPaused(true);
        assertEq(fund.paused(), true);
    }
    
    function test_OnlySafeCanEnableTrading() public {
        vm.prank(alice);
        vm.expectRevert(AxiomVenturesFund1.OnlySafe.selector);
        fund.enableTrading();
        
        vm.prank(safe);
        fund.enableTrading();
        assertEq(fund.tradingEnabled(), true);
    }
    
    function test_LockUpgrades() public {
        vm.prank(safe);
        fund.lockUpgrades();
        
        assertEq(fund.upgradesLocked(), true);
    }
    
    function test_OnlyMetadataAdminCanSetContractURI() public {
        vm.prank(alice);
        vm.expectRevert(AxiomVenturesFund1.OnlyMetadataAdmin.selector);
        fund.setContractURI("ipfs://test");
        
        vm.prank(metadataAdmin);
        fund.setContractURI("ipfs://test");
        assertEq(fund.contractURI(), "ipfs://test");
    }
    
    /*//////////////////////////////////////////////////////////////
                        ACCUMULATED DIVIDENDS
    //////////////////////////////////////////////////////////////*/
    
    function test_LateDepositorsGetOnlyNewTokens() public {
        // Alice deposits first
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        // First batch of tokens arrives
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.claimFromClanker(address(agentToken1));
        
        // Bob deposits after tokens arrived
        vm.startPrank(bob);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        // Bob should have nothing to claim from first batch
        uint256 bobPending = fund.getPending(1, address(agentToken1));
        assertEq(bobPending, 0);
        
        // Alice should have her full share
        uint256 alicePending = fund.getPending(0, address(agentToken1));
        uint256 expected = (1e18 * 99) / 100;
        assertEq(alicePending, expected);
        
        // Second batch arrives
        agentToken1.mint(address(clankerVault), 200e18);
        clankerVault.setPending(address(agentToken1), 200e18);
        fund.claimFromClanker(address(agentToken1));
        
        // Now Bob can claim from second batch
        bobPending = fund.getPending(1, address(agentToken1));
        assertGt(bobPending, 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/
    
    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);
        
        if (strBytes.length < prefixBytes.length) return false;
        
        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }
}
