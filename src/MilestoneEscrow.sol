// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MilestoneEscrow
 * @dev Holds invested capital in milestone-based tranches with clawback functionality
 * @notice Enables controlled release of funds based on milestone achievement
 */
contract MilestoneEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Status of each milestone
    enum MilestoneStatus {
        Pending,
        Released,
        Clawed
    }

    /// @notice Milestone structure
    struct Milestone {
        uint256 amount;
        string description;
        MilestoneStatus status;
        uint256 releasedAt;
    }

    /// @notice USDC token contract
    IERC20 public immutable asset;
    
    /// @notice Vault contract that created this escrow
    address public immutable vault;
    
    /// @notice Recipient of milestone funds
    address public immutable recipient;
    
    /// @notice Deadline for fund release, after which clawback is automatic
    uint256 public immutable deadline;
    
    /// @notice Array of milestones
    Milestone[] public milestones;
    
    /// @notice Total amount escrowed
    uint256 public totalAmount;
    
    /// @notice Amount already released
    uint256 public totalReleased;
    
    /// @notice Whether escrow has been fully clawed back
    bool public isClawedBack;

    event MilestoneReleased(uint256 indexed milestoneId, uint256 amount, address recipient);
    event EmergencyClawback(uint256 amount, address vault);
    event AutoClawback(uint256 amount, address vault);
    event EscrowCreated(address vault, address recipient, uint256 totalAmount, uint256 deadline);

    error InvalidMilestone();
    error MilestoneAlreadyProcessed();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error InsufficientBalance();
    error EscrowClawedBack();
    error OnlyVault();
    error InvalidAmount();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier notClawedBack() {
        if (isClawedBack) revert EscrowClawedBack();
        _;
    }

    /**
     * @notice Initialize the milestone escrow
     * @param asset_ USDC token address
     * @param vault_ Vault contract address
     * @param recipient_ Address to receive released funds
     * @param deadline_ Deadline for automatic clawback
     * @param amounts_ Array of milestone amounts
     * @param descriptions_ Array of milestone descriptions
     */
    constructor(
        IERC20 asset_,
        address vault_,
        address recipient_,
        uint256 deadline_,
        uint256[] memory amounts_,
        string[] memory descriptions_
    ) Ownable(vault_) {
        if (amounts_.length != descriptions_.length || amounts_.length == 0) {
            revert InvalidMilestone();
        }
        if (deadline_ <= block.timestamp) {
            revert InvalidAmount();
        }

        asset = asset_;
        vault = vault_;
        recipient = recipient_;
        deadline = deadline_;

        uint256 total = 0;
        for (uint256 i = 0; i < amounts_.length; i++) {
            if (amounts_[i] == 0) revert InvalidAmount();
            
            milestones.push(Milestone({
                amount: amounts_[i],
                description: descriptions_[i],
                status: MilestoneStatus.Pending,
                releasedAt: 0
            }));
            
            total += amounts_[i];
        }
        
        totalAmount = total;

        emit EscrowCreated(vault_, recipient_, total, deadline_);
    }

    /**
     * @notice Fund the escrow (called by vault after deployment)
     * @param amount Amount to fund
     */
    function fund(uint256 amount) external onlyVault {
        if (amount != totalAmount) revert InvalidAmount();
        asset.safeTransferFrom(vault, address(this), amount);
    }

    /**
     * @notice Release a specific milestone
     * @param milestoneId Index of the milestone to release
     * @dev Only owner (vault) can release milestones
     */
    function releaseMilestone(uint256 milestoneId) external onlyOwner nonReentrant notClawedBack {
        if (milestoneId >= milestones.length) revert InvalidMilestone();
        if (block.timestamp > deadline) revert DeadlinePassed();
        
        Milestone storage milestone = milestones[milestoneId];
        if (milestone.status != MilestoneStatus.Pending) {
            revert MilestoneAlreadyProcessed();
        }

        milestone.status = MilestoneStatus.Released;
        milestone.releasedAt = block.timestamp;
        totalReleased += milestone.amount;

        asset.safeTransfer(recipient, milestone.amount);
        
        emit MilestoneReleased(milestoneId, milestone.amount, recipient);
    }

    /**
     * @notice Release multiple milestones at once
     * @param milestoneIds Array of milestone indices to release
     */
    function releaseMultipleMilestones(uint256[] calldata milestoneIds) external onlyOwner nonReentrant notClawedBack {
        for (uint256 i = 0; i < milestoneIds.length; i++) {
            uint256 milestoneId = milestoneIds[i];
            if (milestoneId >= milestones.length) revert InvalidMilestone();
            if (block.timestamp > deadline) revert DeadlinePassed();
            
            Milestone storage milestone = milestones[milestoneId];
            if (milestone.status != MilestoneStatus.Pending) {
                revert MilestoneAlreadyProcessed();
            }

            milestone.status = MilestoneStatus.Released;
            milestone.releasedAt = block.timestamp;
            totalReleased += milestone.amount;

            asset.safeTransfer(recipient, milestone.amount);
            
            emit MilestoneReleased(milestoneId, milestone.amount, recipient);
        }
    }

    /**
     * @notice Emergency clawback by owner (before deadline)
     * @dev Returns all unreleased funds to vault
     */
    function emergencyClawback() external onlyOwner nonReentrant notClawedBack {
        uint256 unreleasedAmount = totalAmount - totalReleased;
        if (unreleasedAmount == 0) revert InsufficientBalance();

        // Mark all pending milestones as clawed
        for (uint256 i = 0; i < milestones.length; i++) {
            if (milestones[i].status == MilestoneStatus.Pending) {
                milestones[i].status = MilestoneStatus.Clawed;
            }
        }

        isClawedBack = true;
        asset.safeTransfer(vault, unreleasedAmount);

        emit EmergencyClawback(unreleasedAmount, vault);
    }

    /**
     * @notice Automatic clawback after deadline passes
     * @dev Anyone can call this after deadline
     */
    function autoClawback() external nonReentrant notClawedBack {
        if (block.timestamp <= deadline) revert DeadlineNotPassed();
        
        uint256 unreleasedAmount = totalAmount - totalReleased;
        if (unreleasedAmount == 0) revert InsufficientBalance();

        // Mark all pending milestones as clawed
        for (uint256 i = 0; i < milestones.length; i++) {
            if (milestones[i].status == MilestoneStatus.Pending) {
                milestones[i].status = MilestoneStatus.Clawed;
            }
        }

        isClawedBack = true;
        asset.safeTransfer(vault, unreleasedAmount);

        emit AutoClawback(unreleasedAmount, vault);
    }

    /**
     * @notice Get milestone details
     * @param milestoneId Index of the milestone
     * @return milestone The milestone struct
     */
    function getMilestone(uint256 milestoneId) external view returns (Milestone memory) {
        if (milestoneId >= milestones.length) revert InvalidMilestone();
        return milestones[milestoneId];
    }

    /**
     * @notice Get all milestones
     * @return All milestone structs
     */
    function getAllMilestones() external view returns (Milestone[] memory) {
        return milestones;
    }

    /**
     * @notice Get number of milestones
     * @return Length of milestones array
     */
    function getMilestoneCount() external view returns (uint256) {
        return milestones.length;
    }

    /**
     * @notice Get unreleased amount
     * @return Amount that hasn't been released yet
     */
    function getUnreleasedAmount() external view returns (uint256) {
        if (isClawedBack) return 0;
        return totalAmount - totalReleased;
    }

    /**
     * @notice Check if escrow is expired (past deadline)
     * @return True if deadline has passed
     */
    function isExpired() external view returns (bool) {
        return block.timestamp > deadline;
    }

    /**
     * @notice Get pending milestone count
     * @return Number of milestones still pending release
     */
    function getPendingMilestoneCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < milestones.length; i++) {
            if (milestones[i].status == MilestoneStatus.Pending) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Get released milestone count
     * @return Number of milestones that have been released
     */
    function getReleasedMilestoneCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < milestones.length; i++) {
            if (milestones[i].status == MilestoneStatus.Released) {
                count++;
            }
        }
        return count;
    }
}