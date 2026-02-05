// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {AgentDeal} from "../../src/v3/AgentDeal.sol";
import {TokenVesting} from "../../src/v3/TokenVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _approve(from, msg.sender, currentAllowance - amount);
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(_balances[from] >= amount, "ERC20: transfer amount exceeds balance");
        
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

contract MockDistributor {
    mapping(address => address) public tokenToVesting;
    
    function addToken(address token, address vestingContract) external {
        tokenToVesting[token] = vestingContract;
    }
}

contract AgentDealTest is Test {
    AgentDeal public agentDeal;
    MockERC20 public usdc;
    MockERC20 public agentToken1;
    MockERC20 public agentToken2;
    MockDistributor public mockDistributor;
    
    address public vault = makeAddr("vault");
    address public owner = makeAddr("owner");
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    
    uint256 public constant TOKEN_AMOUNT = 2000e18; // 20% of 10,000 token supply

    event DealCreated(
        uint256 indexed dealId,
        address indexed agent,
        address indexed token,
        address vestingContract,
        uint256 tokenAmount
    );

    event DealConfirmed(uint256 indexed dealId, address indexed agent);

    event DealExecuted(
        uint256 indexed dealId,
        address indexed agent,
        address indexed token,
        address vestingContract,
        uint256 tokenAmount,
        uint256 usdcAmount
    );

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        agentToken1 = new MockERC20("Agent Token 1", "AGT1", 18);
        agentToken2 = new MockERC20("Agent Token 2", "AGT2", 18);
        mockDistributor = new MockDistributor();
        
        agentDeal = new AgentDeal(vault, address(mockDistributor), address(usdc), owner);
        
        // Mint tokens to agents
        agentToken1.mint(agent1, 10000e18);
        agentToken2.mint(agent2, 10000e18);
    }

    function test_constructor() public view {
        assertEq(agentDeal.vault(), vault);
        assertEq(agentDeal.distributor(), address(mockDistributor));
        assertEq(address(agentDeal.usdc()), address(usdc));
        assertEq(agentDeal.owner(), owner);
        assertEq(agentDeal.USDC_AMOUNT(), 20000e6);
        assertEq(agentDeal.CLIFF_DURATION(), 1_209_600);
        assertEq(agentDeal.VESTING_DURATION(), 7_776_000);
    }

    function test_constructor_zeroVault_reverts() public {
        vm.expectRevert("AgentDeal: vault is the zero address");
        new AgentDeal(address(0), address(mockDistributor), address(usdc), owner);
    }

    function test_constructor_zeroDistributor_reverts() public {
        vm.expectRevert("AgentDeal: distributor is the zero address");
        new AgentDeal(vault, address(0), address(usdc), owner);
    }

    function test_constructor_zeroUsdc_reverts() public {
        vm.expectRevert("AgentDeal: usdc is the zero address");
        new AgentDeal(vault, address(mockDistributor), address(0), owner);
    }

    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert();
        new AgentDeal(vault, address(mockDistributor), address(usdc), address(0));
    }

    function test_createDeal() public {
        vm.prank(owner);
        uint256 dealId = agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        
        assertEq(dealId, 0);
        
        AgentDeal.Deal memory deal = agentDeal.getDeal(dealId);
        assertEq(deal.agent, agent1);
        assertEq(deal.token, address(agentToken1));
        assertEq(deal.usdcAmount, 20000e6);
        assertEq(deal.tokenAmount, TOKEN_AMOUNT);
        assertEq(deal.timestamp, block.timestamp);
        assertEq(uint8(deal.status), uint8(AgentDeal.DealStatus.Created));
        assertTrue(deal.vestingContract != address(0));
        
        // Verify vesting contract parameters
        TokenVesting vesting = TokenVesting(deal.vestingContract);
        assertEq(address(vesting.token()), address(agentToken1));
        assertEq(vesting.beneficiary(), address(mockDistributor));
        assertEq(vesting.cliff(), 1_209_600);
        assertEq(vesting.vestingDuration(), 7_776_000);
        assertEq(vesting.totalAmount(), TOKEN_AMOUNT);
    }

    function test_createDeal_onlyOwner() public {
        vm.prank(agent1);
        vm.expectRevert();
        agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
    }

    function test_createDeal_zeroAgent_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: agent is the zero address");
        agentDeal.createDeal(address(0), address(agentToken1), TOKEN_AMOUNT);
    }

    function test_createDeal_zeroToken_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: token is the zero address");
        agentDeal.createDeal(agent1, address(0), TOKEN_AMOUNT);
    }

    function test_createDeal_zeroTokenAmount_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: token amount must be > 0");
        agentDeal.createDeal(agent1, address(agentToken1), 0);
    }

    function test_confirmDeal() public {
        // Create deal
        vm.prank(owner);
        uint256 dealId = agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        
        AgentDeal.Deal memory deal = agentDeal.getDeal(dealId);
        
        // Agent transfers tokens to vesting contract
        vm.prank(agent1);
        agentToken1.transfer(deal.vestingContract, TOKEN_AMOUNT);
        
        // Confirm deal
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit DealConfirmed(dealId, agent1);
        agentDeal.confirmDeal(dealId);
        
        // Check deal status updated
        deal = agentDeal.getDeal(dealId);
        assertEq(uint8(deal.status), uint8(AgentDeal.DealStatus.Confirmed));
    }

    function test_confirmDeal_onlyOwner() public {
        vm.prank(owner);
        uint256 dealId = agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        
        vm.prank(agent1);
        vm.expectRevert();
        agentDeal.confirmDeal(dealId);
    }

    function test_confirmDeal_invalidDealId_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: invalid deal ID");
        agentDeal.confirmDeal(999);
    }

    function test_confirmDeal_insufficientTokens_reverts() public {
        vm.prank(owner);
        uint256 dealId = agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        
        // Don't transfer enough tokens
        AgentDeal.Deal memory deal = agentDeal.getDeal(dealId);
        vm.prank(agent1);
        agentToken1.transfer(deal.vestingContract, TOKEN_AMOUNT - 1);
        
        vm.prank(owner);
        vm.expectRevert("AgentDeal: insufficient tokens in vesting contract");
        agentDeal.confirmDeal(dealId);
    }

    function test_confirmDeal_alreadyConfirmed_reverts() public {
        // Create and confirm deal
        vm.prank(owner);
        uint256 dealId = agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        
        AgentDeal.Deal memory deal = agentDeal.getDeal(dealId);
        vm.prank(agent1);
        agentToken1.transfer(deal.vestingContract, TOKEN_AMOUNT);
        
        vm.prank(owner);
        agentDeal.confirmDeal(dealId);
        
        // Try to confirm again
        vm.prank(owner);
        vm.expectRevert("AgentDeal: deal already confirmed");
        agentDeal.confirmDeal(dealId);
    }

    function test_getDealsCount() public {
        assertEq(agentDeal.getDealsCount(), 0);
        
        vm.startPrank(owner);
        agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        assertEq(agentDeal.getDealsCount(), 1);
        
        agentDeal.createDeal(agent2, address(agentToken2), TOKEN_AMOUNT);
        assertEq(agentDeal.getDealsCount(), 2);
        vm.stopPrank();
    }

    function test_getActiveDealCount() public {
        vm.startPrank(owner);
        
        // Create first deal
        uint256 dealId1 = agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        assertEq(agentDeal.getActiveDealCount(), 0);
        
        // Fund and confirm first deal
        AgentDeal.Deal memory deal1 = agentDeal.getDeal(dealId1);
        vm.stopPrank();
        vm.prank(agent1);
        agentToken1.transfer(deal1.vestingContract, TOKEN_AMOUNT);
        vm.prank(owner);
        agentDeal.confirmDeal(dealId1);
        assertEq(agentDeal.getActiveDealCount(), 1);
        
        // Create second deal but don't confirm
        vm.prank(owner);
        agentDeal.createDeal(agent2, address(agentToken2), TOKEN_AMOUNT);
        assertEq(agentDeal.getActiveDealCount(), 1);
    }

    function test_getDealsByAgent() public {
        vm.startPrank(owner);
        
        // Create deals for agent1
        uint256 dealId1 = agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        uint256 dealId2 = agentDeal.createDeal(agent1, address(agentToken2), TOKEN_AMOUNT);
        
        // Create deal for agent2
        uint256 dealId3 = agentDeal.createDeal(agent2, address(agentToken1), TOKEN_AMOUNT);
        
        vm.stopPrank();
        
        uint256[] memory agent1Deals = agentDeal.getDealsByAgent(agent1);
        uint256[] memory agent2Deals = agentDeal.getDealsByAgent(agent2);
        
        assertEq(agent1Deals.length, 2);
        assertEq(agent1Deals[0], dealId1);
        assertEq(agent1Deals[1], dealId2);
        
        assertEq(agent2Deals.length, 1);
        assertEq(agent2Deals[0], dealId3);
    }

    function test_getAllDeals() public {
        vm.startPrank(owner);
        agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        agentDeal.createDeal(agent2, address(agentToken2), TOKEN_AMOUNT);
        vm.stopPrank();
        
        AgentDeal.Deal[] memory allDeals = agentDeal.getAllDeals(0, 10);
        assertEq(allDeals.length, 2);
        assertEq(allDeals[0].agent, agent1);
        assertEq(allDeals[1].agent, agent2);
    }

    function test_getAllDeals_pagination() public {
        vm.startPrank(owner);
        agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        agentDeal.createDeal(agent2, address(agentToken2), TOKEN_AMOUNT);
        agentDeal.createDeal(agent1, address(agentToken2), TOKEN_AMOUNT);
        vm.stopPrank();
        
        // Get first page
        AgentDeal.Deal[] memory page1 = agentDeal.getAllDeals(0, 2);
        assertEq(page1.length, 2);
        assertEq(page1[0].agent, agent1);
        assertEq(page1[1].agent, agent2);
        
        // Get second page
        AgentDeal.Deal[] memory page2 = agentDeal.getAllDeals(2, 2);
        assertEq(page2.length, 1);
        assertEq(page2[0].agent, agent1);
    }

    function test_getAllDeals_offsetOutOfBounds_reverts() public {
        vm.expectRevert("AgentDeal: offset out of bounds");
        agentDeal.getAllDeals(1, 10);
    }

    function test_multipleDealWorkflow() public {
        // Create multiple deals
        vm.startPrank(owner);
        uint256 dealId1 = agentDeal.createDeal(agent1, address(agentToken1), TOKEN_AMOUNT);
        uint256 dealId2 = agentDeal.createDeal(agent2, address(agentToken2), TOKEN_AMOUNT);
        vm.stopPrank();
        
        // Fund first deal
        AgentDeal.Deal memory deal1 = agentDeal.getDeal(dealId1);
        vm.prank(agent1);
        agentToken1.transfer(deal1.vestingContract, TOKEN_AMOUNT);
        
        // Fund second deal
        AgentDeal.Deal memory deal2 = agentDeal.getDeal(dealId2);
        vm.prank(agent2);
        agentToken2.transfer(deal2.vestingContract, TOKEN_AMOUNT);
        
        // Confirm both deals
        vm.startPrank(owner);
        agentDeal.confirmDeal(dealId1);
        agentDeal.confirmDeal(dealId2);
        vm.stopPrank();
        
        // Verify final state
        assertEq(agentDeal.getActiveDealCount(), 2);
        
        deal1 = agentDeal.getDeal(dealId1);
        deal2 = agentDeal.getDeal(dealId2);
        
        assertEq(uint8(deal1.status), uint8(AgentDeal.DealStatus.Confirmed));
        assertEq(uint8(deal2.status), uint8(AgentDeal.DealStatus.Confirmed));
        
        // Verify vesting contracts are funded
        assertEq(agentToken1.balanceOf(deal1.vestingContract), TOKEN_AMOUNT);
        assertEq(agentToken2.balanceOf(deal2.vestingContract), TOKEN_AMOUNT);
    }

    function test_getDeal_invalidId_reverts() public {
        vm.expectRevert("AgentDeal: invalid deal ID");
        agentDeal.getDeal(0);
    }

    function test_executeDeal() public {
        // Setup: Fund the contract with USDC
        usdc.mint(owner, 20000e6);
        vm.startPrank(owner);
        usdc.approve(address(agentDeal), 20000e6);
        agentDeal.depositUSDC(20000e6);

        // Setup: Create fresh token with 10,000 supply
        MockERC20 freshToken = new MockERC20("Fresh Token", "FRESH", 18);
        freshToken.mint(address(this), 10000e18);
        uint256 totalSupply = freshToken.totalSupply();
        uint256 expectedTokenAmount = (totalSupply * 20) / 100; // 20% of total supply

        // Create vesting contract (simulating launch contract flow)
        address vestingContract = agentDeal.createVestingContract(address(freshToken), expectedTokenAmount);
        
        vm.stopPrank();
        
        // Send 20% of tokens to vesting contract (simulating launch flow)
        freshToken.transfer(vestingContract, expectedTokenAmount);

        // Execute deal
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit DealExecuted(0, agent1, address(freshToken), vestingContract, expectedTokenAmount, 20000e6);
        
        uint256 dealId = agentDeal.executeDeal(agent1, address(freshToken), vestingContract);

        // Verify deal created correctly
        assertEq(dealId, 0);
        AgentDeal.Deal memory deal = agentDeal.getDeal(dealId);
        assertEq(deal.agent, agent1);
        assertEq(deal.token, address(freshToken));
        assertEq(deal.usdcAmount, 20000e6);
        assertEq(deal.tokenAmount, expectedTokenAmount);
        assertEq(uint8(deal.status), uint8(AgentDeal.DealStatus.Confirmed));
        assertEq(deal.vestingContract, vestingContract);

        // Verify agent received USDC
        assertEq(usdc.balanceOf(agent1), 20000e6);

        // Verify token was added to distributor
        assertEq(mockDistributor.tokenToVesting(address(freshToken)), vestingContract);
    }

    function test_executeDeal_onlyOwner() public {
        address dummyVesting = makeAddr("vesting");
        vm.prank(agent1);
        vm.expectRevert();
        agentDeal.executeDeal(agent1, address(agentToken1), dummyVesting);
    }

    function test_executeDeal_zeroAgent_reverts() public {
        address dummyVesting = makeAddr("vesting");
        vm.prank(owner);
        vm.expectRevert("AgentDeal: agent is the zero address");
        agentDeal.executeDeal(address(0), address(agentToken1), dummyVesting);
    }

    function test_executeDeal_zeroToken_reverts() public {
        address dummyVesting = makeAddr("vesting");
        vm.prank(owner);
        vm.expectRevert("AgentDeal: token is the zero address");
        agentDeal.executeDeal(agent1, address(0), dummyVesting);
    }

    function test_executeDeal_zeroVesting_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: vesting contract is the zero address");
        agentDeal.executeDeal(agent1, address(agentToken1), address(0));
    }

    function test_executeDeal_insufficientUSDC_reverts() public {
        // Create a fresh token for this test to avoid supply accumulation
        MockERC20 freshToken = new MockERC20("Fresh Token", "FRESH", 18);
        freshToken.mint(address(this), 10000e18);
        uint256 totalSupply = freshToken.totalSupply();
        uint256 expectedTokenAmount = (totalSupply * 20) / 100;

        vm.prank(owner);
        address vestingContract = agentDeal.createVestingContract(address(freshToken), expectedTokenAmount);
        freshToken.transfer(vestingContract, expectedTokenAmount);

        vm.prank(owner);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        agentDeal.executeDeal(agent1, address(freshToken), vestingContract);
    }

    function test_depositUSDC() public {
        uint256 depositAmount = 100000e6;
        usdc.mint(owner, depositAmount);
        
        vm.startPrank(owner);
        usdc.approve(address(agentDeal), depositAmount);
        agentDeal.depositUSDC(depositAmount);
        vm.stopPrank();

        assertEq(agentDeal.getUSDCBalance(), depositAmount);
    }

    function test_depositUSDC_onlyOwner() public {
        usdc.mint(agent1, 10000e6);
        
        vm.startPrank(agent1);
        usdc.approve(address(agentDeal), 10000e6);
        vm.expectRevert();
        agentDeal.depositUSDC(10000e6);
        vm.stopPrank();
    }

    function test_depositUSDC_zeroAmount_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: amount must be > 0");
        agentDeal.depositUSDC(0);
    }

    function test_withdrawUSDC() public {
        // First deposit
        uint256 depositAmount = 100000e6;
        usdc.mint(owner, depositAmount);
        
        vm.startPrank(owner);
        usdc.approve(address(agentDeal), depositAmount);
        agentDeal.depositUSDC(depositAmount);

        // Then withdraw
        uint256 withdrawAmount = 50000e6;
        address withdrawTo = makeAddr("treasury");
        
        agentDeal.withdrawUSDC(withdrawAmount, withdrawTo);
        vm.stopPrank();

        assertEq(agentDeal.getUSDCBalance(), depositAmount - withdrawAmount);
        assertEq(usdc.balanceOf(withdrawTo), withdrawAmount);
    }

    function test_withdrawUSDC_onlyOwner() public {
        vm.prank(agent1);
        vm.expectRevert();
        agentDeal.withdrawUSDC(1000e6, agent1);
    }

    function test_withdrawUSDC_zeroAmount_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: amount must be > 0");
        agentDeal.withdrawUSDC(0, owner);
    }

    function test_withdrawUSDC_zeroTo_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: to is the zero address");
        agentDeal.withdrawUSDC(1000e6, address(0));
    }

    function test_getUSDCBalance() public {
        assertEq(agentDeal.getUSDCBalance(), 0);
        
        usdc.mint(owner, 50000e6);
        vm.startPrank(owner);
        usdc.approve(address(agentDeal), 50000e6);
        agentDeal.depositUSDC(50000e6);
        vm.stopPrank();
        
        assertEq(agentDeal.getUSDCBalance(), 50000e6);
    }

    function test_createVestingContract() public {
        uint256 tokenAmount = 2000e18;
        
        vm.prank(owner);
        address vestingContract = agentDeal.createVestingContract(address(agentToken1), tokenAmount);
        
        assertTrue(vestingContract != address(0));
        
        // Verify vesting contract parameters
        TokenVesting vesting = TokenVesting(vestingContract);
        assertEq(address(vesting.token()), address(agentToken1));
        assertEq(vesting.beneficiary(), address(mockDistributor));
        assertEq(vesting.cliff(), 1_209_600);
        assertEq(vesting.vestingDuration(), 7_776_000);
        assertEq(vesting.totalAmount(), tokenAmount);
    }

    function test_createVestingContract_onlyOwner() public {
        vm.prank(agent1);
        vm.expectRevert();
        agentDeal.createVestingContract(address(agentToken1), 1000e18);
    }

    function test_createVestingContract_zeroToken_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: token is the zero address");
        agentDeal.createVestingContract(address(0), 1000e18);
    }

    function test_createVestingContract_zeroAmount_reverts() public {
        vm.prank(owner);
        vm.expectRevert("AgentDeal: token amount must be > 0");
        agentDeal.createVestingContract(address(agentToken1), 0);
    }

    function test_atomicLaunchFlow() public {
        // Simulate complete atomic launch flow
        
        // 1. Fund the deal contract with USDC
        usdc.mint(owner, 20000e6);
        vm.startPrank(owner);
        usdc.approve(address(agentDeal), 20000e6);
        agentDeal.depositUSDC(20000e6);

        // 2. Token launch creates fresh token with 10,000 tokens
        MockERC20 launchToken = new MockERC20("Launch Token", "LAUNCH", 18);
        launchToken.mint(address(this), 10000e18); // Launch contract gets all tokens
        uint256 totalSupply = launchToken.totalSupply();

        // 3. Launch contract creates vesting contract
        uint256 vestingAmount = (totalSupply * 20) / 100;
        address vestingContract = agentDeal.createVestingContract(address(launchToken), vestingAmount);
        
        vm.stopPrank();
        
        // 4. Launch contract sends 20% to vesting
        launchToken.transfer(vestingContract, vestingAmount);
        
        // 5. Execute deal atomically
        vm.prank(owner);
        uint256 dealId = agentDeal.executeDeal(agent1, address(launchToken), vestingContract);

        // Verify everything worked
        AgentDeal.Deal memory deal = agentDeal.getDeal(dealId);
        assertEq(deal.agent, agent1);
        assertEq(deal.token, address(launchToken));
        assertEq(deal.tokenAmount, vestingAmount);
        assertEq(uint8(deal.status), uint8(AgentDeal.DealStatus.Confirmed));
        assertEq(deal.vestingContract, vestingContract);
        
        // Agent got USDC
        assertEq(usdc.balanceOf(agent1), 20000e6);
        
        // Token registered with distributor
        assertEq(mockDistributor.tokenToVesting(address(launchToken)), vestingContract);
        
        // Vesting contract has the tokens
        assertEq(launchToken.balanceOf(vestingContract), vestingAmount);
    }
}