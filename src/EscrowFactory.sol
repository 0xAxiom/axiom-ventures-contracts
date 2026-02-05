// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {MilestoneEscrow} from "./MilestoneEscrow.sol";

/**
 * @title EscrowFactory
 * @dev Factory contract for creating MilestoneEscrow instances
 * @notice Manages deployment and tracking of escrow contracts for investments
 */
contract EscrowFactory is Ownable, ReentrancyGuard {
    /// @notice USDC token contract
    IERC20 public immutable asset;
    
    /// @notice Vault contract that owns this factory
    address public immutable vault;
    
    /// @notice Array of all created escrows
    address[] public escrows;
    
    /// @notice Mapping of escrow address to whether it was created by this factory
    mapping(address => bool) public isValidEscrow;
    
    /// @notice Mapping of recipient to their escrows
    mapping(address => address[]) public recipientEscrows;

    event EscrowCreated(
        address indexed escrow,
        address indexed recipient,
        uint256 totalAmount,
        uint256 deadline,
        uint256 milestoneCount
    );

    error OnlyVault();
    error InvalidRecipient();
    error InvalidDeadline();
    error InvalidMilestones();
    error EscrowCreationFailed();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /**
     * @notice Initialize the escrow factory
     * @param asset_ USDC token address
     * @param vault_ Vault contract address
     */
    constructor(IERC20 asset_, address vault_) Ownable(vault_) {
        asset = asset_;
        vault = vault_;
    }

    /**
     * @notice Create a new milestone escrow
     * @param recipient Address to receive released funds
     * @param deadline Deadline for automatic clawback
     * @param amounts Array of milestone amounts
     * @param descriptions Array of milestone descriptions
     * @return escrow Address of the created escrow contract
     */
    function createEscrow(
        address recipient,
        uint256 deadline,
        uint256[] memory amounts,
        string[] memory descriptions
    ) external onlyVault nonReentrant returns (address escrow) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (deadline <= block.timestamp) revert InvalidDeadline();
        if (amounts.length == 0 || amounts.length != descriptions.length) {
            revert InvalidMilestones();
        }

        // Calculate total amount
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) revert InvalidMilestones();
            totalAmount += amounts[i];
        }

        // Deploy new escrow contract
        try new MilestoneEscrow{
            salt: keccak256(abi.encodePacked(recipient, deadline, block.timestamp))
        }(
            asset,
            vault,
            recipient,
            deadline,
            amounts,
            descriptions
        ) returns (MilestoneEscrow newEscrow) {
            escrow = address(newEscrow);
        } catch {
            revert EscrowCreationFailed();
        }

        // Track the escrow
        escrows.push(escrow);
        isValidEscrow[escrow] = true;
        recipientEscrows[recipient].push(escrow);

        emit EscrowCreated(escrow, recipient, totalAmount, deadline, amounts.length);
    }

    /**
     * @notice Get all escrows created by this factory
     * @return Array of escrow addresses
     */
    function getAllEscrows() external view returns (address[] memory) {
        return escrows;
    }

    /**
     * @notice Get escrows for a specific recipient
     * @param recipient Address to query escrows for
     * @return Array of escrow addresses for the recipient
     */
    function getRecipientEscrows(address recipient) external view returns (address[] memory) {
        return recipientEscrows[recipient];
    }

    /**
     * @notice Get total number of escrows created
     * @return Number of escrows
     */
    function getEscrowCount() external view returns (uint256) {
        return escrows.length;
    }

    /**
     * @notice Get escrow at specific index
     * @param index Index in the escrows array
     * @return Escrow address
     */
    function getEscrowAtIndex(uint256 index) external view returns (address) {
        require(index < escrows.length, "Index out of bounds");
        return escrows[index];
    }

    /**
     * @notice Get active escrows (not clawed back and not expired)
     * @return activeEscrows Array of active escrow addresses
     */
    function getActiveEscrows() external view returns (address[] memory activeEscrows) {
        uint256 activeCount = 0;
        
        // First pass: count active escrows
        for (uint256 i = 0; i < escrows.length; i++) {
            MilestoneEscrow escrow = MilestoneEscrow(escrows[i]);
            if (!escrow.isClawedBack() && !escrow.isExpired()) {
                activeCount++;
            }
        }

        // Second pass: populate active escrows array
        activeEscrows = new address[](activeCount);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < escrows.length; i++) {
            MilestoneEscrow escrow = MilestoneEscrow(escrows[i]);
            if (!escrow.isClawedBack() && !escrow.isExpired()) {
                activeEscrows[currentIndex] = escrows[i];
                currentIndex++;
            }
        }
    }

    /**
     * @notice Get expired escrows that can be clawed back
     * @return expiredEscrows Array of expired escrow addresses
     */
    function getExpiredEscrows() external view returns (address[] memory expiredEscrows) {
        uint256 expiredCount = 0;
        
        // First pass: count expired escrows
        for (uint256 i = 0; i < escrows.length; i++) {
            MilestoneEscrow escrow = MilestoneEscrow(escrows[i]);
            if (!escrow.isClawedBack() && escrow.isExpired()) {
                expiredCount++;
            }
        }

        // Second pass: populate expired escrows array
        expiredEscrows = new address[](expiredCount);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < escrows.length; i++) {
            MilestoneEscrow escrow = MilestoneEscrow(escrows[i]);
            if (!escrow.isClawedBack() && escrow.isExpired()) {
                expiredEscrows[currentIndex] = escrows[i];
                currentIndex++;
            }
        }
    }

    /**
     * @notice Get total unreleased funds across all escrows
     * @return totalUnreleased Total amount in pending escrows
     */
    function getTotalUnreleasedFunds() external view returns (uint256 totalUnreleased) {
        for (uint256 i = 0; i < escrows.length; i++) {
            MilestoneEscrow escrow = MilestoneEscrow(escrows[i]);
            totalUnreleased += escrow.getUnreleasedAmount();
        }
    }

    /**
     * @notice Auto-clawback all expired escrows
     * @dev Anyone can call this to help with fund recovery
     * @return clawedBack Number of escrows clawed back
     */
    function autoClawbackExpiredEscrows() external nonReentrant returns (uint256 clawedBack) {
        for (uint256 i = 0; i < escrows.length; i++) {
            MilestoneEscrow escrow = MilestoneEscrow(escrows[i]);
            if (!escrow.isClawedBack() && escrow.isExpired() && escrow.getUnreleasedAmount() > 0) {
                try escrow.autoClawback() {
                    clawedBack++;
                } catch {
                    // Skip failed clawbacks and continue with others
                    continue;
                }
            }
        }
    }
}