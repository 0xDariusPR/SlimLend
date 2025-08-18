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

    function _giveUserTokens(address user, uint256 amount) internal {
        assetToken.mint(user, amount);
        vm.prank(user);
        assetToken.approve(address(c), amount);
    }

    function test_repay_successful_partial() public {
        address user = address(0x1);
        uint256 debtShares = 200e18; // User owes 200 shares
        uint256 repayAmount = 50e18; // Repay $50
        uint256 expectedSharesBurned = 50e18; // At 1e18 share price = 50 shares

        // Setup: User has debt
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(500e18); // Global debt

        // Setup: Give user tokens to repay
        _giveUserTokens(user, repayAmount);

        // Initial state checks
        uint256 initialUserBalance = assetToken.balanceOf(user);
        uint256 initialContractBalance = assetToken.balanceOf(address(c));
        (uint256 initialShares,) = c.borrowerInfo(user);

        assertEq(initialUserBalance, repayAmount, "User should have repay amount");
        assertEq(initialShares, debtShares, "User should have initial debt");

        // Execute repay
        vm.prank(user);
        c.repay(repayAmount, expectedSharesBurned);

        // Verify token transfer
        uint256 finalUserBalance = assetToken.balanceOf(user);
        uint256 finalContractBalance = assetToken.balanceOf(address(c));

        assertEq(finalUserBalance, 0, "User should have transferred repay amount");
        assertEq(finalContractBalance, initialContractBalance + repayAmount, "Contract should receive tokens");

        // Verify debt accounting
        (uint256 finalShares,) = c.borrowerInfo(user);
        uint256 expectedFinalShares = debtShares - expectedSharesBurned;
        assertEq(finalShares, expectedFinalShares, "User debt shares should decrease correctly");

        // Verify global accounting
        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        uint256 expectedTotalBorrowed = 500e18 - repayAmount;
        assertEq(finalTotalBorrowed, expectedTotalBorrowed, "Global borrowed should decrease");
    }

    function test_repay_event_emission() public {
        address user = address(0x2);
        uint256 repayAmount = 30e18;

        // Setup user with debt and tokens
        _setBorrowerShares(user, 100e18);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(200e18);
        _giveUserTokens(user, repayAmount);

        // Expect Repay event
        vm.expectEmit(true, false, false, true);
        emit SlimLend.Repay(user, repayAmount);

        vm.prank(user);
        c.repay(repayAmount, 30e18);
    }

    function test_repay_exact_debt() public {
        address user = address(0x3);
        uint256 debtShares = 100e18;
        uint256 repayAmount = 100e18; // Exact debt amount at 1e18 share price

        // Setup: User has exact debt
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        _giveUserTokens(user, repayAmount);

        vm.prank(user);
        c.repay(repayAmount, 100e18);

        // Verify debt is completely paid off
        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, 0, "User should have no debt remaining");

        // Verify global accounting
        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 200e18, "Global debt should decrease by repay amount");
    }

    function test_repay_underflow_protection_user_over_repayment() public {
        address user = address(0x4);
        uint256 debtShares = 50e18; // User only owes 50 shares
        uint256 repayAmount = 100e18; // Trying to repay more than owed
        uint256 expectedSharesBurned = 100e18; // At 1e18 share price

        // Setup: User has small debt
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(500e18);
        _giveUserTokens(user, repayAmount);

        // This should NOT revert due to _subFloorZero protection
        vm.prank(user);
        c.repay(repayAmount, expectedSharesBurned);

        // Verify: User debt goes to 0 (floored), not underflow
        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, 0, "User debt should be floored to 0, not underflow");

        // Verify: Global debt decreases by repay amount
        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 400e18, "Global debt should decrease by full repay amount");

        // Verify: User still paid the full amount (excess is not returned)
        uint256 finalUserBalance = assetToken.balanceOf(user);
        assertEq(finalUserBalance, 0, "User should have paid full amount");
    }

    function test_repay_underflow_protection_global_over_repayment() public {
        address user = address(0x5);
        uint256 debtShares = 200e18;
        uint256 repayAmount = 150e18;
        uint256 totalBorrowedGlobal = 100e18; // Less than repay amount

        // Setup: Global borrowed is less than repay amount
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(totalBorrowedGlobal);
        _giveUserTokens(user, repayAmount);

        // This should NOT revert due to _subFloorZero protection
        vm.prank(user);
        c.repay(repayAmount, 150e18);

        // Verify: Global debt goes to 0 (floored), not underflow
        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 0, "Global debt should be floored to 0, not underflow");

        // Verify: User debt decreases normally
        (uint256 finalShares,) = c.borrowerInfo(user);
        uint256 expectedFinalShares = debtShares - 150e18;
        assertEq(finalShares, expectedFinalShares, "User debt should decrease normally");
    }

    function test_repay_zero_amount() public {
        address user = address(0x6);
        uint256 debtShares = 100e18;

        // Setup
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(200e18);
        _giveUserTokens(user, 0); // User has no tokens

        // Repay zero amount
        vm.prank(user);
        c.repay(0, 0);

        // Verify nothing changed
        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, debtShares, "Debt should remain unchanged");

        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 200e18, "Global debt should remain unchanged");
    }

    function test_repay_slippage_protection_success() public {
        address user = address(0x7);
        uint256 debtShares = 100e18;
        uint256 repayAmount = 50e18;
        uint256 minSharesBurned = 50e18; // Expect exactly 50 shares at 1e18 price

        // Setup
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        _giveUserTokens(user, repayAmount);

        // Should succeed - gets exactly expected shares
        vm.prank(user);
        c.repay(repayAmount, minSharesBurned);

        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, 50e18, "Should burn exactly 50 shares");
    }

    function test_repay_slippage_protection_failure() public {
        address user = address(0x8);
        uint256 debtShares = 100e18;
        uint256 repayAmount = 50e18;
        uint256 minSharesBurned = 60e18; // Expect 60 shares but will only get 50

        // Setup
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        _giveUserTokens(user, repayAmount);

        // Should fail - not enough shares burned
        vm.prank(user);
        vm.expectRevert(SlimLend.Slippage.selector);
        c.repay(repayAmount, minSharesBurned);
    }

    function test_repay_different_share_prices() public {
        address user = address(0x9);
        uint256 debtShares = 100e18;
        uint256 repayAmount = 100e18;

        // Setup with 2x share price
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(2e18); // Each share worth $2
        _setTotalBorrowedTokens(400e18);
        _giveUserTokens(user, repayAmount);

        // At 2x share price: 100 assets = 50 shares
        uint256 expectedSharesBurned = 50e18;

        vm.prank(user);
        c.repay(repayAmount, expectedSharesBurned);

        (uint256 finalShares,) = c.borrowerInfo(user);
        uint256 expectedFinalShares = debtShares - expectedSharesBurned;
        assertEq(finalShares, expectedFinalShares, "Should burn fewer shares at higher price");
        assertEq(finalShares, 50e18, "Should have 50 shares remaining");
    }

    function test_repay_order_of_operations_token_transfer_first() public {
        address user = address(0xa);
        uint256 debtShares = 100e18;
        uint256 repayAmount = 50e18;

        // Setup: User has debt but NO tokens (to test order of operations)
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);
        // Intentionally NOT giving user tokens

        // Critical test: Token transfer happens FIRST
        // If accounting happened first, we might update state before transfer fails
        vm.prank(user);
        vm.expectRevert(); // Should fail on token transfer (ERC20: insufficient balance)
        c.repay(repayAmount, 50e18);

        // Verify: No state changes occurred (because transfer failed first)
        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, debtShares, "Debt should remain unchanged after failed transfer");

        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 300e18, "Global debt should remain unchanged after failed transfer");
    }

    function test_repay_order_of_operations_critical_sequence() public {
        address user = address(0xb);
        uint256 debtShares = 100e18;
        uint256 repayAmount = 80e18;

        // Setup
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(300e18);

        // Give user EXACT amount needed (tests precision)
        _giveUserTokens(user, repayAmount);

        // Get initial state
        uint256 initialUserBalance = assetToken.balanceOf(user);
        uint256 initialContractBalance = assetToken.balanceOf(address(c));

        vm.prank(user);
        c.repay(repayAmount, 80e18);

        // Verify order was: transfer -> global update -> share calc -> user update
        // If order was wrong, one of these would be inconsistent

        // 1. Token transfer completed
        assertEq(assetToken.balanceOf(user), initialUserBalance - repayAmount, "User tokens transferred");
        assertEq(assetToken.balanceOf(address(c)), initialContractBalance + repayAmount, "Contract received tokens");

        // 2. Global accounting updated
        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 220e18, "Global debt updated correctly");

        // 3. User debt updated
        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, 20e18, "User debt updated correctly");
    }

    function test_repay_multiple_repayments() public {
        address user = address(0xc);
        uint256 initialDebtShares = 150e18;
        uint256 firstRepay = 40e18;
        uint256 secondRepay = 60e18;

        // Setup
        _setBorrowerShares(user, initialDebtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(500e18);
        _giveUserTokens(user, firstRepay + secondRepay);

        // First repayment
        vm.prank(user);
        c.repay(firstRepay, 40e18);

        (uint256 sharesAfterFirst,) = c.borrowerInfo(user);
        assertEq(sharesAfterFirst, 110e18, "Should have 110 shares after first repay");

        uint256 totalAfterFirst = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(totalAfterFirst, 460e18, "Global debt should decrease by first repay");

        // Second repayment
        vm.prank(user);
        c.repay(secondRepay, 60e18);

        (uint256 sharesAfterSecond,) = c.borrowerInfo(user);
        assertEq(sharesAfterSecond, 50e18, "Should have 50 shares after second repay");

        uint256 totalAfterSecond = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(totalAfterSecond, 400e18, "Global debt should decrease by both repays");
    }

    function test_repay_user_with_no_debt() public {
        address user = address(0xd);
        uint256 repayAmount = 50e18;

        // Setup: User has NO debt
        _setBorrowerShares(user, 0);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(100e18);
        _giveUserTokens(user, repayAmount);

        // Should not revert (underflow protection handles this)
        vm.prank(user);
        c.repay(repayAmount, 50e18);

        // Verify: User still has no debt
        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, 0, "User should still have no debt");

        // Verify: Global debt decreases anyway (user paid into protocol)
        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 50e18, "Global debt should decrease");
    }

    function test_repay_precision_edge_case() public {
        address user = address(0xe);
        uint256 debtShares = 1000000000000000001; // Slightly more than 1 ether in wei
        uint256 repayAmount = 1e18; // Exactly 1 ether

        // Setup
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(2e18);
        _giveUserTokens(user, repayAmount);

        // At 1e18 share price: 1e18 assets = 1e18 shares
        vm.prank(user);
        c.repay(repayAmount, 1e18);

        (uint256 finalShares,) = c.borrowerInfo(user);
        uint256 expectedFinalShares = debtShares - 1e18;
        assertEq(finalShares, expectedFinalShares, "Should handle precision correctly");
        assertEq(finalShares, 1, "Should have 1 wei of debt remaining");
    }

    function test_repay_very_small_amounts() public {
        address user = address(0xf);
        uint256 debtShares = 1000; // 1000 wei
        uint256 repayAmount = 500; // 500 wei

        // Setup
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(2000);
        _giveUserTokens(user, repayAmount);

        vm.prank(user);
        c.repay(repayAmount, 500);

        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, 500, "Should have 500 wei debt remaining");

        uint256 finalTotalBorrowed = uint256(vm.load(address(c), TOTAL_BORROWED_TOKENS_SLOT));
        assertEq(finalTotalBorrowed, 1500, "Global debt should decrease by 500 wei");
    }

    function test_repay_insufficient_allowance() public {
        address user = address(0x10);
        uint256 debtShares = 100e18;
        uint256 repayAmount = 50e18;

        // Setup: User has tokens but insufficient allowance
        _setBorrowerShares(user, debtShares);
        _setBorrowerSharePrice(1e18);
        _setTotalBorrowedTokens(200e18);
        
        assetToken.mint(user, repayAmount);
        // Intentionally NOT approving tokens

        vm.prank(user);
        vm.expectRevert(); // Should fail on transferFrom due to insufficient allowance
        c.repay(repayAmount, 50e18);

        // Verify no state changes
        (uint256 finalShares,) = c.borrowerInfo(user);
        assertEq(finalShares, debtShares, "Debt should remain unchanged");
    }
}