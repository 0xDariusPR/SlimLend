// SPDX-License-Identifier: BSL-3.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/**
 * @title SlimLend
 * @notice Simplified educational lending protocol implementing interest accrual, LP shares, and collateralized borrowing.
 * @dev Demonstrates lending, borrowing, repayment, and liquidation mechanisms using ERC20 tokens and Chainlink-style price feeds.
 */
contract SlimLend is ERC20("LPSlimShares", "LPS") {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         STATE
    // =============================================================

    uint256 public totalDepositedTokens;
    uint256 public totalBorrowedTokens;

    uint256 public lpSharePrice = 1e18;
    uint256 public borrowerSharePrice = 1e18;
    uint256 public lastUpdateTime = block.timestamp;

    IERC20 public immutable assetToken;
    IERC20 public immutable collateralToken;
    IPriceFeed public immutable priceFeed;

    // Interest model constants
    uint256 public constant MIN_COLLATERALIZATION_RATIO = 1.5e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 1.1e18;
    uint256 public constant OPTIMAL_UTILIZATION = 0.95e18;
    uint256 public constant KINK_INTEREST_PER_SECOND = 1_585_489_599;   // see test for derivation
    uint256 public constant MAX_INTEREST_PER_SECOND = 15_854_895_991;   // see test for derivation

    // =============================================================
    //                         ERRORS
    // =============================================================

    error Slippage();
    error InsufficientLiquidity();
    error MinCollateralization();
    error HealthyAccount();
    error InsufficientCollateral();

    // =============================================================
    //                         EVENTS
    // =============================================================

    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPRedeem(address indexed user, uint256 shares, uint256 amount);
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 amount);

    // =============================================================
    //                         STRUCTS
    // =============================================================

    struct BorrowerInfo {
        uint256 borrowerShares;
        uint256 collateralTokenAmount;
    }

    mapping(address => BorrowerInfo) public borrowerInfo;

    // =============================================================
    //                       CONSTRUCTOR
    // =============================================================

    constructor(IERC20 _assetToken, IERC20 _collateralToken, IPriceFeed _priceFeed) {
        assetToken = _assetToken;
        collateralToken = _collateralToken;
        priceFeed = _priceFeed;
    }

    // =============================================================
    //                        VIEW LOGIC
    // =============================================================

    /**
     * @notice Returns the current utilization ratio (borrowed / deposited).
     */
    function utilization() public view returns (uint256) {
        return totalDepositedTokens == 0 ? 0 : (totalBorrowedTokens * 1e18) / totalDepositedTokens;
    }

    /**
     * @notice Calculates borrower and lender interest rates based on utilization.
     * @param _utilization Pool utilization ratio (1e18 precision).
     * @return borrowerRate The rate paid by borrowers (per second).
     * @return lenderRate The rate earned by LPs (per second).
     */
    function interestRate(uint256 _utilization)
        public
        pure
        returns (uint256 borrowerRate, uint256 lenderRate)
    {
        if (_utilization == 0) return (0, 0);

        if (_utilization < OPTIMAL_UTILIZATION) {
            borrowerRate = (KINK_INTEREST_PER_SECOND * _utilization) / OPTIMAL_UTILIZATION;
        } else {
            uint256 excess = _utilization - OPTIMAL_UTILIZATION;
            uint256 slope = (MAX_INTEREST_PER_SECOND - KINK_INTEREST_PER_SECOND) * 1e18
                / (1e18 - OPTIMAL_UTILIZATION);
            borrowerRate = KINK_INTEREST_PER_SECOND + (slope * excess) / 1e18;
        }

        lenderRate = (borrowerRate * _utilization) / 1e18;
    }

    /**
     * @notice Returns the collateral value of a borrower denominated in assetToken.
     */
    function collateralValue(address borrower) public view returns (uint256) {
        uint256 amount = borrowerInfo[borrower].collateralTokenAmount;
        if (amount == 0) return 0;

        (, int256 price,,,) = priceFeed.latestRoundData();
        return (amount * uint256(price)) / 1e8;
    }

    /**
     * @notice Returns the borrower's collateralization ratio (collateral / debt).
     * @dev Returns `type(uint256).max` for healthy or zero-debt borrowers.
     */
    function collateralizationRatio(address borrower) public view returns (uint256) {
        uint256 shares = borrowerInfo[borrower].borrowerShares;
        if (shares == 0) return type(uint256).max;

        uint256 cValue = collateralValue(borrower);
        if (cValue == 0 && shares == 0) return type(uint256).max;

        uint256 debtValue = (shares * borrowerSharePrice) / 1e18;
        return (cValue * 1e18) / debtValue;
    }

    /**
     * @notice Returns true if a borrower can be liquidated.
     */
    function canLiquidate(address borrower) public view returns (bool) {
        return collateralizationRatio(borrower) < LIQUIDATION_THRESHOLD;
    }

    // =============================================================
    //                      INTERNAL LOGIC
    // =============================================================

    /**
     * @dev Updates LP and borrower share prices based on elapsed time and interest accrual.
     */
    function _updateSharePrices() internal {
        uint256 delta = block.timestamp - lastUpdateTime;
        (uint256 borrowerRate, uint256 lenderRate) = interestRate(utilization());

        uint256 borrowerAccrual = delta * borrowerRate;
        uint256 lenderAccrual = delta * lenderRate;

        lpSharePrice = (lpSharePrice * (1e18 + lenderAccrual)) / 1e18;
        borrowerSharePrice = (borrowerSharePrice * (1e18 + borrowerAccrual)) / 1e18;

        lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Safe subtraction that floors at zero.
     */
    function _subFloorZero(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? 0 : x - y;
    }

    // =============================================================
    //                        LP FUNCTIONS
    // =============================================================

    /**
     * @notice Deposits asset tokens to receive LP shares.
     * @param amount Amount of asset tokens to deposit.
     * @param minSharesOut Minimum acceptable LP shares (slippage protection).
     */
    function lpDepositAsset(uint256 amount, uint256 minSharesOut) external {
        require(amount <= type(uint256).max - totalDepositedTokens, "Amount too large");
        _updateSharePrices();

        uint256 shares = (amount * 1e18) / lpSharePrice;
        if (shares < minSharesOut) revert Slippage();

        assetToken.safeTransferFrom(msg.sender, address(this), amount);
        totalDepositedTokens += amount;
        _mint(msg.sender, shares);

        emit LPDeposit(msg.sender, amount, shares);
    }

    /**
     * @notice Redeems LP shares for asset tokens.
     * @param shares Amount of LP shares to redeem.
     * @param minAssetOut Minimum acceptable asset tokens to receive.
     */
    function lpRedeemShares(uint256 shares, uint256 minAssetOut) external {
        _updateSharePrices();

        uint256 amount = (shares * lpSharePrice) / 1e18;
        if (amount < minAssetOut) revert Slippage();
        if (amount > totalDepositedTokens - totalBorrowedTokens) revert InsufficientLiquidity();

        _burn(msg.sender, shares);
        totalDepositedTokens -= amount;

        assetToken.safeTransfer(msg.sender, amount);
        emit LPRedeem(msg.sender, shares, amount);
    }

    // =============================================================
    //                      BORROWER FUNCTIONS
    // =============================================================

    /**
     * @notice Deposits collateral tokens.
     * @param amount Amount of collateral tokens to deposit.
     */
    function borrowerDepositCollateral(uint256 amount) external {
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        borrowerInfo[msg.sender].collateralTokenAmount += amount;
        emit DepositCollateral(msg.sender, amount);
    }

    /**
     * @notice Withdraws collateral tokens if collateralization remains above minimum.
     * @param amount Amount of collateral to withdraw.
     */
    function borrowerWithdrawCollateral(uint256 amount) external {
        BorrowerInfo storage info = borrowerInfo[msg.sender];
        if (amount > info.collateralTokenAmount) revert InsufficientCollateral();

        info.collateralTokenAmount -= amount;
        if (collateralizationRatio(msg.sender) < MIN_COLLATERALIZATION_RATIO) {
            info.collateralTokenAmount += amount;
            revert MinCollateralization();
        }

        collateralToken.safeTransfer(msg.sender, amount);
        emit WithdrawCollateral(msg.sender, amount);
    }

    /**
     * @notice Borrows asset tokens against collateral.
     * @param amount Amount of asset tokens to borrow.
     */
    function borrow(uint256 amount) external {
        _updateSharePrices();
        if (amount > totalDepositedTokens - totalBorrowedTokens) revert InsufficientLiquidity();

        uint256 sharesToMint = (amount * 1e18) / borrowerSharePrice;
        borrowerInfo[msg.sender].borrowerShares += sharesToMint;
        totalBorrowedTokens += amount;

        if (collateralizationRatio(msg.sender) < MIN_COLLATERALIZATION_RATIO) {
            borrowerInfo[msg.sender].borrowerShares -= sharesToMint;
            totalBorrowedTokens -= amount;
            revert MinCollateralization();
        }

        assetToken.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    /**
     * @notice Repays borrowed asset tokens.
     * @param amount Amount of asset tokens to repay.
     * @param minSharesBurned Minimum acceptable shares to burn (slippage protection).
     */
    function repay(uint256 amount, uint256 minSharesBurned) external {
        _updateSharePrices();

        BorrowerInfo storage info = borrowerInfo[msg.sender];
        uint256 sharesToBurn = (amount * 1e18) / borrowerSharePrice;

        if (sharesToBurn < minSharesBurned) revert Slippage();
        if (sharesToBurn > info.borrowerShares) sharesToBurn = info.borrowerShares;

        info.borrowerShares = _subFloorZero(info.borrowerShares, sharesToBurn);
        totalBorrowedTokens = _subFloorZero(totalBorrowedTokens, amount);

        assetToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Repay(msg.sender, amount);
    }

    /**
     * @notice Liquidates a borrower if undercollateralized.
     * @param borrower Address of the borrower to liquidate.
     */
    function liquidate(address borrower) external {
        if (!canLiquidate(borrower)) revert HealthyAccount();

        BorrowerInfo storage info = borrowerInfo[borrower];
        uint256 debtAmount = (info.borrowerShares * borrowerSharePrice) / 1e18;

        assetToken.safeTransferFrom(msg.sender, address(this), debtAmount);
        totalBorrowedTokens = _subFloorZero(totalBorrowedTokens, debtAmount);
        info.borrowerShares = 0;

        uint256 collateralAmount = info.collateralTokenAmount;
        info.collateralTokenAmount = 0;

        collateralToken.safeTransfer(msg.sender, collateralAmount);
        emit Liquidate(msg.sender, borrower, debtAmount);
    }
}
