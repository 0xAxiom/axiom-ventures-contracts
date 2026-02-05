// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {TokenDistributor} from "../../src/v3/TokenDistributor.sol";
import {TokenVesting} from "../../src/v3/TokenVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

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

    function burn(address from, uint256 amount) external {
        require(_balances[from] >= amount, "ERC20: burn amount exceeds balance");
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
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

contract MockERC4626 is IERC4626 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    IERC20 private _asset;
    
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(address asset_) {
        _asset = IERC20(asset_);
        _name = "Vault Shares";
        _symbol = "SHARES";
        _decimals = 18;
    }

    // ERC20 functions
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _approve(from, msg.sender, currentAllowance - amount);
        _transfer(from, to, amount);
        return true;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    // ERC4626 functions
    function asset() external view override returns (address) {
        return address(_asset);
    }

    function totalAssets() external view override returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) external pure override returns (uint256) {
        return assets; // 1:1 conversion for simplicity
    }

    function convertToAssets(uint256 shares) external pure override returns (uint256) {
        return shares; // 1:1 conversion for simplicity
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        _asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, assets);
        emit Deposit(msg.sender, receiver, assets, assets);
        return assets;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function mint(uint256 shares, address receiver) external override returns (uint256) {
        _asset.transferFrom(msg.sender, address(this), shares);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, shares, shares);
        return shares;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return _balances[owner];
    }

    function previewWithdraw(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256) {
        if (msg.sender != owner) {
            uint256 currentAllowance = _allowances[owner][msg.sender];
            require(currentAllowance >= assets, "ERC4626: insufficient allowance");
            _approve(owner, msg.sender, currentAllowance - assets);
        }
        
        _burn(owner, assets);
        _asset.transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, assets);
        return assets;
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return _balances[owner];
    }

    function previewRedeem(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256) {
        if (msg.sender != owner) {
            uint256 currentAllowance = _allowances[owner][msg.sender];
            require(currentAllowance >= shares, "ERC4626: insufficient allowance");
            _approve(owner, msg.sender, currentAllowance - shares);
        }
        
        _burn(owner, shares);
        _asset.transfer(receiver, shares);
        emit Withdraw(msg.sender, receiver, owner, shares, shares);
        return shares;
    }

    // Internal functions
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

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ERC20: mint to the zero address");
        
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(from != address(0), "ERC20: burn from the zero address");
        require(_balances[from] >= amount, "ERC20: burn amount exceeds balance");
        
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}

