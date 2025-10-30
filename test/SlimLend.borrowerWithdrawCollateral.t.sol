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

    bytes32 constant BORROWER_SHARE_PRICE_SLOT = bytes32(uint256(8));
    bytes32 constant BORROWER_INFO_SLOT = bytes32(uint256(10));
    
    uint256 constant MIN_COLLATERALIZATION_RATIO = 1.5e18;

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 1e8); // 8 decimals, $1 price
        c = new SlimLend(assetToken, collateralToken, priceFeed);
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

    function _setBorrowerSharePrice(uint256 price) internal {
        vm.store(address(c), BORROWER_SHARE_PRICE_SLOT, bytes32(price));
    }

    function _prepareContractCollateral(uint256 amount) internal {
        collateralToken.mint(address(c), amount);
    }

    function test_borrowerWithdrawCollateral_successful_no_debt() public {
        address user = address(0x1);
        uint256 collateralAmount = 200e18;
        uint256 withdrawAmount = 50e18;

        // Setup: User has collateral but no debt
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, 0); // No debt
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);

        // Prepare contract with collateral
        _prepareContractCollateral(collateralAmount);

        // Initial state checks
        uint256 initialUserBalance = collateralToken.balanceOf(user);
        uint256 initialContractBalance = collateralToken.balanceOf(address(c));
        (uint256 initialShares, uint256 initialCollateral) = c.borrowerInfo(user);

        assertEq(initialUserBalance, 0, "User should start with no collateral tokens");
        assertEq(initialCollateral, collateralAmount, "User should have recorded collateral");

        // Execute withdrawal
        vm.prank(user);
        c.borrowerWithdrawCollateral(withdrawAmount);

        // Verify token transfer
        uint256 finalUserBalance = collateralToken.balanceOf(user);
        uint256 finalContractBalance = collateralToken.balanceOf(address(c));

        assertEq(finalUserBalance, withdrawAmount, "User should receive withdrawn amount");
        assertEq(finalContractBalance, initialContractBalance - withdrawAmount, "Contract should transfer tokens");

        // Verify state update
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalShares, 0, "User should still have no debt");
        assertEq(finalCollateral, collateralAmount - withdrawAmount, "Collateral balance should decrease");
    }

    function test_borrowerWithdrawCollateral_successful_with_debt() public {
        address user = address(0x2);
        uint256 collateralAmount = 300e18; // $300 collateral
        uint256 debtShares = 100e18; // $100 debt (300% ratio initially)
        uint256 withdrawAmount = 100e18; // Withdraw $100 (leaving 200% ratio)

        // Setup: User with debt, well collateralized
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);

        _prepareContractCollateral(collateralAmount);

        // Verify initial state
        uint256 initialRatio = c.collateralizationRatio(user);
        assertEq(initialRatio, 3e18, "Should start at 300% collateralization");

        vm.prank(user);
        c.borrowerWithdrawCollateral(withdrawAmount);

        // Verify final collateralization
        uint256 finalRatio = c.collateralizationRatio(user);
        assertEq(finalRatio, 2e18, "Should end at 200% collateralization");
        assertGe(finalRatio, MIN_COLLATERALIZATION_RATIO, "Should still meet minimum requirement");

        // Verify balances
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalShares, debtShares, "Debt should remain unchanged");
        assertEq(finalCollateral, 200e18, "Should have 200e18 collateral remaining");
    }

    function test_borrowerWithdrawCollateral_event_emission() public {
        address user = address(0x3);
        uint256 collateralAmount = 200e18;
        uint256 withdrawAmount = 75e18;

        // Setup
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, 0); // No debt for simplicity
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        // Expect WithdrawCollateral event
        vm.expectEmit(true, false, false, true);
        emit SlimLend.WithdrawCollateral(user, withdrawAmount);

        vm.prank(user);
        c.borrowerWithdrawCollateral(withdrawAmount);
    }

    function test_borrowerWithdrawCollateral_fails_insufficient_balance() public {
        address user = address(0x4);
        uint256 collateralAmount = 50e18;
        uint256 withdrawAmount = 100e18; // More than available

        // Setup: User has less collateral than withdrawal amount
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, 0);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        vm.prank(user);
        vm.expectRevert(SlimLend.InsufficientCollateral.selector);
        c.borrowerWithdrawCollateral(withdrawAmount);
    }

    function test_borrowerWithdrawCollateral_fails_min_collateralization() public {
        address user = address(0x5);
        uint256 collateralAmount = 180e18; // $180 collateral
        uint256 debtShares = 100e18; // $100 debt (180% ratio initially)
        uint256 withdrawAmount = 50e18; // Would leave $130 collateral (130% ratio < 150%)

        // Setup: Withdrawal would violate minimum collateralization
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        // Verify initial state is valid
        uint256 initialRatio = c.collateralizationRatio(user);
        assertEq(initialRatio, 1.8e18, "Should start at 180% collateralization");

        // Withdrawal should fail due to minimum collateralization
        vm.prank(user);
        vm.expectRevert(SlimLend.MinCollateralization.selector);
        c.borrowerWithdrawCollateral(withdrawAmount);

        // Verify no state changes occurred
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalShares, debtShares, "Debt should remain unchanged");
        assertEq(finalCollateral, collateralAmount, "Collateral should remain unchanged");
    }

    function test_borrowerWithdrawCollateral_boundary_case_exact_minimum() public {
        address user = address(0x6);
        uint256 collateralAmount = 225e18; // $225 collateral
        uint256 debtShares = 100e18; // $100 debt
        uint256 withdrawAmount = 75e18; // Would leave exactly $150 (150% ratio)

        // Setup: Withdrawal results in exactly minimum collateralization
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        // Should succeed (exactly at minimum)
        vm.prank(user);
        c.borrowerWithdrawCollateral(withdrawAmount);

        uint256 finalRatio = c.collateralizationRatio(user);
        assertEq(finalRatio, MIN_COLLATERALIZATION_RATIO, "Should be exactly at minimum");
        assertEq(finalRatio, 1.5e18, "Should be 150%");

        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalCollateral, 150e18, "Should have exactly 150e18 remaining");
    }

    function test_borrowerWithdrawCollateral_order_of_operations_critical() public {
        address user = address(0x7);
        uint256 collateralAmount = 160e18; // $160 collateral
        uint256 debtShares = 100e18; // $100 debt (160% ratio initially)
        uint256 withdrawAmount = 20e18; // Would leave $140 collateral (140% ratio < 150%)

        // Setup: This tests that collateralization is checked AFTER reducing collateral
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        // Initial ratio: 160% > 150% ✅ (would pass if checked before withdrawal)
        // Final ratio: 140% < 150% ❌ (correctly fails when checked after withdrawal)
        
        uint256 initialRatio = c.collateralizationRatio(user);
        assertEq(initialRatio, 1.6e18, "Should start at 160%");
        assertGe(initialRatio, MIN_COLLATERALIZATION_RATIO, "Initial ratio should be valid");

        // Critical: This proves collateralization is checked AFTER reducing collateral
        // If checked before: 160% >= 150% ✅ → would incorrectly allow
        // If checked after: 140% < 150% ❌ → correctly fails
        vm.prank(user);
        vm.expectRevert(SlimLend.MinCollateralization.selector);
        c.borrowerWithdrawCollateral(withdrawAmount);

        // Verify no state changes (withdrawal failed)
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalCollateral, collateralAmount, "Collateral should remain unchanged after failed withdrawal");
        assertEq(finalShares, debtShares, "Debt should remain unchanged");
    }

    function test_borrowerWithdrawCollateral_order_of_operations_token_transfer_after_checks() public {
        address user = address(0x8);
        uint256 collateralAmount = 200e18;
        uint256 withdrawAmount = 50e18;

        // Setup: User has collateral but contract has insufficient balance
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, 0); // No debt
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        
        // Intentionally NOT giving contract enough collateral
        collateralToken.mint(address(c), withdrawAmount - 1); // 1 wei short

        // Critical test: Token transfer happens AFTER state changes
        // If state updated first, user balance would change before transfer fails
        // If transfer happens after state change, failure should revert everything
        vm.prank(user);
        vm.expectRevert(); // Should fail on token transfer (insufficient balance)
        c.borrowerWithdrawCollateral(withdrawAmount);

        // Verify: No permanent state changes occurred (transaction reverted)
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalCollateral, collateralAmount, "Collateral balance should be unchanged after failed transfer");

        uint256 userBalance = collateralToken.balanceOf(user);
        assertEq(userBalance, 0, "User should not have received tokens after failed transfer");
    }

    function test_borrowerWithdrawCollateral_different_share_prices() public {
        address user = address(0x9);
        uint256 collateralAmount = 300e18; // $300 collateral
        uint256 debtShares = 100e18; // 100 shares
        uint256 withdrawAmount = 50e18;

        // Setup with 2e18 share price: 100 shares * 2e18 = $200 debt
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(2e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        // Initial: $300/$200 = 150% (exactly at minimum)
        // After withdrawal: $250/$200 = 125% < 150% (should fail)
        
        uint256 initialRatio = c.collateralizationRatio(user);
        assertEq(initialRatio, 1.5e18, "Should start at exactly 150%");

        vm.prank(user);
        vm.expectRevert(SlimLend.MinCollateralization.selector);
        c.borrowerWithdrawCollateral(withdrawAmount);
    }

    function test_borrowerWithdrawCollateral_different_collateral_prices() public {
        address user = address(0xa);
        uint256 collateralTokens = 150e18; // 150 collateral tokens
        uint256 debtShares = 100e18; // $100 debt
        uint256 withdrawTokens = 25e18; // 25 collateral tokens

        // Setup with $2 collateral price: 150 tokens * $2 = $300 collateral value
        _setCollateralAmount(user, collateralTokens);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(2e8); // $2 per token
        _prepareContractCollateral(collateralTokens);

        // Initial: $300/$100 = 300%
        // After withdrawal: (150-25) * $2 = $250/$100 = 250% (still above 150%)
        
        vm.prank(user);
        c.borrowerWithdrawCollateral(withdrawTokens); // Should succeed

        uint256 finalRatio = c.collateralizationRatio(user);
        assertEq(finalRatio, 2.5e18, "Should be 250% after withdrawal");

        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalCollateral, 125e18, "Should have 125 tokens remaining");
    }

    function test_borrowerWithdrawCollateral_zero_withdrawal() public {
        address user = address(0xb);
        uint256 collateralAmount = 100e18;

        // Setup
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, 50e18);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        vm.prank(user);
        c.borrowerWithdrawCollateral(0); // Should work but do nothing

        // Verify no changes
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalCollateral, collateralAmount, "Collateral should remain unchanged");

        uint256 userBalance = collateralToken.balanceOf(user);
        assertEq(userBalance, 0, "User should receive no tokens");
    }

    function test_borrowerWithdrawCollateral_full_withdrawal_no_debt() public {
        address user = address(0xc);
        uint256 collateralAmount = 100e18;

        // Setup: User with no debt can withdraw everything
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, 0); // No debt
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        vm.prank(user);
        c.borrowerWithdrawCollateral(collateralAmount); // Withdraw everything

        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalCollateral, 0, "Should have no collateral remaining");
        assertEq(finalShares, 0, "Should still have no debt");

        uint256 userBalance = collateralToken.balanceOf(user);
        assertEq(userBalance, collateralAmount, "User should receive all collateral");
    }

    function test_borrowerWithdrawCollateral_very_small_amounts() public {
        address user = address(0xd);
        uint256 collateralAmount = 1500; // 1500 wei
        uint256 debtShares = 1000; // 1000 wei debt
        uint256 withdrawAmount = 1; // 1 wei

        // Setup with very small amounts
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        // Initial: 150% ratio (exactly at minimum)
        uint256 initialRatio = c.collateralizationRatio(user);
        assertEq(initialRatio, 1.5e18, "Should start at 150%");

        // Withdrawing 1 wei should put us below minimum
        vm.prank(user);
        vm.expectRevert(SlimLend.MinCollateralization.selector);
        c.borrowerWithdrawCollateral(withdrawAmount);
    }

    function test_borrowerWithdrawCollateral_precision_edge_case() public {
        address user = address(0xe);
        uint256 collateralAmount = 1500000000000000001; // 1.5e18 + 1 wei
        uint256 debtShares = 1e18; // Exactly 1e18 debt
        uint256 withdrawAmount = 2; // 2 wei withdrawal

        // Setup: Just above minimum collateralization
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(collateralAmount);

        // Initial ratio: slightly above 150%
        uint256 initialRatio = c.collateralizationRatio(user);
        assertGt(initialRatio, MIN_COLLATERALIZATION_RATIO, "Should be slightly above minimum");

        // After withdrawing 2 wei, should drop below minimum
        vm.prank(user);
        vm.expectRevert(SlimLend.MinCollateralization.selector);
        c.borrowerWithdrawCollateral(withdrawAmount);
    }

    function test_borrowerWithdrawCollateral_multiple_withdrawals() public {
        address user = address(0xf);
        uint256 initialCollateral = 300e18; // $300
        uint256 debtShares = 100e18; // $100 debt
        uint256 firstWithdraw = 50e18;
        uint256 secondWithdraw = 40e18;

        // Setup
        _setCollateralAmount(user, initialCollateral);
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        _prepareContractCollateral(initialCollateral);

        // First withdrawal: 300 -> 250 (250% ratio)
        vm.prank(user);
        c.borrowerWithdrawCollateral(firstWithdraw);

        (uint256 midShares, uint256 midCollateral) = c.borrowerInfo(user);
        assertEq(midCollateral, 250e18, "Should have 250e18 after first withdrawal");

        uint256 midRatio = c.collateralizationRatio(user);
        assertEq(midRatio, 2.5e18, "Should be 250% after first withdrawal");

        // Second withdrawal: 250 -> 210 (210% ratio)
        vm.prank(user);
        c.borrowerWithdrawCollateral(secondWithdraw);

        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalCollateral, 210e18, "Should have 210e18 after second withdrawal");

        uint256 finalRatio = c.collateralizationRatio(user);
        assertEq(finalRatio, 2.1e18, "Should be 210% after second withdrawal");

        // Verify user received both amounts
        uint256 userBalance = collateralToken.balanceOf(user);
        assertEq(userBalance, firstWithdraw + secondWithdraw, "User should receive both withdrawal amounts");
    }

    function test_borrowerWithdrawCollateral_no_collateral() public {
        address user = address(0x10);

        // Setup: User has no collateral
        _setCollateralAmount(user, 0);
        _setBorrowerShares(user, 0);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);

        vm.prank(user);
        vm.expectRevert(SlimLend.InsufficientCollateral.selector);
        c.borrowerWithdrawCollateral(1); // Try to withdraw 1 wei
    }

    function test_borrowerWithdrawCollateral_contract_insufficient_balance() public {
        address user = address(0x11);
        uint256 collateralAmount = 100e18;
        uint256 withdrawAmount = 50e18;

        // Setup: User has collateral recorded but contract doesn't have tokens
        _setCollateralAmount(user, collateralAmount);
        _setBorrowerShares(user, 0); // No debt
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        
        // Intentionally NOT giving contract any collateral tokens
        
        vm.prank(user);
        vm.expectRevert(); // Should fail on token transfer
        c.borrowerWithdrawCollateral(withdrawAmount);
    }
}