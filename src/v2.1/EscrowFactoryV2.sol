// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {MilestoneEscrow} from "../MilestoneEscrow.sol";

/**
 * @title EscrowFactoryV2
 * @dev Enhanced factory contract for creating MilestoneEscrow instances
 * @notice V2.1 - Creates escrows owned by Safe multisig instead of vault
 * @author Axiom Ventures
 */
contract EscrowFactoryV2 is Ownable, ReentrancyGuard {
    /// @notice USDC token contract
    IERC20 public immutable asset;
    
    /// @notice Safe multisig that owns created escrows
    address public immutable escrowOwner;
    
    /// @notice Authorized router contract that can create escrows
    address public authorizedRouter;
    
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

    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    error OnlyAuthorized();
    error InvalidRecipient();
    error InvalidDeadline();
    error InvalidMilestones();
    error EscrowCreationFailed();
    error InvalidRouter();

    modifier onlyAuthorized() {
        if (msg.sender != owner() && msg.sender != authorizedRouter) {
            revert OnlyAuthorized();
        }
        _;
    }

    /**
     * @notice Initialize the escrow factory V2
     * @param asset_ USDC token address
     * @param escrowOwner_ Safe multisig address that will own created escrows
     * @param initialOwner_ Initial owner of this factory (deployer initially)
     */
    constructor(
        IERC20 asset_, 
        address escrowOwner_, 
        address initialOwner_
    ) Ownable(initialOwner_) {
        asset = asset_;
        escrowOwner = escrowOwner_;
    }

    /**
     * @notice Set the authorized router contract
     * @param router_ Address of the InvestmentRouterV2 contract
     * @dev Only owner can update the authorized router
     */
    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert InvalidRouter();
        
        address oldRouter = authorizedRouter;
        authorizedRouter = router_;
        
        emit RouterUpdated(oldRouter, router_);
    }

    /**
     * @notice Create a new milestone escrow
     * @param recipient Address to receive released funds
     * @param deadline Deadline for automatic clawback
     * @param amounts Array of milestone amounts
     * @param descriptions Array of milestone descriptions
     * @return escrow Address of the created escrow contract
     * @dev Can be called by owner or authorized router
     */
    function createEscrow(
        address recipient,
        uint256 deadline,
        uint256[] memory amounts,
        string[] memory descriptions
    ) external onlyAuthorized nonReentrant returns (address escrow) {
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

        // Deploy new escrow contract - use escrowOwner (Safe) as the vault parameter
        // This makes the Safe the owner of the escrow, allowing it to call releaseMilestone/emergencyClawback
        try new MilestoneEscrow{
            salt: keccak256(abi.encodePacked(recipient, deadline, block.timestamp))
        }(
            asset,
            escrowOwner,  // Safe address becomes the "vault" parameter and owner
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
     * @notice Get escrows with pagination
     * @param start Starting index
     * @param count Maximum number of escrows to return
     * @return paginatedEscrows Array of escrow addresses in range
     */
    function getEscrowsPaginated(uint256 start, uint256 count) 
        external 
        view 
        returns (address[] memory paginatedEscrows) 
    {
        if (start >= escrows.length) {
            return new address[](0);
        }

        uint256 end = start + count;
        if (end > escrows.length) {
            end = escrows.length;
        }

        paginatedEscrows = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            paginatedEscrows[i - start] = escrows[i];
        }
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
     * @notice Auto-clawback expired escrows with batch limiting
     * @param maxCount Maximum number of escrows to process in this call
     * @dev Prevents unbounded gas consumption, can be called multiple times
     * @return clawedBack Number of escrows clawed back
     */
    function autoClawbackBatch(uint256 maxCount) external nonReentrant returns (uint256 clawedBack) {
        uint256 processed = 0;
        
        for (uint256 i = 0; i < escrows.length && processed < maxCount; i++) {
            MilestoneEscrow escrow = MilestoneEscrow(escrows[i]);
            processed++;
            
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