contract TokenDistributorTest is Test {
    TokenDistributor public distributor;
    MockERC4626 public vault;
    MockERC20 public usdc;
    MockERC20 public agentToken1;
    MockERC20 public agentToken2;
    TokenVesting public vesting1;
    TokenVesting public vesting2;
    
    address public owner = makeAddr("owner");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public lp3 = makeAddr("lp3");
    
    uint256 public constant CLIFF_DURATION = 1_209_600; // 2 weeks
    uint256 public constant VESTING_DURATION = 7_776_000; // 3 months
    uint256 public constant TOKEN_AMOUNT = 2000e18; // 20% of supply

    event TokensClaimed(address indexed user, address indexed token, uint256 amount);
    event TokensReleased(address indexed vestingContract, address indexed token, uint256 amount);
    event TokenAdded(address indexed token, address indexed vestingContract);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockERC4626(address(usdc));
        distributor = new TokenDistributor(address(vault), owner);
        
        agentToken1 = new MockERC20("Agent Token 1", "AGT1", 18);
        agentToken2 = new MockERC20("Agent Token 2", "AGT2", 18);
        
        // Create vesting contracts
        vesting1 = new TokenVesting(
            address(agentToken1),
            address(distributor),
            CLIFF_DURATION,
            VESTING_DURATION,
            TOKEN_AMOUNT
        );
        
        vesting2 = new TokenVesting(
            address(agentToken2),
            address(distributor),
            CLIFF_DURATION,
            VESTING_DURATION,
            TOKEN_AMOUNT
        );
        
        // Mint USDC and set up vault shares for LPs
        usdc.mint(lp1, 10000e6);
        usdc.mint(lp2, 20000e6);
        usdc.mint(lp3, 30000e6);
        
        // LPs deposit into vault (LP1: 10k, LP2: 20k, LP3: 30k = 60k total)
        vm.startPrank(lp1);
        usdc.approve(address(vault), 10000e6);
        vault.deposit(10000e6, lp1);
        vm.stopPrank();
        
        vm.startPrank(lp2);
        usdc.approve(address(vault), 20000e6);
        vault.deposit(20000e6, lp2);
        vm.stopPrank();
        
        vm.startPrank(lp3);
        usdc.approve(address(vault), 30000e6);
        vault.deposit(30000e6, lp3);
        vm.stopPrank();
        
        // Fund vesting contracts
        agentToken1.mint(address(vesting1), TOKEN_AMOUNT);
        agentToken2.mint(address(vesting2), TOKEN_AMOUNT);
        
        // Add tokens to distributor
        vm.startPrank(owner);
        distributor.addToken(address(agentToken1), address(vesting1));
        distributor.addToken(address(agentToken2), address(vesting2));
        vm.stopPrank();
    }

    function test_constructor() public view {
        assertEq(address(distributor.vault()), address(vault));
        assertEq(distributor.owner(), owner);
    }

    function test_constructor_zeroVault_reverts() public {
        vm.expectRevert("TokenDistributor: vault is the zero address");
        new TokenDistributor(address(0), owner);
    }

    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert();
        new TokenDistributor(address(vault), address(0));
    }

    function test_addToken() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        TokenVesting newVesting = new TokenVesting(
            address(newToken),
            address(distributor),
            CLIFF_DURATION,
            VESTING_DURATION,
            1000e18
        );
        
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit TokenAdded(address(newToken), address(newVesting));
        distributor.addToken(address(newToken), address(newVesting));
        
        assertTrue(distributor.isTokenRegistered(address(newToken)));
        assertEq(distributor.tokenToVesting(address(newToken)), address(newVesting));
        assertEq(distributor.getTokenCount(), 3);
    }

    function test_addToken_onlyOwner() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        TokenVesting newVesting = new TokenVesting(
            address(newToken),
            address(distributor),
            CLIFF_DURATION,
            VESTING_DURATION,
            1000e18
        );
        
        vm.prank(lp1);
        vm.expectRevert();
        distributor.addToken(address(newToken), address(newVesting));
    }

    function test_addToken_zeroToken_reverts() public {
        vm.prank(owner);
        vm.expectRevert("TokenDistributor: token is the zero address");
        distributor.addToken(address(0), address(vesting1));
    }

    function test_addToken_zeroVesting_reverts() public {
        vm.prank(owner);
        vm.expectRevert("TokenDistributor: vesting contract is the zero address");
        distributor.addToken(address(agentToken1), address(0));
    }

    function test_addToken_alreadyRegistered_reverts() public {
        vm.prank(owner);
        vm.expectRevert("TokenDistributor: token already registered");
        distributor.addToken(address(agentToken1), address(vesting1));
    }

    function test_addToken_tokenMismatch_reverts() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        
        vm.prank(owner);
        vm.expectRevert("TokenDistributor: token mismatch");
        distributor.addToken(address(newToken), address(vesting2));
    }

    function test_addToken_beneficiaryMismatch_reverts() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        TokenVesting wrongVesting = new TokenVesting(
            address(newToken),
            lp1, // Wrong beneficiary
            CLIFF_DURATION,
            VESTING_DURATION,
            TOKEN_AMOUNT
        );
        
        vm.prank(owner);
        vm.expectRevert("TokenDistributor: beneficiary mismatch");
        distributor.addToken(address(newToken), address(wrongVesting));
    }

    function test_release() public {
        // Move time to after cliff + some vesting
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 4);
        
        uint256 releasableBefore = vesting1.releasable();
        assertTrue(releasableBefore > 0);
        
        vm.expectEmit(true, true, true, true);
        emit TokensReleased(address(vesting1), address(agentToken1), releasableBefore);
        distributor.release(address(vesting1));
        
        assertEq(agentToken1.balanceOf(address(distributor)), releasableBefore);
        assertEq(vesting1.releasable(), 0);
    }

    function test_release_notBeneficiary_reverts() public {
        TokenVesting wrongVesting = new TokenVesting(
            address(agentToken1),
            lp1, // Wrong beneficiary
            CLIFF_DURATION,
            VESTING_DURATION,
            TOKEN_AMOUNT
        );
        
        vm.expectRevert("TokenDistributor: not beneficiary");
        distributor.release(address(wrongVesting));
    }

    function test_release_noTokens_reverts() public {
        // Before cliff, no tokens should be releasable
        vm.expectRevert("TokenDistributor: no tokens to release");
        distributor.release(address(vesting1));
    }

    function test_claimable_beforeVesting() public {
        uint256 claimable1 = distributor.claimable(address(agentToken1), lp1);
        assertEq(claimable1, 0);
    }

    function test_claimable_afterVesting() public {
        // Move time and release tokens
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        distributor.release(address(vesting1));
        
        uint256 distributorBalance = agentToken1.balanceOf(address(distributor));
        assertTrue(distributorBalance > 0);
        
        // LP1 has 10k out of 60k total = 1/6 share
        uint256 expectedLp1 = distributorBalance / 6;
        uint256 claimable1 = distributor.claimable(address(agentToken1), lp1);
        assertApproxEqAbs(claimable1, expectedLp1, 1);
        
        // LP2 has 20k out of 60k total = 1/3 share
        uint256 expectedLp2 = distributorBalance / 3;
        uint256 claimable2 = distributor.claimable(address(agentToken1), lp2);
        assertApproxEqAbs(claimable2, expectedLp2, 1);
        
        // LP3 has 30k out of 60k total = 1/2 share
        uint256 expectedLp3 = distributorBalance / 2;
        uint256 claimable3 = distributor.claimable(address(agentToken1), lp3);
        assertApproxEqAbs(claimable3, expectedLp3, 1);
    }

    function test_claimable_unregisteredToken() public {
        MockERC20 unregisteredToken = new MockERC20("Unregistered", "UNREG", 18);
        uint256 claimable = distributor.claimable(address(unregisteredToken), lp1);
        assertEq(claimable, 0);
    }

    function test_claimable_noShares() public {
        address lpWithNoShares = makeAddr("noShares");
        uint256 claimable = distributor.claimable(address(agentToken1), lpWithNoShares);
        assertEq(claimable, 0);
    }

    function test_claimable_zeroTotalShares() public {
        // Create a new distributor with empty vault
        MockERC4626 emptyVault = new MockERC4626(address(usdc));
        TokenDistributor newDistributor = new TokenDistributor(address(emptyVault), owner);
        
        uint256 claimable = newDistributor.claimable(address(agentToken1), lp1);
        assertEq(claimable, 0);
    }

    function test_claim() public {
        // Setup: move time and release tokens
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        distributor.release(address(vesting1));
        
        uint256 claimableBefore = distributor.claimable(address(agentToken1), lp1);
        assertTrue(claimableBefore > 0);
        
        uint256 lp1BalanceBefore = agentToken1.balanceOf(lp1);
        
        vm.prank(lp1);
        vm.expectEmit(true, true, true, true);
        emit TokensClaimed(lp1, address(agentToken1), claimableBefore);
        distributor.claim(address(agentToken1));
        
        assertEq(agentToken1.balanceOf(lp1), lp1BalanceBefore + claimableBefore);
        assertEq(distributor.claimed(address(agentToken1), lp1), claimableBefore);
        assertEq(distributor.claimable(address(agentToken1), lp1), 0);
    }

    function test_claim_unregisteredToken_reverts() public {
        MockERC20 unregisteredToken = new MockERC20("Unregistered", "UNREG", 18);
        
        vm.prank(lp1);
        vm.expectRevert("TokenDistributor: token not registered");
        distributor.claim(address(unregisteredToken));
    }

    function test_claim_noTokensToClaimUU_reverts() public {
        vm.prank(lp1);
        vm.expectRevert("TokenDistributor: no tokens to claim");
        distributor.claim(address(agentToken1));
    }

    function test_claim_multipleReleases() public {
        // First release at 25% vesting
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 4);
        distributor.release(address(vesting1));
        
        vm.prank(lp1);
        distributor.claim(address(agentToken1));
        uint256 firstClaim = agentToken1.balanceOf(lp1);
        
        // Second release at 75% vesting
        vm.warp(block.timestamp + CLIFF_DURATION + 3 * VESTING_DURATION / 4);
        distributor.release(address(vesting1));
        
        vm.prank(lp1);
        distributor.claim(address(agentToken1));
        uint256 secondClaim = agentToken1.balanceOf(lp1) - firstClaim;
        
        assertTrue(secondClaim > firstClaim); // More tokens vested, so more to claim
    }

    function test_claimMultiple() public {
        // Setup both tokens
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        distributor.release(address(vesting1));
        distributor.release(address(vesting2));
        
        uint256 claimable1 = distributor.claimable(address(agentToken1), lp1);
        uint256 claimable2 = distributor.claimable(address(agentToken2), lp1);
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(agentToken1);
        tokens[1] = address(agentToken2);
        
        uint256 lp1Balance1Before = agentToken1.balanceOf(lp1);
        uint256 lp1Balance2Before = agentToken2.balanceOf(lp1);
        
        vm.prank(lp1);
        distributor.claimMultiple(tokens);
        
        assertEq(agentToken1.balanceOf(lp1), lp1Balance1Before + claimable1);
        assertEq(agentToken2.balanceOf(lp1), lp1Balance2Before + claimable2);
    }

    function test_getTokenCount() public view {
        assertEq(distributor.getTokenCount(), 2);
    }

    function test_getAllTokens() public view {
        address[] memory tokens = distributor.getAllTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(agentToken1));
        assertEq(tokens[1], address(agentToken2));
    }

    function test_getTokens_pagination() public {
        address[] memory page1 = distributor.getTokens(0, 1);
        assertEq(page1.length, 1);
        assertEq(page1[0], address(agentToken1));
        
        address[] memory page2 = distributor.getTokens(1, 1);
        assertEq(page2.length, 1);
        assertEq(page2[0], address(agentToken2));
    }

    function test_getTokens_offsetOutOfBounds_reverts() public {
        vm.expectRevert("TokenDistributor: offset out of bounds");
        distributor.getTokens(10, 1);
    }

    function test_getClaimableAmounts() public {
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        distributor.release(address(vesting1));
        distributor.release(address(vesting2));
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(agentToken1);
        tokens[1] = address(agentToken2);
        
        uint256[] memory amounts = distributor.getClaimableAmounts(lp1, tokens);
        assertEq(amounts.length, 2);
        assertEq(amounts[0], distributor.claimable(address(agentToken1), lp1));
        assertEq(amounts[1], distributor.claimable(address(agentToken2), lp1));
    }

    function test_getUserVaultSharePercentage() public view {
        // LP1: 10k out of 60k = 16.67% = 1666 basis points
        assertEq(distributor.getUserVaultSharePercentage(lp1), 1666);
        
        // LP2: 20k out of 60k = 33.33% = 3333 basis points
        assertEq(distributor.getUserVaultSharePercentage(lp2), 3333);
        
        // LP3: 30k out of 60k = 50% = 5000 basis points
        assertEq(distributor.getUserVaultSharePercentage(lp3), 5000);
    }

    function test_proRataDistribution() public {
        // Test the core pro-rata logic with full vesting
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION + 1);
        distributor.release(address(vesting1));
        
        // All LPs claim
        vm.prank(lp1);
        distributor.claim(address(agentToken1));
        vm.prank(lp2);
        distributor.claim(address(agentToken1));
        vm.prank(lp3);
        distributor.claim(address(agentToken1));
        
        uint256 lp1Balance = agentToken1.balanceOf(lp1);
        uint256 lp2Balance = agentToken1.balanceOf(lp2);
        uint256 lp3Balance = agentToken1.balanceOf(lp3);
        uint256 totalClaimed = lp1Balance + lp2Balance + lp3Balance;
        
        // Should equal the full vested amount (allowing 1 wei rounding error)
        assertApproxEqAbs(totalClaimed, TOKEN_AMOUNT, 1);
        
        // Check proportions based on vault shares (10k, 20k, 30k out of 60k)  
        // LP1: 10/60 = 1/6 of total
        assertApproxEqRel(lp1Balance, TOKEN_AMOUNT / 6, 0.01e18);
        // LP2: 20/60 = 1/3 of total  
        assertApproxEqRel(lp2Balance, TOKEN_AMOUNT / 3, 0.01e18);
        // LP3: 30/60 = 1/2 of total
        assertApproxEqRel(lp3Balance, TOKEN_AMOUNT / 2, 0.01e18);
    }

    function test_noDubleClaimPrevention() public {
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        distributor.release(address(vesting1));
        
        vm.prank(lp1);
        distributor.claim(address(agentToken1));
        uint256 firstClaim = agentToken1.balanceOf(lp1);
        
        // Try to claim again without new vesting
        uint256 claimableAfter = distributor.claimable(address(agentToken1), lp1);
        assertEq(claimableAfter, 0);
        
        vm.prank(lp1);
        vm.expectRevert("TokenDistributor: no tokens to claim");
        distributor.claim(address(agentToken1));
        
        assertEq(agentToken1.balanceOf(lp1), firstClaim); // No change
    }

    function test_dynamicShareChanges() public {
        // LP1 withdraws half their shares  
        uint256 lp1Shares = vault.balanceOf(lp1);
        vm.prank(lp1);
        vault.redeem(lp1Shares / 2, lp1, lp1);
        
        // Now shares: LP1=5k, LP2=20k, LP3=30k = 55k total
        assertEq(distributor.getUserVaultSharePercentage(lp1), 909); // 5/55 = ~9.09%
        assertEq(distributor.getUserVaultSharePercentage(lp2), 3636); // 20/55 = ~36.36%
        assertEq(distributor.getUserVaultSharePercentage(lp3), 5454); // 30/55 = ~54.54%
        
        // Release and claim with new share ratios
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION + 1);
        distributor.release(address(vesting1));
        
        vm.prank(lp1);
        distributor.claim(address(agentToken1));
        vm.prank(lp2);
        distributor.claim(address(agentToken1));
        vm.prank(lp3);
        distributor.claim(address(agentToken1));
        
        uint256 lp1Balance = agentToken1.balanceOf(lp1);
        uint256 lp2Balance = agentToken1.balanceOf(lp2);
        uint256 lp3Balance = agentToken1.balanceOf(lp3);
        
        // Check new proportions based on TOKEN_AMOUNT
        assertApproxEqRel(lp1Balance, TOKEN_AMOUNT * 5 / 55, 0.01e18); // 5/55 share
        assertApproxEqRel(lp2Balance, TOKEN_AMOUNT * 20 / 55, 0.01e18); // 20/55 share
        assertApproxEqRel(lp3Balance, TOKEN_AMOUNT * 30 / 55, 0.01e18); // 30/55 share
    }
}