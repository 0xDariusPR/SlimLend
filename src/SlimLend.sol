// SPDX-License-Identifier: BSL-3.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

contract SlimLend is ERC20("LPSlimShares", "LPS") {

    using SafeERC20 for IERC20;

    uint256 totalDepositedTokens;
    uint256 totalBorrowedTokens; 
    uint256 lpSharePrice = 1e18;
    uint256 borrowerSharePrice = 1e18;
    uint256 lastUpdateTime = block.timestamp;
    IERC20 immutable assetToken;
    IERC20 immutable collateralToken;
    IPriceFeed immutable priceFeed;
    
    uint256 constant MIN_COLLATERALIZATION_RATIO = 1.5e18;
    uint256 constant LIQUIDATION_THRESHOLD = 1.1e18;
    uint256 constant OPTIMAL_UTILIZATION = 0.95e18;
    uint256 constant KINK_INTEREST_PER_SECOND = 1585489599; // see test for derivation
    uint256 constant MAX_INTEREST_PER_SECOND = 15854895991; // see test for derivation

    error Slippage();
    error InsufficientLiquidity();
    error MinCollateralization();
    error HealthyAccount();
    error InsufficientCollateral();

    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPRedeem(address indexed user, uint256 shares, uint256 amount);
    event DepositCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);

    struct BorrowerInfo {
        uint256 borrowerShares;
        uint256 collateralTokenAmount;
    }

    mapping(address => BorrowerInfo) public borrowerInfo;

    constructor(IERC20 _assetToken, IERC20 _collateralToken, IPriceFeed _priceFeed) {
        assetToken = _assetToken;
        collateralToken = _collateralToken;
        priceFeed = _priceFeed;
    }

    // returns utilization [0-1] with 18 decimals
    function utilization() public view returns (uint256) {
        if (totalDepositedTokens > 0) {
            return 10**18 * totalBorrowedTokens / totalDepositedTokens;
        }
        return 0;
    }

    function interestRate(uint256 _utilization) public pure returns (uint256 borrowerRate, uint256 lenderRate) {
        if (_utilization <= OPTIMAL_UTILIZATION) {
            uint256 borrowRate = _utilization * KINK_INTEREST_PER_SECOND / OPTIMAL_UTILIZATION;
            return (borrowRate, borrowRate * _utilization / 1e18);
        } else {
            uint256 xdiff = 1e18 - OPTIMAL_UTILIZATION;
            uint256 ydiff = MAX_INTEREST_PER_SECOND - KINK_INTEREST_PER_SECOND;
            uint256 negB = ydiff * 10**18 / xdiff - MAX_INTEREST_PER_SECOND;

            uint256 borrowRate = ydiff * _utilization / xdiff - negB;
            return (borrowRate, borrowRate * _utilization / 1e18);
        }
    }

    function _updateSharePrices() internal {
        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        if (timeElapsed > 0) {
            (uint256 borrowerRate, uint256 lenderRate) = interestRate(utilization());
            lpSharePrice += lpSharePrice * lenderRate * timeElapsed;
            borrowerSharePrice += borrowerSharePrice * borrowerRate * timeElapsed;
        }
        lastUpdateTime = block.timestamp;
    }

    function lpDepositAsset(uint256 amount, uint256 minSharesOut) public {
        _updateSharePrices();
        uint256 shares = 10**18 * amount / lpSharePrice;
        if (shares < minSharesOut) revert Slippage();
        assetToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, shares);
        totalDepositedTokens += amount;
        emit LPDeposit(msg.sender, amount, shares);
    }

    function lpRedeemShares(uint256 amountShares, uint256 minAmountAssetOut) public {
        _updateSharePrices();
        uint256 amountAsset = amountShares * lpSharePrice / 10**18;
        if (amountAsset < minAmountAssetOut) revert Slippage();
        require(totalDepositedTokens - totalBorrowedTokens >= amountAsset, "insufficient liquidity");
        _burn(msg.sender, amountShares);
        totalDepositedTokens -= amountAsset;
        assetToken.safeTransfer(msg.sender, amountAsset);
        emit LPRedeem(msg.sender, amountShares, amountAsset);
    }

    function borrowerDepositCollateral(uint256 amount) public {
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        borrowerInfo[msg.sender].collateralTokenAmount += amount;
        emit DepositCollateral(msg.sender, amount);
    }

    function borrowerWithdrawCollateral(uint256 amount) public {
        _updateSharePrices();
        require(borrowerInfo[msg.sender].collateralTokenAmount >= amount, InsufficientCollateral());
        borrowerInfo[msg.sender].collateralTokenAmount -= amount;
        require(collateralization_ratio(msg.sender) >= MIN_COLLATERALIZATION_RATIO, MinCollateralization());
        collateralToken.safeTransfer(msg.sender, amount);
        emit WithdrawCollateral(msg.sender, amount);
    }

    function borrow(uint256 amount) public {
        _updateSharePrices();
        require(totalDepositedTokens - totalBorrowedTokens >= amount, InsufficientLiquidity());
        uint256 _borrowerShares = 10**18 * amount / borrowerSharePrice;
        borrowerInfo[msg.sender].borrowerShares += _borrowerShares;
        require(collateralization_ratio(msg.sender) >= MIN_COLLATERALIZATION_RATIO, MinCollateralization());
        totalBorrowedTokens += amount;
        assetToken.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    // 18 decimals regardless of oracle. Assumes oracle uses 18 decimals or less
    function collateralValue(address borrower) public view returns (uint256) {
        (,int256 price,,,) = priceFeed.latestRoundData();
        return borrowerInfo[borrower].collateralTokenAmount * uint256(price) / 10**priceFeed.decimals(); // price is now in 18 decimals
    }

    function collateralization_ratio(address borrower) public view returns (uint256) {
        uint256 debtValue = borrowerInfo[borrower].borrowerShares * borrowerSharePrice / 10**18;
        uint256 collateralValueInAsset = collateralValue(borrower);
        if (debtValue == 0) return type(uint256).max; // No debt means infinite collateralization
        return 10**18 * collateralValueInAsset / debtValue; // 18 decimals
    }

    function repay(uint256 amountAsset, uint256 minBorrowSharesBurned) public {
        _updateSharePrices();
        assetToken.safeTransferFrom(msg.sender, address(this), amountAsset);
        totalBorrowedTokens = _subFloorZero(totalBorrowedTokens, amountAsset);
        uint256 borrowerShares = amountAsset * 10**18 / borrowerSharePrice;
        require(borrowerShares >= minBorrowSharesBurned, Slippage());
        borrowerInfo[msg.sender].borrowerShares = _subFloorZero(borrowerInfo[msg.sender].borrowerShares, borrowerShares);
        emit Repay(msg.sender, amountAsset);
    }

    // if x < y return 0, else x - y
    function _subFloorZero(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? 0 : x - y;
    }

    function canLiquidate(address borrower) public view returns (bool) {
        return (collateralization_ratio(borrower) < LIQUIDATION_THRESHOLD) ? true : false;
    }

    function liquidate(address borrower) public {
        _updateSharePrices();
        require(canLiquidate(borrower), HealthyAccount());
        uint256 debtAmount = borrowerInfo[borrower].borrowerShares * borrowerSharePrice / 10**18;
        assetToken.safeTransferFrom(msg.sender, address(this), debtAmount);
        collateralToken.safeTransfer(msg.sender, borrowerInfo[borrower].collateralTokenAmount);

        borrowerInfo[borrower].borrowerShares = 0;
        borrowerInfo[borrower].collateralTokenAmount = 0;
        totalBorrowedTokens = _subFloorZero(totalBorrowedTokens, debtAmount);
        emit Liquidate(msg.sender, borrower, debtAmount);
    }
}