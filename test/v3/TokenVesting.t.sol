// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
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

contract TokenVestingTest is Test {
    TokenVesting public vesting;
    MockERC20 public token;
    
    address public beneficiary = makeAddr("beneficiary");
    address public agent = makeAddr("agent");
    
    uint256 public constant CLIFF_DURATION = 1_209_600; // 2 weeks
    uint256 public constant VESTING_DURATION = 7_776_000; // 3 months
    uint256 public constant TOTAL_AMOUNT = 1000e18; // 1000 tokens

    event TokensReleased(uint256 amount);

    function setUp() public {
        token = new MockERC20("Agent Token", "AGT", 18);
        
        vesting = new TokenVesting(
            address(token),
            beneficiary,
            CLIFF_DURATION,
            VESTING_DURATION,
            TOTAL_AMOUNT
        );

        // Mint tokens to agent and transfer to vesting contract
        token.mint(agent, TOTAL_AMOUNT);
        vm.prank(agent);
        token.transfer(address(vesting), TOTAL_AMOUNT);
    }

    function test_constructor() public view {
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.cliff(), CLIFF_DURATION);
        assertEq(vesting.vestingDuration(), VESTING_DURATION);
        assertEq(vesting.totalAmount(), TOTAL_AMOUNT);
        assertEq(vesting.released(), 0);
        assertEq(vesting.startTime(), block.timestamp);
    }

    function test_constructor_zeroToken_reverts() public {
        vm.expectRevert("TokenVesting: token is the zero address");
        new TokenVesting(address(0), beneficiary, CLIFF_DURATION, VESTING_DURATION, TOTAL_AMOUNT);
    }

    function test_constructor_zeroBeneficiary_reverts() public {
        vm.expectRevert("TokenVesting: beneficiary is the zero address");
        new TokenVesting(address(token), address(0), CLIFF_DURATION, VESTING_DURATION, TOTAL_AMOUNT);
    }

    function test_constructor_zeroCliff_reverts() public {
        vm.expectRevert("TokenVesting: cliff must be > 0");
        new TokenVesting(address(token), beneficiary, 0, VESTING_DURATION, TOTAL_AMOUNT);
    }

    function test_constructor_zeroVestingDuration_reverts() public {
        vm.expectRevert("TokenVesting: vesting duration must be > 0");
        new TokenVesting(address(token), beneficiary, CLIFF_DURATION, 0, TOTAL_AMOUNT);
    }

    function test_constructor_zeroTotalAmount_reverts() public {
        vm.expectRevert("TokenVesting: total amount must be > 0");
        new TokenVesting(address(token), beneficiary, CLIFF_DURATION, VESTING_DURATION, 0);
    }

    function test_vestedAmount_beforeCliff() public {
        // Time before cliff should return 0
        assertEq(vesting.vestedAmount(), 0);
        
        // Just before cliff ends
        vm.warp(block.timestamp + CLIFF_DURATION - 1);
        assertEq(vesting.vestedAmount(), 0);
    }

    function test_vestedAmount_afterCliffBeforeFullVesting() public {
        // Right after cliff
        vm.warp(block.timestamp + CLIFF_DURATION + 1);
        uint256 vested = vesting.vestedAmount();
        assertGt(vested, 0);
        assertLt(vested, TOTAL_AMOUNT);
        
        // Halfway through vesting period
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        vested = vesting.vestedAmount();
        assertApproxEqAbs(vested, TOTAL_AMOUNT / 2, 1e15); // Allow small rounding error
    }

    function test_vestedAmount_afterFullVesting() public {
        // After full vesting period
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION + 1);
        assertEq(vesting.vestedAmount(), TOTAL_AMOUNT);
    }

    function test_releasable_beforeCliff() public {
        assertEq(vesting.releasable(), 0);
    }

    function test_releasable_afterCliff() public {
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 4);
        uint256 vested = vesting.vestedAmount();
        assertEq(vesting.releasable(), vested);
    }

    function test_release_beforeCliff_reverts() public {
        vm.expectRevert("TokenVesting: no tokens are due");
        vesting.release();
    }

    function test_release_afterCliff() public {
        // Move to 25% through vesting period
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 4);
        
        uint256 expectedVested = vesting.vestedAmount();
        uint256 beneficiaryBalanceBefore = token.balanceOf(beneficiary);
        
        vm.expectEmit(true, true, true, true);
        emit TokensReleased(expectedVested);
        vesting.release();
        
        assertEq(vesting.released(), expectedVested);
        assertEq(token.balanceOf(beneficiary), beneficiaryBalanceBefore + expectedVested);
        assertEq(vesting.releasable(), 0);
    }

    function test_release_multipleReleases() public {
        // First release at 25% vesting
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 4);
        uint256 firstVested = vesting.vestedAmount();
        vesting.release();
        
        // Second release at 75% vesting
        vm.warp(block.timestamp + CLIFF_DURATION + 3 * VESTING_DURATION / 4);
        uint256 secondVested = vesting.vestedAmount();
        uint256 secondReleasable = vesting.releasable();
        
        vesting.release();
        
        assertEq(vesting.released(), secondVested);
        assertEq(secondReleasable, secondVested - firstVested);
    }

    function test_release_fullVesting() public {
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION + 1);
        
        vesting.release();
        
        assertEq(vesting.released(), TOTAL_AMOUNT);
        assertEq(token.balanceOf(beneficiary), TOTAL_AMOUNT);
        assertEq(vesting.releasable(), 0);
    }

    function test_release_canBeCalledByAnyone() public {
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        vesting.release();
        
        assertGt(vesting.released(), 0);
        assertGt(token.balanceOf(beneficiary), 0);
    }

    function test_cliffEnd() public view {
        assertEq(vesting.cliffEnd(), block.timestamp + CLIFF_DURATION);
    }

    function test_vestingEnd() public view {
        assertEq(vesting.vestingEnd(), block.timestamp + CLIFF_DURATION + VESTING_DURATION);
    }

    function test_vestingLinearProgression() public {
        uint256 quarterVestingTime = VESTING_DURATION / 4;
        
        // Test vesting at different points
        vm.warp(block.timestamp + CLIFF_DURATION + quarterVestingTime);
        uint256 quarterVested = vesting.vestedAmount();
        
        vm.warp(block.timestamp + CLIFF_DURATION + 2 * quarterVestingTime);
        uint256 halfVested = vesting.vestedAmount();
        
        vm.warp(block.timestamp + CLIFF_DURATION + 3 * quarterVestingTime);
        uint256 threeQuarterVested = vesting.vestedAmount();
        
        // Check linear progression (allow small rounding errors)
        assertApproxEqAbs(halfVested, 2 * quarterVested, 1e15);
        assertApproxEqAbs(threeQuarterVested, 3 * quarterVested, 1e15);
    }

    function test_noTokensInContract_release_reverts() public {
        // Create vesting without funding it
        TokenVesting unfundedVesting = new TokenVesting(
            address(token),
            beneficiary,
            CLIFF_DURATION,
            VESTING_DURATION,
            TOTAL_AMOUNT
        );
        
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        unfundedVesting.release();
    }

    function test_immutability() public {
        // Test that contract parameters cannot be changed after deployment
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.cliff(), CLIFF_DURATION);
        assertEq(vesting.vestingDuration(), VESTING_DURATION);
        assertEq(vesting.totalAmount(), TOTAL_AMOUNT);
        
        // Simulate passage of time and releases
        vm.warp(block.timestamp + CLIFF_DURATION + VESTING_DURATION / 2);
        vesting.release();
        
        // Parameters should remain unchanged
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.cliff(), CLIFF_DURATION);
        assertEq(vesting.vestingDuration(), VESTING_DURATION);
        assertEq(vesting.totalAmount(), TOTAL_AMOUNT);
    }
}