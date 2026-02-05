// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TokenVesting
 * @dev Holds an agent's tokens with cliff + linear vesting. One instance per investment.
 * @notice Once deployed, this contract is fully immutable - no admin can change the schedule or steal tokens.
 * This protects agents from the fund changing terms after deployment.
 */
contract TokenVesting {
    using SafeERC20 for IERC20;

    /// @notice The ERC20 token being vested
    IERC20 public immutable token;
    
    /// @notice Address that will receive the vested tokens (TokenDistributor)
    address public immutable beneficiary;
    
    /// @notice Cliff period in seconds (2 weeks = 1,209,600)
    uint256 public immutable cliff;
    
    /// @notice Vesting duration after cliff in seconds (3 months = 7,776,000)
    uint256 public immutable vestingDuration;
    
    /// @notice Total amount of tokens to be vested
    uint256 public immutable totalAmount;
    
    /// @notice Timestamp when vesting starts
    uint256 public immutable startTime;
    
    /// @notice Amount of tokens already released
    uint256 public released;

    /// @notice Emitted when tokens are released
    event TokensReleased(uint256 amount);

    /**
     * @dev Creates a vesting contract that vests tokens with a cliff period followed by linear vesting
     * @param _token Address of the ERC20 token being vested
     * @param _beneficiary Address that will receive the vested tokens
     * @param _cliff Cliff period in seconds
     * @param _vestingDuration Vesting duration after cliff in seconds  
     * @param _totalAmount Total amount of tokens to be vested
     */
    constructor(
        address _token,
        address _beneficiary,
        uint256 _cliff,
        uint256 _vestingDuration,
        uint256 _totalAmount
    ) {
        require(_token != address(0), "TokenVesting: token is the zero address");
        require(_beneficiary != address(0), "TokenVesting: beneficiary is the zero address");
        require(_cliff > 0, "TokenVesting: cliff must be > 0");
        require(_vestingDuration > 0, "TokenVesting: vesting duration must be > 0");
        require(_totalAmount > 0, "TokenVesting: total amount must be > 0");

        token = IERC20(_token);
        beneficiary = _beneficiary;
        cliff = _cliff;
        vestingDuration = _vestingDuration;
        totalAmount = _totalAmount;
        startTime = block.timestamp;
    }

    /**
     * @notice Release vested tokens to the beneficiary
     * @dev Can be called by anyone. Sends all currently vested tokens to beneficiary.
     */
    function release() external {
        uint256 unreleased = releasable();
        require(unreleased > 0, "TokenVesting: no tokens are due");

        released = released + unreleased;
        token.safeTransfer(beneficiary, unreleased);

        emit TokensReleased(unreleased);
    }

    /**
     * @notice Calculate amount of tokens that have vested so far
     * @return Amount of tokens that have vested
     */
    function vestedAmount() public view returns (uint256) {
        if (block.timestamp < startTime + cliff) {
            // Still in cliff period
            return 0;
        } else if (block.timestamp >= startTime + cliff + vestingDuration) {
            // Fully vested
            return totalAmount;
        } else {
            // Linear vesting after cliff
            uint256 timeSinceCliff = block.timestamp - (startTime + cliff);
            return (totalAmount * timeSinceCliff) / vestingDuration;
        }
    }

    /**
     * @notice Calculate amount of tokens that can be released (vested minus already released)
     * @return Amount of tokens that can be released
     */
    function releasable() public view returns (uint256) {
        return vestedAmount() - released;
    }

    /**
     * @notice Get the timestamp when cliff period ends
     * @return Timestamp when cliff ends
     */
    function cliffEnd() external view returns (uint256) {
        return startTime + cliff;
    }

    /**
     * @notice Get the timestamp when vesting fully completes
     * @return Timestamp when vesting ends
     */
    function vestingEnd() external view returns (uint256) {
        return startTime + cliff + vestingDuration;
    }
}