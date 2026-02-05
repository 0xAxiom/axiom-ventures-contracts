// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title TokenWarrant
 * @dev Locks agent tokens as collateral at discounted prices for Axiom Ventures
 * @notice Enables fund to exercise warrants for tokens at predetermined discount rates
 */
contract TokenWarrant is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice USDC token contract
    IERC20 public immutable USDC;

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum discount allowed (100% = 10000 basis points)
    uint256 public constant MAX_DISCOUNT_BPS = 10000;

    /// @notice Warrant structure
    struct Warrant {
        uint256 pitchId;           // Linked pitch from PitchRegistry
        address token;             // Agent's ERC-20 token
        uint256 tokenAmount;       // Tokens offered as collateral
        uint256 snapshotPrice;     // Price per token at funding time (6 decimals, USDC precision)
        uint256 discountBps;       // Discount in basis points (5000 = 50%)
        uint256 exerciseDeadline;  // When exercise right expires
        address agent;             // Agent who deposited tokens
        address beneficiary;       // Who can exercise (vault or Safe)
        bool deposited;            // Agent has deposited tokens
        bool exercised;            // Warrant has been exercised
        bool cancelled;            // Warrant was cancelled
    }

    /// @notice Counter for warrant IDs (starts at 1)
    uint256 public nextWarrantId = 1;

    /// @notice Mapping from warrant ID to warrant struct
    mapping(uint256 => Warrant) public warrants;

    /// @notice Mapping from pitch ID to warrant ID
    mapping(uint256 => uint256) public pitchToWarrant;

    /// @notice Array of all warrant IDs for iteration
    uint256[] public allWarrantIds;

    event WarrantCreated(
        uint256 indexed warrantId,
        uint256 indexed pitchId,
        address indexed token,
        uint256 tokenAmount,
        uint256 snapshotPrice,
        uint256 discountBps,
        uint256 exerciseDeadline,
        address agent,
        address beneficiary
    );

    event TokensDeposited(uint256 indexed warrantId, address indexed agent, uint256 tokenAmount);
    event WarrantExercised(uint256 indexed warrantId, address indexed beneficiary, uint256 usdcPaid, uint256 tokensReceived);
    event WarrantCancelled(uint256 indexed warrantId, uint256 tokensReturned);

    error InvalidDiscountBps();
    error InvalidExerciseDeadline();
    error InvalidTokenAmount();
    error InvalidPitchId();
    error WarrantNotFound();
    error NotAuthorized();
    error TokensAlreadyDeposited();
    error TokensNotDeposited();
    error WarrantAlreadyExercised();
    error WarrantAlreadyCancelled();
    error WarrantExpired();
    error WarrantNotExpired();
    error InsufficientUSDCBalance();
    error InsufficientUSDCAllowance();
    error DuplicatePitchId();

    modifier validWarrant(uint256 warrantId) {
        if (warrantId == 0 || warrantId >= nextWarrantId) revert WarrantNotFound();
        _;
    }

    modifier onlyAgent(uint256 warrantId) {
        if (msg.sender != warrants[warrantId].agent) revert NotAuthorized();
        _;
    }

    modifier onlyBeneficiary(uint256 warrantId) {
        if (msg.sender != warrants[warrantId].beneficiary) revert NotAuthorized();
        _;
    }

    /**
     * @notice Initialize the TokenWarrant contract
     * @param initialOwner Initial owner (deployer, will be transferred to Safe)
     * @param usdc USDC token address
     */
    constructor(address initialOwner, IERC20 usdc) Ownable(initialOwner) {
        USDC = usdc;
    }

    /**
     * @notice Create a new token warrant
     * @param pitchId Linked pitch from PitchRegistry
     * @param token Agent's ERC-20 token address
     * @param tokenAmount Number of tokens offered as collateral
     * @param snapshotPrice Price per token at funding time (6 decimals, USDC precision)
     * @param discountBps Discount in basis points (5000 = 50%)
     * @param exerciseDeadline When exercise right expires
     * @param agent Agent who will deposit tokens
     * @param beneficiary Who can exercise (vault or Safe)
     * @return warrantId The ID of the created warrant
     */
    function createWarrant(
        uint256 pitchId,
        address token,
        uint256 tokenAmount,
        uint256 snapshotPrice,
        uint256 discountBps,
        uint256 exerciseDeadline,
        address agent,
        address beneficiary
    ) external onlyOwner returns (uint256 warrantId) {
        if (pitchId == 0) revert InvalidPitchId();
        if (token == address(0) || agent == address(0) || beneficiary == address(0)) revert NotAuthorized();
        if (tokenAmount == 0) revert InvalidTokenAmount();
        if (discountBps > MAX_DISCOUNT_BPS) revert InvalidDiscountBps();
        if (exerciseDeadline <= block.timestamp) revert InvalidExerciseDeadline();
        if (pitchToWarrant[pitchId] != 0) revert DuplicatePitchId();

        warrantId = nextWarrantId++;

        warrants[warrantId] = Warrant({
            pitchId: pitchId,
            token: token,
            tokenAmount: tokenAmount,
            snapshotPrice: snapshotPrice,
            discountBps: discountBps,
            exerciseDeadline: exerciseDeadline,
            agent: agent,
            beneficiary: beneficiary,
            deposited: false,
            exercised: false,
            cancelled: false
        });

        pitchToWarrant[pitchId] = warrantId;
        allWarrantIds.push(warrantId);

        emit WarrantCreated(
            warrantId,
            pitchId,
            token,
            tokenAmount,
            snapshotPrice,
            discountBps,
            exerciseDeadline,
            agent,
            beneficiary
        );
    }

    /**
     * @notice Agent deposits their tokens into the warrant
     * @param warrantId The ID of the warrant to deposit tokens into
     */
    function depositTokens(uint256 warrantId) 
        external 
        nonReentrant 
        validWarrant(warrantId) 
        onlyAgent(warrantId) 
    {
        Warrant storage warrant = warrants[warrantId];
        
        if (warrant.deposited) revert TokensAlreadyDeposited();
        if (warrant.cancelled) revert WarrantAlreadyCancelled();

        warrant.deposited = true;

        IERC20(warrant.token).safeTransferFrom(msg.sender, address(this), warrant.tokenAmount);

        emit TokensDeposited(warrantId, msg.sender, warrant.tokenAmount);
    }

    /**
     * @notice Beneficiary exercises the warrant by paying discounted USDC
     * @param warrantId The ID of the warrant to exercise
     */
    function exerciseWarrant(uint256 warrantId) 
        external 
        nonReentrant 
        validWarrant(warrantId) 
        onlyBeneficiary(warrantId) 
    {
        Warrant storage warrant = warrants[warrantId];
        
        if (!warrant.deposited) revert TokensNotDeposited();
        if (warrant.exercised) revert WarrantAlreadyExercised();
        if (warrant.cancelled) revert WarrantAlreadyCancelled();
        if (block.timestamp > warrant.exerciseDeadline) revert WarrantExpired();

        uint256 exerciseCost = getExerciseCost(warrantId);
        
        if (USDC.balanceOf(msg.sender) < exerciseCost) revert InsufficientUSDCBalance();
        if (USDC.allowance(msg.sender, address(this)) < exerciseCost) revert InsufficientUSDCAllowance();

        warrant.exercised = true;

        USDC.safeTransferFrom(msg.sender, address(this), exerciseCost);
        IERC20(warrant.token).safeTransfer(msg.sender, warrant.tokenAmount);

        emit WarrantExercised(warrantId, msg.sender, exerciseCost, warrant.tokenAmount);
    }

    /**
     * @notice Owner cancels a warrant, returning tokens to agent if deposited
     * @param warrantId The ID of the warrant to cancel
     */
    function cancelWarrant(uint256 warrantId) 
        external 
        onlyOwner 
        nonReentrant 
        validWarrant(warrantId) 
    {
        Warrant storage warrant = warrants[warrantId];
        
        if (warrant.exercised) revert WarrantAlreadyExercised();

        uint256 tokensReturned = 0;
        if (warrant.deposited) {
            tokensReturned = warrant.tokenAmount;
            IERC20(warrant.token).safeTransfer(warrant.agent, warrant.tokenAmount);
        }

        warrant.cancelled = true;

        emit WarrantCancelled(warrantId, tokensReturned);
    }

    /**
     * @notice Get warrant details
     * @param warrantId The ID of the warrant
     * @return warrant The warrant struct
     */
    function getWarrant(uint256 warrantId) external view validWarrant(warrantId) returns (Warrant memory) {
        return warrants[warrantId];
    }

    /**
     * @notice Get warrant ID by pitch ID
     * @param pitchId The pitch ID
     * @return warrantId The associated warrant ID (0 if not found)
     */
    function getWarrantByPitch(uint256 pitchId) external view returns (uint256) {
        return pitchToWarrant[pitchId];
    }

    /**
     * @notice Calculate the USDC cost to exercise a warrant
     * @param warrantId The ID of the warrant
     * @return exerciseCost The amount of USDC required to exercise
     */
    function getExerciseCost(uint256 warrantId) public view validWarrant(warrantId) returns (uint256 exerciseCost) {
        Warrant storage warrant = warrants[warrantId];
        
        // Get token decimals to handle different token decimal places
        uint256 tokenDecimals = IERC20Metadata(warrant.token).decimals();
        
        // Calculate: (tokenAmount * snapshotPrice * (10000 - discountBps)) / (10000 * 10^tokenDecimals)
        // This gives us the result in USDC decimals (6)
        uint256 totalValue = warrant.tokenAmount.mulDiv(warrant.snapshotPrice, 10**tokenDecimals);
        exerciseCost = totalValue.mulDiv(BPS_DENOMINATOR - warrant.discountBps, BPS_DENOMINATOR);
    }

    /**
     * @notice Get all warrant IDs
     * @return All warrant IDs
     */
    function getAllWarrants() external view returns (uint256[] memory) {
        return allWarrantIds;
    }

    /**
     * @notice Get active warrant IDs (deposited, not exercised, not cancelled)
     * @return activeWarrants Array of active warrant IDs
     */
    function getActiveWarrants() external view returns (uint256[] memory activeWarrants) {
        uint256 activeCount = 0;
        
        // Count active warrants
        for (uint256 i = 0; i < allWarrantIds.length; i++) {
            uint256 warrantId = allWarrantIds[i];
            Warrant storage warrant = warrants[warrantId];
            if (warrant.deposited && !warrant.exercised && !warrant.cancelled) {
                activeCount++;
            }
        }
        
        // Create array and populate
        activeWarrants = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allWarrantIds.length; i++) {
            uint256 warrantId = allWarrantIds[i];
            Warrant storage warrant = warrants[warrantId];
            if (warrant.deposited && !warrant.exercised && !warrant.cancelled) {
                activeWarrants[index] = warrantId;
                index++;
            }
        }
    }

    /**
     * @notice Get warrants with pagination
     * @param start Starting index
     * @param count Number of warrants to return
     * @return warrantIds Array of warrant IDs
     */
    function getWarrantsPaginated(uint256 start, uint256 count) 
        external 
        view 
        returns (uint256[] memory warrantIds) 
    {
        if (start >= allWarrantIds.length) {
            return new uint256[](0);
        }
        
        uint256 end = start + count;
        if (end > allWarrantIds.length) {
            end = allWarrantIds.length;
        }
        
        warrantIds = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            warrantIds[i - start] = allWarrantIds[i];
        }
    }

    /**
     * @notice Get total number of warrants
     * @return Total warrant count
     */
    function getWarrantCount() external view returns (uint256) {
        return allWarrantIds.length;
    }

    /**
     * @notice Owner can withdraw accumulated USDC from exercised warrants
     * @param to Address to send USDC to
     * @param amount Amount of USDC to withdraw
     */
    function withdrawUSDC(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert NotAuthorized();
        USDC.safeTransfer(to, amount);
    }

    /**
     * @notice Get contract's USDC balance
     * @return USDC balance
     */
    function getUSDCBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
}