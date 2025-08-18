// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SlimLend, IPriceFeed} from "../src/SlimLend.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPriceFeed is IPriceFeed {
    uint8 public decimals;
    int256 public price;
    
    constructor(uint8 _decimals, int256 _price) {
        decimals = _decimals;
        price = _price;
    }
    
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
    
    function description() external pure returns (string memory) {
        return "Mock Price Feed";
    }
    
    function version() external pure returns (uint256) {
        return 1;
    }
    
    function setPrice(int256 _price) external {
        price = _price;
    }
}

contract SlimLendTest is Test {
    SlimLend public c;
    MockERC20 public assetToken;
    MockERC20 public collateralToken;
    MockPriceFeed public priceFeed;

    bytes32 constant TOTAL_BORROWED_TOKENS_SLOT = bytes32(uint256(6));
    bytes32 constant BORROWER_SHARE_PRICE_SLOT = bytes32(uint256(8));
    bytes32 constant BORROWER_INFO_SLOT = bytes32(uint256(10));
    
    uint256 constant LIQUIDATION_THRESHOLD = 1.1e18;

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 1e8); // 8 decimals, $1 price
        c = new SlimLend(assetToken, collateralToken, priceFeed);
    }

    function _setTotalBorrowedTokens(uint256 amount) internal {
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(amount));
    }

    function _setBorrowerSharePrice(uint256 price) internal {
        vm.store(address(c), BORROWER_SHARE_PRICE_SLOT, bytes32(price));
    }

    function _setBorrowerShares(address user, uint256 shares) internal {
        bytes32 slot = keccak256(abi.encode(user, BORROWER_INFO_SLOT));
        vm.store(address(c), slot, bytes32(shares));
    }

    function _setCollateralAmount(address user, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(user, BORROWER_INFO_SLOT));
        bytes32 collateralSlot = bytes32(uint256(slot) + 1);
        vm.store(address(c), collateralSlot, bytes32(amount));
    }

    function _giveLiquidatorTokens(address liquidator, uint256 amount) internal {
        assetToken.mint(liquidator, amount);
        vm.prank(liquidator);
        assetToken.approve(address(c), amount);
    }

    function _prepareCollateralForContract(uint256 amount) internal {
        collateralToken.mint(address(c), amount);
    }

    function test_liquidate_successful_basic() public {
        address borrower = address(0x1);
        address liquidator = address(0x2);
        uint256 debtShares = 100e18; // 100 shares
        uint256 collateralAmount = 105e18; // $105 collateral (105% ratio)
        uint256 debtValue = 100e18; // $100 debt at 1e18 share price

        // Setup: Borrower is under-collateralized (105% < 110% threshold)
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(500e18); // Global debt
        priceFeed.setPrice(1e8); // $1 collateral price

        // Setup: Give liquidator tokens and contract collateral
        _giveLiquidatorTokens(liquidator, debtValue);
        _prepareCollateralForContract(collateralAmount);

        // Verify borrower can be liquidated
        assertTrue(c.canLiquidate(borrower), "Borrower should be liquidatable");
        uint256 ratio = c.collateralization_ratio(borrower);
        assertLt(ratio, LIQUIDATION_THRESHOLD, "Ratio should be below liquidation threshold");

        // Initial state checks
        uint256 initialLiquidatorAssetBalance = assetToken.balanceOf(liquidator);
        uint256 initialLiquidatorCollateralBalance = collateralToken.balanceOf(liquidator);
        uint256 initialContractAssetBalance = assetToken.balanceOf(address(c));
        uint256 initialContractCollateralBalance = collateralToken.balanceOf(address(c));
        (uint256 initialBorrowerShares, uint256 initialBorrowerCollateral) = c.borrowerInfo(borrower);

        assertEq(initialBorrowerShares, debtShares, "Borrower should have initial debt shares");
        assertEq(initialBorrowerCollateral, collateralAmount, "Borrower should have initial collateral");

        // Execute liquidation
        vm.prank(liquidator);
        c.liquidate(borrower);

        {
        // Verify token transfers
        uint256 finalLiquidatorAssetBalance = assetToken.balanceOf(liquidator);
        uint256 finalLiquidatorCollateralBalance = collateralToken.balanceOf(liquidator);
        uint256 finalContractAssetBalance = assetToken.balanceOf(address(c));
        uint256 finalContractCollateralBalance = collateralToken.balanceOf(address(c));

        assertEq(finalLiquidatorAssetBalance, initialLiquidatorAssetBalance - debtValue, "Liquidator should pay debt");
        assertEq(finalLiquidatorCollateralBalance, initialLiquidatorCollateralBalance + collateralAmount, "Liquidator should receive collateral");
        assertEq(finalContractAssetBalance, initialContractAssetBalance + debtValue, "Contract should receive debt payment");
        assertEq(finalContractCollateralBalance, initialContractCollateralBalance - collateralAmount, "Contract should transfer collateral");
        }

        { // prevent stack too deep
            // Verify borrower state cleared
            (uint256 finalBorrowerShares, uint256 finalBorrowerCollateral) = c.borrowerInfo(borrower);
            assertEq(finalBorrowerShares, 0, "Borrower shares should be cleared");
            assertEq(finalBorrowerCollateral, 0, "Borrower collateral should be cleared");
        }

        // Verify global accounting
        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 400e18, "Global debt should decrease by liquidated amount");
    }

    function test_liquidate_event_emission() public {
        address borrower = address(0x3);
        address liquidator = address(0x4);
        uint256 debtShares = 50e18;
        uint256 collateralAmount = 50e18; // 100% ratio (below 110% threshold)

        // Setup liquidatable borrower
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(200e18);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, 50e18);
        _prepareCollateralForContract(collateralAmount);

        // Expect Liquidate event
        vm.expectEmit(true, true, false, true);
        emit SlimLend.Liquidate(liquidator, borrower, 50e18);

        vm.prank(liquidator);
        c.liquidate(borrower);
    }

    function test_liquidate_fails_healthy_account() public {
        address borrower = address(0x5);
        address liquidator = address(0x6);
        uint256 debtShares = 100e18;
        uint256 collateralAmount = 200e18; // 200% ratio (above 110% threshold)

        // Setup: Borrower is well-collateralized
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, 100e18);
        _prepareCollateralForContract(collateralAmount);

        // Verify borrower cannot be liquidated
        assertFalse(c.canLiquidate(borrower), "Healthy borrower should not be liquidatable");

        vm.prank(liquidator);
        vm.expectRevert(SlimLend.HealthyAccount.selector);
        c.liquidate(borrower);
    }

    function test_liquidate_boundary_case_exact_threshold() public {
        address borrower = address(0x7);
        address liquidator = address(0x8);
        uint256 debtShares = 100e18;
        uint256 collateralAmount = 110e18; // Exactly 110% (at liquidation threshold)

        // Setup: Borrower at exact liquidation threshold
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, 100e18);
        _prepareCollateralForContract(collateralAmount);

        // At exactly 110%, should NOT be liquidatable (need to be below threshold)
        uint256 ratio = c.collateralization_ratio(borrower);
        assertEq(ratio, LIQUIDATION_THRESHOLD, "Should be exactly at threshold");
        assertFalse(c.canLiquidate(borrower), "Should not be liquidatable at exact threshold");

        vm.prank(liquidator);
        vm.expectRevert(SlimLend.HealthyAccount.selector);
        c.liquidate(borrower);
    }

    function test_liquidate_just_below_threshold() public {
        address borrower = address(0x9);
        address liquidator = address(0xa);
        uint256 debtShares = 1000e18; // Large debt for precision
        uint256 collateralAmount = 1099e18; // 109.9% ratio (just below 110%)

        // Setup: Borrower just below liquidation threshold
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(2000e18);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, 1000e18);
        _prepareCollateralForContract(collateralAmount);

        // Should be liquidatable (just below threshold)
        uint256 ratio = c.collateralization_ratio(borrower);
        assertLt(ratio, LIQUIDATION_THRESHOLD, "Should be below threshold");
        assertTrue(c.canLiquidate(borrower), "Should be liquidatable just below threshold");

        vm.prank(liquidator);
        c.liquidate(borrower); // Should succeed
    }

    function test_liquidate_order_of_operations_transfer_before_clear() public {
        address borrower = address(0xb);
        address liquidator = address(0xc);
        uint256 debtShares = 100e18;
        uint256 collateralAmount = 105e18;

        // Setup liquidatable borrower
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        priceFeed.setPrice(1e8);

        // Setup: Give liquidator tokens but DON'T give contract collateral
        _giveLiquidatorTokens(liquidator, 100e18);
        // Intentionally NOT calling _prepareCollateralForContract

        // Critical test: If transfers happen after state clearing, this would fail silently
        // But if transfers happen before clearing (correct order), this should fail on transfer
        vm.prank(liquidator);
        vm.expectRevert(); // Should fail on collateral transfer (insufficient balance)
        c.liquidate(borrower);

        // Verify: No state changes occurred (because transfer failed before clearing)
        (uint256 shares, uint256 collateral) = c.borrowerInfo(borrower);
        assertEq(shares, debtShares, "Borrower shares should remain unchanged after failed liquidation");
        assertEq(collateral, collateralAmount, "Borrower collateral should remain unchanged after failed liquidation");

        uint256 totalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(totalBorrowed, 300e18, "Global debt should remain unchanged after failed liquidation");
    }

    function test_liquidate_order_of_operations_asset_payment_first() public {
        address borrower = address(0xd);
        address liquidator = address(0xe);
        uint256 debtShares = 100e18;
        uint256 collateralAmount = 105e18;

        // Setup liquidatable borrower
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        priceFeed.setPrice(1e8);

        // Setup: Give contract collateral but DON'T give liquidator sufficient tokens
        _prepareCollateralForContract(collateralAmount);
        assetToken.mint(liquidator, 50e18); // Only half the needed amount
        vm.prank(liquidator);
        assetToken.approve(address(c), 50e18);

        // Critical test: Asset payment happens FIRST
        // If debt payment checked after other operations, might allow partial liquidation
        // If debt payment checked first (correct), should fail immediately
        vm.prank(liquidator);
        vm.expectRevert(); // Should fail on asset transfer (insufficient balance/allowance)
        c.liquidate(borrower);

        // Verify: No state changes occurred
        (uint256 shares, uint256 collateral) = c.borrowerInfo(borrower);
        assertEq(shares, debtShares, "Borrower state should be unchanged after failed payment");
        assertEq(collateral, collateralAmount, "Borrower collateral should be unchanged");

        uint256 liquidatorCollateralBalance = collateralToken.balanceOf(liquidator);
        assertEq(liquidatorCollateralBalance, 0, "Liquidator should not receive collateral after failed payment");
    }

    function test_liquidate_different_share_prices() public {
        address borrower = address(0xf);
        address liquidator = address(0x10);
        uint256 debtShares = 50e18; // 50 shares
        uint256 collateralAmount = 105e18;

        // Setup with 2e18 share price: 50 shares * 2e18 = 100e18 debt value
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(2e18);
        _setTotalBorrowedTokens(400e18);
        priceFeed.setPrice(1e8);

        uint256 expectedDebtValue = 100e18; // 50 shares * 2e18 / 1e18
        _giveLiquidatorTokens(liquidator, expectedDebtValue);
        _prepareCollateralForContract(collateralAmount);

        // Verify ratio calculation with higher share price
        uint256 ratio = c.collateralization_ratio(borrower);
        assertEq(ratio, 1.05e18, "Should be 105% collateralized (105/100)");
        assertTrue(c.canLiquidate(borrower), "Should be liquidatable at 105%");

        vm.prank(liquidator);
        c.liquidate(borrower);

        // Verify liquidator paid correct debt amount
        uint256 liquidatorFinalBalance = assetToken.balanceOf(liquidator);
        assertEq(liquidatorFinalBalance, 0, "Liquidator should have paid 100e18 debt value");

        // Verify global debt decreased by debt value, not share count
        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 300e18, "Global debt should decrease by debt value (100), not shares (50)");
    }

    function test_liquidate_different_collateral_prices() public {
        address borrower = address(0x11);
        address liquidator = address(0x12);
        uint256 debtShares = 100e18;
        uint256 collateralTokens = 52.5e18; // 52.5 collateral tokens

        // Setup with $2 collateral price: 52.5 tokens * $2 = $105 collateral value
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralTokens);
        _setBorrowerSharePrice(1e18); // $100 debt
        _setTotalBorrowedTokens(300e18);
        priceFeed.setPrice(2e8); // $2 per collateral token

        _giveLiquidatorTokens(liquidator, 100e18);
        _prepareCollateralForContract(collateralTokens);

        // Verify ratio with higher collateral price
        uint256 ratio = c.collateralization_ratio(borrower);
        assertEq(ratio, 1.05e18, "Should be 105% collateralized ($105/$100)");

        vm.prank(liquidator);
        c.liquidate(borrower);

        // Verify liquidator receives actual token amount, not value
        uint256 liquidatorCollateralBalance = collateralToken.balanceOf(liquidator);
        assertEq(liquidatorCollateralBalance, collateralTokens, "Should receive actual token amount (52.5), not value");
    }

    function test_liquidate_zero_debt() public {
        address borrower = address(0x13);
        address liquidator = address(0x14);
        uint256 collateralAmount = 100e18;

        // Setup: Borrower has collateral but no debt
        _setBorrowerShares(borrower, 0);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(200e18);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, 0);
        _prepareCollateralForContract(collateralAmount);

        // Should not be liquidatable (infinite collateralization ratio)
        assertFalse(c.canLiquidate(borrower), "Zero debt should not be liquidatable");

        vm.prank(liquidator);
        vm.expectRevert(SlimLend.HealthyAccount.selector);
        c.liquidate(borrower);
    }

    function test_liquidate_zero_collateral() public {
        address borrower = address(0x15);
        address liquidator = address(0x16);
        uint256 debtShares = 100e18;

        // Setup: Borrower has debt but no collateral (0% collateralized)
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, 0);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, 100e18);
        // No collateral to prepare since borrower has none

        // Should be liquidatable (0% < 110%)
        assertTrue(c.canLiquidate(borrower), "Zero collateral should be liquidatable");

        vm.prank(liquidator);
        c.liquidate(borrower); // Should succeed

        // Verify liquidator paid debt but received no collateral
        uint256 liquidatorAssetBalance = assetToken.balanceOf(liquidator);
        uint256 liquidatorCollateralBalance = collateralToken.balanceOf(liquidator);
        
        assertEq(liquidatorAssetBalance, 0, "Liquidator should have paid debt");
        assertEq(liquidatorCollateralBalance, 0, "Liquidator should receive no collateral");

        // Verify borrower state cleared
        (uint256 shares, uint256 collateral) = c.borrowerInfo(borrower);
        assertEq(shares, 0, "Borrower debt should be cleared");
        assertEq(collateral, 0, "Borrower collateral should remain zero");
    }

    function test_liquidate_very_small_amounts() public {
        address borrower = address(0x17);
        address liquidator = address(0x18);
        uint256 debtShares = 1000; // 1000 wei
        uint256 collateralAmount = 1000; // 1000 wei (100% ratio)

        // Setup with very small amounts
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(2000);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, 1000);
        _prepareCollateralForContract(1000);

        // Should be liquidatable (100% < 110%)
        assertTrue(c.canLiquidate(borrower), "Small amounts should be liquidatable at 100%");

        vm.prank(liquidator);
        c.liquidate(borrower);

        // Verify small amounts handled correctly
        uint256 liquidatorAssetBalance = assetToken.balanceOf(liquidator);
        uint256 liquidatorCollateralBalance = collateralToken.balanceOf(liquidator);
        
        assertEq(liquidatorAssetBalance, 0, "Should have paid 1000 wei debt");
        assertEq(liquidatorCollateralBalance, 1000, "Should have received 1000 wei collateral");
    }

    function test_liquidate_global_accounting_edge_case() public {
        address borrower = address(0x19);
        address liquidator = address(0x1a);
        uint256 debtShares = 150e18;
        uint256 debtValue = 150e18;
        uint256 collateralAmount = 160e18; // 106.67% ratio
        uint256 initialGlobalDebt = 100e18; // Less than debt value

        // Setup: Global debt is less than liquidation amount (edge case)
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(initialGlobalDebt);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, debtValue);
        _prepareCollateralForContract(collateralAmount);

        vm.prank(liquidator);
        c.liquidate(borrower);

        // Verify _subFloorZero protection works for global accounting
        uint256 finalGlobalDebt = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalGlobalDebt, 0, "Global debt should floor to 0 when liquidation exceeds total");

        // Verify liquidation still completed normally
        (uint256 shares, uint256 collateral) = c.borrowerInfo(borrower);
        assertEq(shares, 0, "Borrower should be cleared");
        assertEq(collateral, 0, "Collateral should be cleared");
    }

    function test_liquidate_multiple_liquidations() public {
        address borrower1 = address(0x1b);
        address borrower2 = address(0x1c);
        address liquidator = address(0x1d);
        
        uint256 debt1 = 80e18;
        uint256 debt2 = 60e18;
        uint256 collateral1 = 85e18; // 106.25% ratio
        uint256 collateral2 = 65e18; // 108.33% ratio

        // Setup two liquidatable borrowers
        _setBorrowerShares(borrower1, debt1);
        _setCollateralAmount(borrower1, collateral1);
        _setBorrowerShares(borrower2, debt2);
        _setCollateralAmount(borrower2, collateral2);
        
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(500e18);
        priceFeed.setPrice(1e8);

        _giveLiquidatorTokens(liquidator, debt1 + debt2);
        _prepareCollateralForContract(collateral1 + collateral2);

        // First liquidation
        vm.prank(liquidator);
        c.liquidate(borrower1);

        uint256 midGlobalDebt = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(midGlobalDebt, 420e18, "Global debt should decrease by first liquidation");

        uint256 midLiquidatorCollateral = collateralToken.balanceOf(liquidator);
        assertEq(midLiquidatorCollateral, collateral1, "Should receive first borrower's collateral");

        // Second liquidation
        vm.prank(liquidator);
        c.liquidate(borrower2);

        uint256 finalGlobalDebt = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalGlobalDebt, 360e18, "Global debt should decrease by both liquidations");

        uint256 finalLiquidatorCollateral = collateralToken.balanceOf(liquidator);
        assertEq(finalLiquidatorCollateral, collateral1 + collateral2, "Should receive both borrowers' collateral");
    }

    function test_liquidate_insufficient_liquidator_allowance() public {
        address borrower = address(0x1e);
        address liquidator = address(0x1f);
        uint256 debtShares = 100e18;
        uint256 collateralAmount = 105e18;

        // Setup liquidatable borrower
        _setBorrowerShares(borrower, debtShares);
        _setCollateralAmount(borrower, collateralAmount);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        priceFeed.setPrice(1e8);

        // Give liquidator tokens but insufficient allowance
        assetToken.mint(liquidator, 100e18);
        vm.prank(liquidator);
        assetToken.approve(address(c), 50e18); // Only approve half

        _prepareCollateralForContract(collateralAmount);

        // Should fail on transferFrom due to insufficient allowance
        vm.prank(liquidator);
        vm.expectRevert(); // ERC20 insufficient allowance
        c.liquidate(borrower);

        // Verify no state changes
        (uint256 shares, uint256 collateral) = c.borrowerInfo(borrower);
        assertEq(shares, debtShares, "Borrower state should be unchanged");
        assertEq(collateral, collateralAmount, "Collateral should be unchanged");
    }
}