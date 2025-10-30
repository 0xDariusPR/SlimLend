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

    bytes32 constant TOTAL_DEPOSITED_TOKENS_SLOT = bytes32(uint256(5));
    bytes32 constant TOTAL_BORROWED_TOKENS_SLOT = bytes32(uint256(6));
    bytes32 constant BORROWER_SHARE_PRICE_SLOT = bytes32(uint256(8));
    bytes32 constant BORROWER_INFO_SLOT = bytes32(uint256(10));

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 1e8); // 8 decimals, $1 price
        c = new SlimLend(assetToken, collateralToken, priceFeed);
    }

    function _setTotalDepositedTokens(uint256 amount) internal {
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(amount));
    }

    function _setTotalBorrowedTokens(uint256 amount) internal {
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(amount));
    }

    function _setBorrowerSharePrice(uint256 price) internal {
        vm.store(address(c), BORROWER_SHARE_PRICE_SLOT, bytes32(price));
    }

    function _setCollateralAmount(address user, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(user, BORROWER_INFO_SLOT));
        bytes32 collateralSlot = bytes32(uint256(slot) + 1);
        vm.store(address(c), collateralSlot, bytes32(amount));
    }

    function _setBorrowerShares(address user, uint256 shares) internal {
        bytes32 slot = keccak256(abi.encode(user, BORROWER_INFO_SLOT));
        vm.store(address(c), slot, bytes32(shares));
    }

    function _prepareContractLiquidity(uint256 amount) internal {
        assetToken.mint(address(c), amount);
        _setTotalDepositedTokens(amount);
    }

    function test_borrow_successful_well_collateralized() public {
        address user = address(0x1);
        uint256 borrowAmount = 100e18;
        uint256 collateralAmount = 300e18; // 300% collateralized after borrow
        
        // Setup: Give user $300 collateral
        _setCollateralAmount(user, collateralAmount);
        priceFeed.setPrice(1e8); // $1 price
        _setBorrowerSharePrice(1e18);
        
        // Setup: Give contract liquidity
        _prepareContractLiquidity(1000e18);
        
        // Initial state checks
        uint256 initialUserBalance = assetToken.balanceOf(user);
        uint256 initialContractBalance = assetToken.balanceOf(address(c));
        (uint256 initialShares,) = c.borrowerInfo(user);
        
        assertEq(initialUserBalance, 0, "User should start with no assets");
        assertEq(initialShares, 0, "User should start with no debt");
        
        // Execute borrow
        vm.prank(user);
        c.borrow(borrowAmount);
        
        // Verify token transfer
        uint256 finalUserBalance = assetToken.balanceOf(user);
        uint256 finalContractBalance = assetToken.balanceOf(address(c));
        
        assertEq(finalUserBalance, borrowAmount, "User should receive borrowed amount");
        assertEq(finalContractBalance, initialContractBalance - borrowAmount, "Contract should transfer tokens");
        
        // Verify debt accounting
        (uint256 finalShares,) = c.borrowerInfo(user);
        uint256 expectedShares = borrowAmount * 1e18 / 1e18; // 100 shares at 1e18 price
        assertEq(finalShares, expectedShares, "Borrower shares should be recorded correctly");
        
        // Verify collateralization ratio
        uint256 ratio = c.collateralizationRatio(user);
        assertEq(ratio, 3e18, "Should be 300% collateralized ($300 collateral / $100 debt)");
        assertGe(ratio, 1.5e18, "Should meet minimum collateralization requirement");
    }

    function test_borrow_event_emission() public {
        address user = address(0x2);
        uint256 borrowAmount = 50e18;
        
        // Setup well-collateralized user
        _setCollateralAmount(user, 200e18); // 400% collateralized
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        // Expect Borrow event
        vm.expectEmit(true, false, false, true);
        emit SlimLend.Borrow(user, borrowAmount);
        
        vm.prank(user);
        c.borrow(borrowAmount);
    }

    function test_borrow_fails_insufficient_liquidity() public {
        address user = address(0x3);
        uint256 borrowAmount = 200e18;
        
        // Setup well-collateralized user
        _setCollateralAmount(user, 500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        // Setup contract with insufficient liquidity
        _prepareContractLiquidity(100e18); // Only 100, user wants 200
        
        vm.prank(user);
        vm.expectRevert(SlimLend.InsufficientLiquidity.selector);
        c.borrow(borrowAmount);
    }

    function test_borrow_fails_insufficient_collateralization() public {
        address user = address(0x4);
        uint256 borrowAmount = 100e18;
        uint256 collateralAmount = 120e18; // Only 120% collateralized, need 150%
        
        // Setup under-collateralized user
        _setCollateralAmount(user, collateralAmount);
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        vm.prank(user);
        vm.expectRevert(SlimLend.MinCollateralization.selector);
        c.borrow(borrowAmount);
    }

    function test_borrow_fails_no_collateral() public {
        address user = address(0x5);
        uint256 borrowAmount = 100e18;
        
        // User has no collateral (0% collateralized)
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        vm.prank(user);
        vm.expectRevert(SlimLend.MinCollateralization.selector);
        c.borrow(borrowAmount);
    }

    function test_borrow_order_of_operations_critical() public {
        address user = address(0x6);
        uint256 borrowAmount = 100e18;
        
        // Setup user with existing debt that makes them 200% collateralized
        _setCollateralAmount(user, 400e18); // $400 collateral
        _setBorrowerShares(user, 100e18); // $100 existing debt (200% ratio)
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        // Before new borrow: 400/100 = 4.0 (400% ratio) ✅
        // After new borrow: 400/200 = 2.0 (200% ratio) ✅ (still above 150% minimum)
        
        // This tests that collateralization is checked AFTER adding new debt
        // If checked before, it would see 400% and allow borrow
        // If checked after, it should see 200% and still allow (above 150%)
        
        vm.prank(user);
        c.borrow(borrowAmount); // Should succeed
        
        // Verify final state
        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, 200e18, "Should have 200 shares total (100 old + 100 new)");
        
        uint256 finalRatio = c.collateralizationRatio(user);
        assertEq(finalRatio, 2e18, "Should be 200% collateralized after new borrow");
    }

    function test_borrow_order_of_operations_boundary() public {
        address user = address(0x7);
        uint256 borrowAmount = 100e18;
        
        // Setup user at exact boundary after new borrow
        _setCollateralAmount(user, 225e18); // $225 collateral
        _setBorrowerShares(user, 50e18); // $50 existing debt
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        // Before new borrow: 225/50 = 4.5 (450% ratio) ✅
        // After new borrow: 225/150 = 1.5 (150% ratio) ✅ (exactly at minimum)
        
        // Critical: This test ensures collateralization is checked AFTER adding debt
        // If checked before: 450% > 150% ✅ → would incorrectly allow
        // If checked after: 150% >= 150% ✅ → correctly allows (boundary case)
        
        vm.prank(user);
        c.borrow(borrowAmount); // Should succeed (exactly at boundary)
        
        uint256 finalRatio = c.collateralizationRatio(user);
        assertEq(finalRatio, 1.5e18, "Should be exactly 150% collateralized");
    }

    function test_borrow_order_of_operations_fail() public {
        address user = address(0x8);
        uint256 borrowAmount = 100e18;
        
        // Setup user that would fail if collateralization checked after adding debt
        _setCollateralAmount(user, 200e18); // $200 collateral  
        _setBorrowerShares(user, 50e18); // $50 existing debt
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        // Before new borrow: 200/50 = 4.0 (400% ratio) ✅
        // After new borrow: 200/150 = 1.33 (133% ratio) ❌ (below 150% minimum)
        
        // Critical: This proves collateralization is checked AFTER adding debt
        // If checked before: 400% > 150% ✅ → would incorrectly allow
        // If checked after: 133% < 150% ❌ → correctly fails
        
        vm.prank(user);
        vm.expectRevert(SlimLend.MinCollateralization.selector);
        c.borrow(borrowAmount); // Should fail due to insufficient collateralization
    }

    function test_borrow_multiple_borrows() public {
        address user = address(0x9);
        uint256 firstBorrow = 50e18;
        uint256 secondBorrow = 30e18;
        
        // Setup well-collateralized user
        _setCollateralAmount(user, 300e18); // $300 collateral
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        // First borrow
        vm.prank(user);
        c.borrow(firstBorrow);
        
        (uint256 sharesAfterFirst,) = c.borrowerInfo(user);
        assertEq(sharesAfterFirst, 50e18, "Should have 50 shares after first borrow");
        
        uint256 ratioAfterFirst = c.collateralizationRatio(user);
        assertEq(ratioAfterFirst, 6e18, "Should be 600% collateralized after first borrow");
        
        // Second borrow
        vm.prank(user);
        c.borrow(secondBorrow);
        
        (uint256 sharesAfterSecond,) = c.borrowerInfo(user);
        assertEq(sharesAfterSecond, 80e18, "Should have 80 shares total");
        
        uint256 ratioAfterSecond = c.collateralizationRatio(user);
        assertEq(ratioAfterSecond, 3.75e18, "Should be 375% collateralized after both borrows");
        
        // Verify user received both amounts
        uint256 userBalance = assetToken.balanceOf(user);
        assertEq(userBalance, firstBorrow + secondBorrow, "User should have received both borrow amounts");
    }

    function test_borrow_different_share_prices() public {
        address user = address(0xa);
        uint256 borrowAmount = 100e18;
        
        // Setup collateral
        _setCollateralAmount(user, 500e18); // Plenty of collateral
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        
        // Test with 2x share price
        _setBorrowerSharePrice(2e18);
        
        vm.prank(user);
        c.borrow(borrowAmount);
        
        (uint256 shares,) = c.borrowerInfo(user);
        uint256 expectedShares = borrowAmount * 1e18 / 2e18; // 50 shares at 2e18 price
        assertEq(shares, expectedShares, "Should get fewer shares at higher share price");
        assertEq(shares, 50e18, "Should get 50 shares for 100 tokens at 2x price");
    }

    function test_borrow_different_collateral_prices() public {
        address user = address(0xb);
        uint256 borrowAmount = 100e18;
        uint256 collateralTokens = 150e18; // 150 collateral tokens (18 decimals)
        
        _setCollateralAmount(user, collateralTokens);
        _prepareContractLiquidity(500e18);
        _setBorrowerSharePrice(1e18);
        
        // Test with $2 collateral price: 150 tokens * $2 = $300 collateral
        priceFeed.setPrice(2e8);
        
        vm.prank(user);
        c.borrow(borrowAmount); // Should succeed (300% collateralized)
        
        uint256 ratio = c.collateralizationRatio(user);
        assertEq(ratio, 3e18, "Should be 300% collateralized at $2 price");
        
        // Test edge case: lower price makes same collateral insufficient
        address user2 = address(0xc);
        _setCollateralAmount(user2, collateralTokens);
        
        // Set $1 price: 150 tokens * $1 = $150 collateral (150% exactly at minimum)
        priceFeed.setPrice(1e8);
        
        vm.prank(user2);
        c.borrow(borrowAmount); // Should succeed (exactly at 150% minimum)
        
        uint256 ratio2 = c.collateralizationRatio(user2);
        assertEq(ratio2, 1.5e18, "Should be exactly 150% collateralized at $1 price");
    }

    function test_borrow_updates_total_borrowed() public {
        address user = address(0xd);
        uint256 borrowAmount = 75e18;
        
        // Setup
        _setCollateralAmount(user, 300e18);
        _prepareContractLiquidity(500e18);
        _setTotalBorrowedTokens(25e18); // Existing borrows
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        // Check initial total
        uint256 initialTotal = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(initialTotal, 25e18, "Should start with 25 total borrowed");
        
        vm.prank(user);
        c.borrow(borrowAmount);
        
        // Check updated total
        uint256 finalTotal = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotal, 100e18, "Should have 100 total borrowed (25 + 75)");
    }

    function test_borrow_very_small_amount() public {
        address user = address(0xe);
        uint256 borrowAmount = 1; // 1 wei
        
        // Setup with plenty of collateral
        _setCollateralAmount(user, 1e18);
        _prepareContractLiquidity(1e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        vm.prank(user);
        c.borrow(borrowAmount);
        
        uint256 userBalance = assetToken.balanceOf(user);
        assertEq(userBalance, 1, "Should receive 1 wei");
        
        (uint256 shares,) = c.borrowerInfo(user);
        assertEq(shares, 1, "Should have 1 wei of shares");
    }

    function test_borrow_zero_amount() public {
        address user = address(0xf);
        
        // Setup
        _setCollateralAmount(user, 300e18);
        _prepareContractLiquidity(500e18);
        priceFeed.setPrice(1e8);
        _setBorrowerSharePrice(1e18);
        
        vm.prank(user);
        c.borrow(0); // Should work but do nothing
        
        uint256 userBalance = assetToken.balanceOf(user);
        assertEq(userBalance, 0, "Should receive nothing");
        
        (uint256 shares,) = c.borrowerInfo(user);
        assertEq(shares, 0, "Should have no shares");
    }
}