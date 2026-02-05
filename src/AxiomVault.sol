// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title AxiomVault
 * @dev ERC-4626 tokenized vault for Axiom Ventures fund with management and performance fees
 * @notice Manages USDC deposits with 2% annual management fee and 20% performance fee
 */
contract AxiomVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using Math for uint256;

    /// @notice Management fee rate (2% per year = 200 basis points)
    uint256 public constant MANAGEMENT_FEE_BPS = 200;
    
    /// @notice Performance fee rate (20% = 2000 basis points)
    uint256 public constant PERFORMANCE_FEE_BPS = 2000;
    
    /// @notice Liquidity reserve requirement (20% = 2000 basis points)
    uint256 public constant LIQUIDITY_RESERVE_BPS = 2000;
    
    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    /// @notice Seconds per year for fee calculations
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    /// @notice High water mark for performance fee calculation
    uint256 public highWaterMark;
    
    /// @notice Last timestamp when management fees were collected
    uint256 public lastFeeCollection;
    
    /// @notice Accumulated management fees to be collected
    uint256 public pendingManagementFees;

    event ManagementFeeCollected(uint256 amount, uint256 timestamp);
    event PerformanceFeeCollected(uint256 amount, uint256 newHighWaterMark);
    event HighWaterMarkUpdated(uint256 oldMark, uint256 newMark);

    error InsufficientLiquidity();
    error InvalidAmount();

    /**
     * @notice Initialize the Axiom Vault
     * @param asset_ USDC token address on Base
     * @param initialOwner Initial owner (deployer, will be transferred to Safe)
     */
    constructor(
        IERC20 asset_,
        address initialOwner
    ) 
        ERC4626(asset_) 
        ERC20("Axiom Ventures Fund I", "avFUND1") 
        Ownable(initialOwner) 
    {
        lastFeeCollection = block.timestamp;
        highWaterMark = 1e18; // Start at 1 token per share
    }

    /**
     * @notice Pause vault operations (emergency only)
     * @dev Only owner can pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause vault operations
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Deposit assets and receive shares
     * @param assets Amount of USDC to deposit
     * @param receiver Address to receive shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) 
        public 
        override 
        nonReentrant 
        whenNotPaused 
        returns (uint256 shares) 
    {
        if (assets == 0) revert InvalidAmount();
        _collectManagementFees();
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mint shares by depositing assets
     * @param shares Amount of shares to mint
     * @param receiver Address to receive shares
     * @return assets Amount of assets required
     */
    function mint(uint256 shares, address receiver) 
        public 
        override 
        nonReentrant 
        whenNotPaused 
        returns (uint256 assets) 
    {
        if (shares == 0) revert InvalidAmount();
        _collectManagementFees();
        return super.mint(shares, receiver);
    }

    /**
     * @notice Withdraw assets by burning shares
     * @param assets Amount of USDC to withdraw
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner) 
        public 
        override 
        nonReentrant 
        whenNotPaused 
        returns (uint256 shares) 
    {
        if (assets == 0) revert InvalidAmount();
        _collectManagementFees();
        _checkLiquidityReserve(assets);
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Redeem shares for assets
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return assets Amount of assets withdrawn
     */
    function redeem(uint256 shares, address receiver, address owner) 
        public 
        override 
        nonReentrant 
        whenNotPaused 
        returns (uint256 assets) 
    {
        if (shares == 0) revert InvalidAmount();
        _collectManagementFees();
        uint256 assetsToWithdraw = previewRedeem(shares);
        _checkLiquidityReserve(assetsToWithdraw);
        return super.redeem(shares, receiver, owner);
    }

    /**
     * @notice Collect performance fees when vault outperforms high water mark
     * @dev Only owner can trigger performance fee collection
     */
    function collectPerformanceFees() external onlyOwner {
        _collectManagementFees();
        
        uint256 currentSharePrice = totalAssets() == 0 ? 1e18 : convertToAssets(1e18);
        
        if (currentSharePrice > highWaterMark) {
            uint256 totalShares = totalSupply();
            if (totalShares > 0) {
                uint256 performanceGain = currentSharePrice - highWaterMark;
                uint256 gainRatio = performanceGain.mulDiv(1e18, currentSharePrice);
                uint256 feeShares = totalShares.mulDiv(gainRatio, 1e18).mulDiv(PERFORMANCE_FEE_BPS, BPS_DENOMINATOR);
                
                if (feeShares > 0) {
                    _mint(owner(), feeShares);
                    emit PerformanceFeeCollected(feeShares, currentSharePrice);
                }
            }
            
            uint256 oldHighWaterMark = highWaterMark;
            highWaterMark = currentSharePrice;
            emit HighWaterMarkUpdated(oldHighWaterMark, currentSharePrice);
        }
    }

    /**
     * @notice Manually collect accumulated management fees
     * @dev Anyone can call this to ensure fees are up to date
     */
    function collectManagementFees() external {
        _collectManagementFees();
    }

    /**
     * @notice Get current liquidity available for withdrawals
     * @return liquidity Amount of USDC available for withdrawal
     */
    function availableLiquidity() public view returns (uint256 liquidity) {
        uint256 totalAssets_ = totalAssets();
        uint256 reserveRequired = totalAssets_.mulDiv(LIQUIDITY_RESERVE_BPS, BPS_DENOMINATOR);
        return totalAssets_ > reserveRequired ? totalAssets_ - reserveRequired : 0;
    }

    /**
     * @notice Calculate pending management fees
     * @return fees Amount of management fees that can be collected
     */
    function pendingManagementFeesAmount() public view returns (uint256 fees) {
        if (totalAssets() == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - lastFeeCollection;
        uint256 annualFeeRate = totalAssets().mulDiv(MANAGEMENT_FEE_BPS, BPS_DENOMINATOR);
        return annualFeeRate.mulDiv(timeElapsed, SECONDS_PER_YEAR);
    }

    /**
     * @notice Internal function to collect management fees
     */
    function _collectManagementFees() internal {
        uint256 fees = pendingManagementFeesAmount();
        if (fees > 0) {
            uint256 sharesForFees = convertToShares(fees);
            if (sharesForFees > 0) {
                _mint(owner(), sharesForFees);
                emit ManagementFeeCollected(fees, block.timestamp);
            }
        }
        lastFeeCollection = block.timestamp;
    }

    /**
     * @notice Check if withdrawal would breach liquidity reserve requirement
     * @param assets Amount of assets to withdraw
     */
    function _checkLiquidityReserve(uint256 assets) internal view {
        if (assets > availableLiquidity()) {
            revert InsufficientLiquidity();
        }
    }

    /**
     * @notice Override maxWithdraw to respect liquidity reserve
     * @param owner Address that owns the shares
     * @return Maximum withdrawable assets
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 maxAssets = super.maxWithdraw(owner);
        uint256 available = availableLiquidity();
        return maxAssets > available ? available : maxAssets;
    }

    /**
     * @notice Override maxRedeem to respect liquidity reserve
     * @param owner Address that owns the shares
     * @return Maximum redeemable shares
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 maxShares = super.maxRedeem(owner);
        uint256 available = availableLiquidity();
        uint256 sharesForAvailable = convertToShares(available);
        return maxShares > sharesForAvailable ? sharesForAvailable : maxShares;
    }
}