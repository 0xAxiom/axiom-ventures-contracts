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
    
    uint256 public constant SLIP_PRICE = 1000e6;
    uint256 public constant TOTAL_SLIPS = 2000;
    
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
        deal(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), alice, 100_000e6);
        deal(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), bob, 100_000e6);
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
        assertEq(fund.totalMinted(), 0);
    }
    
    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        fund.initialize(safe, metadataAdmin, address(clankerVault));
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
        assertEq(fund.publicSlipsMinted(), 1);
    }
    
    function test_DepositMultipleSlips() public {
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 10 * SLIP_PRICE);
        fund.deposit(10);
        vm.stopPrank();
        
        assertEq(fund.balanceOf(alice), 10);
        assertEq(fund.totalMinted(), 10);
    }
    
    function test_FundManagerSlipMinting() public {
        // Deposit 99 slips - should trigger 1 FM slip
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 99 * SLIP_PRICE);
        fund.deposit(99);
        vm.stopPrank();
        
        assertEq(fund.publicSlipsMinted(), 99);
        assertEq(fund.fundManagerSlipsMinted(), 1);
        assertEq(fund.totalMinted(), 100);
        assertEq(fund.balanceOf(safe), 1);
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
    
    function test_RevertExceedsMaxPublicSlips() public {
        // Try to deposit more than max
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), 2000 * SLIP_PRICE);
        vm.expectRevert(AxiomVenturesFund1.ExceedsMaxPublicSlips.selector);
        fund.deposit(1981);
        vm.stopPrank();
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
        
        // Setup: fund receives tokens
        agentToken1.mint(address(clankerVault), 2000e18);
        clankerVault.setPending(address(agentToken1), 2000e18);
        
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        
        fund.claimFromClanker(address(agentToken1));
        
        // Alice claims her share (1/2000 of 2000 = 1 token, minus 1% fee)
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
        agentToken1.mint(address(clankerVault), 2000e18);
        agentToken2.mint(address(clankerVault), 4000e18);
        clankerVault.setPending(address(agentToken1), 2000e18);
        clankerVault.setPending(address(agentToken2), 4000e18);
        
        vm.startPrank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.addAgentToken(address(agentToken2));
        vm.stopPrank();
        
        fund.claimFromClankerBatch(0, 2);
        
        // Alice batch claims
        vm.prank(alice);
        fund.claimTokensBatch(0, 0, 2);
        
        // Check she got her share of both
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
        
        agentToken1.mint(address(clankerVault), 2000e18);
        clankerVault.setPending(address(agentToken1), 2000e18);
        
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
        agentToken1.mint(address(clankerVault), 2000e18);
        clankerVault.setPending(address(agentToken1), 2000e18);
        fund.claimFromClanker(address(agentToken1));
        
        vm.prank(alice);
        fund.claimSingleToken(0, address(agentToken1));
        uint256 balance1 = agentToken1.balanceOf(alice);
        
        // Second batch of tokens
        agentToken1.mint(address(clankerVault), 2000e18);
        clankerVault.setPending(address(agentToken1), 2000e18);
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
        
        agentToken1.mint(address(clankerVault), 2000e18);
        clankerVault.setPending(address(agentToken1), 2000e18);
        vm.prank(safe);
        fund.addAgentToken(address(agentToken1));
        fund.claimFromClanker(address(agentToken1));
        
        // Bob tries to claim Alice's slip
        vm.prank(bob);
        vm.expectRevert(AxiomVenturesFund1.NotSlipOwner.selector);
        fund.claimSingleToken(0, address(agentToken1));
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
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function test_GetPending() public {
        // Setup
        vm.startPrank(alice);
        IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).approve(address(fund), SLIP_PRICE);
        fund.deposit(1);
        vm.stopPrank();
        
        agentToken1.mint(address(clankerVault), 2000e18);
        clankerVault.setPending(address(agentToken1), 2000e18);
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
    
    function test_Owner() public view {
        assertEq(fund.owner(), metadataAdmin);
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
