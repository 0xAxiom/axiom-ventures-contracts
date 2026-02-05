// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PitchRegistry
 * @dev On-chain registry for startup pitch submissions with status tracking
 * @notice Allows startups to submit pitches with IPFS metadata and fee payment
 */
contract PitchRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Pitch status enum
    enum PitchStatus {
        Submitted,
        UnderReview,
        Approved,
        Funded,
        Rejected
    }

    /// @notice Pitch structure
    struct Pitch {
        address submitter;
        string ipfsHash;
        string title;
        string description;
        uint256 fundingRequest;
        PitchStatus status;
        uint256 submittedAt;
        uint256 lastUpdated;
        address reviewer;
        string reviewNotes;
    }

    /// @notice USDC token contract
    IERC20 public immutable asset;
    
    /// @notice Fee required to submit a pitch (in USDC)
    uint256 public submitFee;
    
    /// @notice Next pitch ID
    uint256 public nextPitchId;
    
    /// @notice Mapping of pitch ID to pitch data
    mapping(uint256 => Pitch) public pitches;
    
    /// @notice Mapping of submitter to their pitch IDs
    mapping(address => uint256[]) public submitterPitches;
    
    /// @notice Array of all pitch IDs
    uint256[] public allPitches;

    event PitchSubmitted(
        uint256 indexed pitchId,
        address indexed submitter,
        string title,
        uint256 fundingRequest,
        uint256 fee
    );
    
    event PitchStatusUpdated(
        uint256 indexed pitchId,
        PitchStatus oldStatus,
        PitchStatus newStatus,
        address reviewer,
        string notes
    );
    
    event SubmitFeeUpdated(uint256 oldFee, uint256 newFee);
    
    event FeesWithdrawn(uint256 amount, address recipient);

    error InvalidFundingRequest();
    error InvalidIPFS();
    error PitchNotFound();
    error InsufficientFee();
    error InvalidStatus();
    error EmptyTitle();
    error StatusUpdateNotAllowed();

    /**
     * @notice Initialize the pitch registry
     * @param asset_ USDC token address
     * @param submitFee_ Initial submission fee in USDC
     * @param initialOwner Initial owner (deployer, will be transferred to Safe)
     */
    constructor(
        IERC20 asset_,
        uint256 submitFee_,
        address initialOwner
    ) Ownable(initialOwner) {
        asset = asset_;
        submitFee = submitFee_;
        nextPitchId = 1; // Start from 1 for easier tracking
    }

    /**
     * @notice Submit a new pitch
     * @param ipfsHash IPFS hash containing detailed pitch data
     * @param title Brief title of the pitch
     * @param description Short description
     * @param fundingRequest Amount of funding requested (in USDC)
     * @return pitchId The ID of the submitted pitch
     */
    function submitPitch(
        string memory ipfsHash,
        string memory title,
        string memory description,
        uint256 fundingRequest
    ) external nonReentrant returns (uint256 pitchId) {
        if (bytes(title).length == 0) revert EmptyTitle();
        if (bytes(ipfsHash).length == 0) revert InvalidIPFS();
        if (fundingRequest == 0) revert InvalidFundingRequest();

        // Collect submission fee
        if (submitFee > 0) {
            asset.safeTransferFrom(msg.sender, address(this), submitFee);
        }

        pitchId = nextPitchId++;

        pitches[pitchId] = Pitch({
            submitter: msg.sender,
            ipfsHash: ipfsHash,
            title: title,
            description: description,
            fundingRequest: fundingRequest,
            status: PitchStatus.Submitted,
            submittedAt: block.timestamp,
            lastUpdated: block.timestamp,
            reviewer: address(0),
            reviewNotes: ""
        });

        submitterPitches[msg.sender].push(pitchId);
        allPitches.push(pitchId);

        emit PitchSubmitted(pitchId, msg.sender, title, fundingRequest, submitFee);
    }

    /**
     * @notice Update pitch status (owner only)
     * @param pitchId ID of the pitch to update
     * @param newStatus New status for the pitch
     * @param notes Review notes
     */
    function updatePitchStatus(
        uint256 pitchId,
        PitchStatus newStatus,
        string memory notes
    ) external onlyOwner {
        if (pitchId >= nextPitchId || pitchId == 0) revert PitchNotFound();

        Pitch storage pitch = pitches[pitchId];
        PitchStatus oldStatus = pitch.status;

        // Validate status transitions
        if (!_isValidStatusTransition(oldStatus, newStatus)) {
            revert StatusUpdateNotAllowed();
        }

        pitch.status = newStatus;
        pitch.lastUpdated = block.timestamp;
        pitch.reviewer = msg.sender;
        pitch.reviewNotes = notes;

        emit PitchStatusUpdated(pitchId, oldStatus, newStatus, msg.sender, notes);
    }

    /**
     * @notice Update submission fee (owner only)
     * @param newFee New submission fee in USDC
     */
    function updateSubmitFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = submitFee;
        submitFee = newFee;
        emit SubmitFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Withdraw collected fees (owner only)
     * @param recipient Address to receive the fees
     */
    function withdrawFees(address recipient) external onlyOwner {
        uint256 balance = asset.balanceOf(address(this));
        if (balance > 0) {
            asset.safeTransfer(recipient, balance);
            emit FeesWithdrawn(balance, recipient);
        }
    }

    /**
     * @notice Get pitch details
     * @param pitchId ID of the pitch
     * @return pitch The pitch struct
     */
    function getPitch(uint256 pitchId) external view returns (Pitch memory) {
        if (pitchId >= nextPitchId || pitchId == 0) revert PitchNotFound();
        return pitches[pitchId];
    }

    /**
     * @notice Get pitches by submitter
     * @param submitter Address of the submitter
     * @return pitchIds Array of pitch IDs submitted by the address
     */
    function getPitchesBySubmitter(address submitter) external view returns (uint256[] memory) {
        return submitterPitches[submitter];
    }

    /**
     * @notice Get pitches by status
     * @param status Status to filter by
     * @return pitchIds Array of pitch IDs with the specified status
     */
    function getPitchesByStatus(PitchStatus status) external view returns (uint256[] memory pitchIds) {
        uint256 count = 0;
        
        // Count pitches with the status
        for (uint256 i = 0; i < allPitches.length; i++) {
            if (pitches[allPitches[i]].status == status) {
                count++;
            }
        }

        // Populate result array
        pitchIds = new uint256[](count);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < allPitches.length; i++) {
            if (pitches[allPitches[i]].status == status) {
                pitchIds[currentIndex] = allPitches[i];
                currentIndex++;
            }
        }
    }

    /**
     * @notice Get total number of pitches
     * @return Total pitch count
     */
    function getTotalPitchCount() external view returns (uint256) {
        return allPitches.length;
    }

    /**
     * @notice Get all pitch IDs
     * @return Array of all pitch IDs
     */
    function getAllPitchIds() external view returns (uint256[] memory) {
        return allPitches;
    }

    /**
     * @notice Get pitch IDs in a range
     * @param start Start index (inclusive)
     * @param end End index (exclusive)
     * @return pitchIds Array of pitch IDs in the specified range
     */
    function getPitchRange(uint256 start, uint256 end) external view returns (uint256[] memory pitchIds) {
        require(start < end && end <= allPitches.length, "Invalid range");
        
        pitchIds = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            pitchIds[i - start] = allPitches[i];
        }
    }

    /**
     * @notice Get total funding requested for pitches with specific status
     * @param status Status to filter by
     * @return totalRequested Total funding amount requested
     */
    function getTotalFundingRequested(PitchStatus status) external view returns (uint256 totalRequested) {
        for (uint256 i = 0; i < allPitches.length; i++) {
            Pitch storage pitch = pitches[allPitches[i]];
            if (pitch.status == status) {
                totalRequested += pitch.fundingRequest;
            }
        }
    }

    /**
     * @notice Get total funding requested across all pitches regardless of status
     * @return totalRequested Total funding amount requested across all pitches
     */
    function getTotalFundingRequestedAll() external view returns (uint256 totalRequested) {
        for (uint256 i = 0; i < allPitches.length; i++) {
            totalRequested += pitches[allPitches[i]].fundingRequest;
        }
    }

    /**
     * @notice Check if pitch exists
     * @param pitchId ID to check
     * @return exists True if pitch exists
     */
    function pitchExists(uint256 pitchId) external view returns (bool) {
        return pitchId > 0 && pitchId < nextPitchId;
    }

    /**
     * @notice Get collected fees balance
     * @return balance Current USDC balance of fees
     */
    function getFeesBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Internal function to validate status transitions
     * @param currentStatus Current pitch status
     * @param newStatus Proposed new status
     * @return valid True if transition is allowed
     */
    function _isValidStatusTransition(PitchStatus currentStatus, PitchStatus newStatus) 
        internal 
        pure 
        returns (bool) 
    {
        // Can't transition to the same status
        if (currentStatus == newStatus) return false;

        // Submitted can go to UnderReview or Rejected
        if (currentStatus == PitchStatus.Submitted) {
            return newStatus == PitchStatus.UnderReview || newStatus == PitchStatus.Rejected;
        }

        // UnderReview can go to Approved or Rejected
        if (currentStatus == PitchStatus.UnderReview) {
            return newStatus == PitchStatus.Approved || newStatus == PitchStatus.Rejected;
        }

        // Approved can only go to Funded
        if (currentStatus == PitchStatus.Approved) {
            return newStatus == PitchStatus.Funded;
        }

        // Funded and Rejected are terminal states
        return false;
    }
}