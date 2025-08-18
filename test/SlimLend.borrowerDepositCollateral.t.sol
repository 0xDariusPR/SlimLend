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
}

contract ESlimLend is SlimLend {
    constructor(MockERC20 _assetToken, MockERC20 _collateralToken, MockPriceFeed _priceFeed) 
        SlimLend(_assetToken, _collateralToken, _priceFeed) {}
    
    function updateSharePrices() external {
        _updateSharePrices();
    }
}

contract SlimLendTest is Test {
    ESlimLend public c;
    MockERC20 public assetToken;
    MockERC20 public collateralToken;
    MockPriceFeed public priceFeed;

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 2000e8); // 8 decimals, $2000 price
        c = new ESlimLend(assetToken, collateralToken, priceFeed);
    }

    function _mintCollateralAndApprove(address user, uint256 amount) internal {
        collateralToken.mint(user, amount);
        vm.prank(user);
        collateralToken.approve(address(c), amount);
    }

    function test_deposit_collateral_basic() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x1);
        
        // Setup user with collateral tokens
        _mintCollateralAndApprove(user, depositAmount);
        
        // Check initial state
        uint256 initialUserBalance = collateralToken.balanceOf(user);
        uint256 initialContractBalance = collateralToken.balanceOf(address(c));
        (uint256 initialBorrowerShares, uint256 initialCollateralAmount) = c.borrowerInfo(user);
        
        assertEq(initialUserBalance, depositAmount, "User should have collateral tokens");
        assertEq(initialContractBalance, 0, "Contract should start with no collateral");
        assertEq(initialBorrowerShares, 0, "Initial borrower shares should be 0");
        assertEq(initialCollateralAmount, 0, "Initial collateral amount should be 0");
        
        // Deposit collateral
        vm.prank(user);
        c.borrowerDepositCollateral(depositAmount);
        
        // Verify token balances changed correctly
        uint256 finalUserBalance = collateralToken.balanceOf(user);
        uint256 finalContractBalance = collateralToken.balanceOf(address(c));
        
        assertEq(finalUserBalance, 0, "User tokens should be transferred to contract");
        assertEq(finalContractBalance, depositAmount, "Contract should receive all tokens");
        
        // Verify borrowerInfo updated correctly
        (uint256 finalBorrowerShares, uint256 finalCollateralAmount) = c.borrowerInfo(user);
        assertEq(finalBorrowerShares, 0, "Borrower shares should remain 0");
        assertEq(finalCollateralAmount, depositAmount, "Collateral amount should equal deposit");
    }

    function test_deposit_collateral_multiple_deposits() public {
        uint256 firstDeposit = 500e18;
        uint256 secondDeposit = 300e18;
        uint256 totalDeposit = firstDeposit + secondDeposit;
        address user = address(0x2);
        
        // Setup user with enough collateral tokens
        _mintCollateralAndApprove(user, totalDeposit);
        
        // First deposit
        vm.prank(user);
        c.borrowerDepositCollateral(firstDeposit);
        
        // Verify state after first deposit
        (uint256 sharesAfterFirst, uint256 collateralAfterFirst) = c.borrowerInfo(user);
        assertEq(sharesAfterFirst, 0, "Borrower shares should be 0 after first deposit");
        assertEq(collateralAfterFirst, firstDeposit, "Collateral should equal first deposit");
        
        uint256 contractBalanceAfterFirst = collateralToken.balanceOf(address(c));
        assertEq(contractBalanceAfterFirst, firstDeposit, "Contract balance should equal first deposit");
        
        // Second deposit
        vm.prank(user);
        c.borrowerDepositCollateral(secondDeposit);
        
        // Verify state after second deposit (should accumulate)
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalShares, 0, "Borrower shares should remain 0");
        assertEq(finalCollateral, totalDeposit, "Collateral should be sum of both deposits");
        
        uint256 finalContractBalance = collateralToken.balanceOf(address(c));
        assertEq(finalContractBalance, totalDeposit, "Contract balance should be sum of both deposits");
        
        // Verify user has no tokens left
        uint256 finalUserBalance = collateralToken.balanceOf(user);
        assertEq(finalUserBalance, 0, "User should have no tokens left");
    }

    function test_deposit_collateral_multiple_users() public {
        uint256 depositAmount1 = 1000e18;
        uint256 depositAmount2 = 750e18;
        address user1 = address(0x3);
        address user2 = address(0x4);
        
        // Setup both users with collateral tokens
        _mintCollateralAndApprove(user1, depositAmount1);
        _mintCollateralAndApprove(user2, depositAmount2);
        
        // User1 deposits
        vm.prank(user1);
        c.borrowerDepositCollateral(depositAmount1);
        
        // User2 deposits
        vm.prank(user2);
        c.borrowerDepositCollateral(depositAmount2);
        
        // Verify each user's borrowerInfo is independent
        (uint256 user1Shares, uint256 user1Collateral) = c.borrowerInfo(user1);
        (uint256 user2Shares, uint256 user2Collateral) = c.borrowerInfo(user2);
        
        assertEq(user1Shares, 0, "User1 borrower shares should be 0");
        assertEq(user1Collateral, depositAmount1, "User1 collateral should equal their deposit");
        
        assertEq(user2Shares, 0, "User2 borrower shares should be 0");
        assertEq(user2Collateral, depositAmount2, "User2 collateral should equal their deposit");
        
        // Verify total contract balance
        uint256 contractBalance = collateralToken.balanceOf(address(c));
        assertEq(contractBalance, depositAmount1 + depositAmount2, "Contract should have total of both deposits");
        
        // Verify users have no tokens left
        assertEq(collateralToken.balanceOf(user1), 0, "User1 should have no tokens left");
        assertEq(collateralToken.balanceOf(user2), 0, "User2 should have no tokens left");
    }

    function test_deposit_collateral_emit_event() public {
        uint256 depositAmount = 500e18;
        address user = address(0x5);
        
        // Setup user with collateral tokens
        _mintCollateralAndApprove(user, depositAmount);
        
        // Expect the DepositCollateral event to be emitted with correct parameters
        vm.expectEmit(true, false, false, true);
        emit SlimLend.DepositCollateral(user, depositAmount);
        
        vm.prank(user);
        c.borrowerDepositCollateral(depositAmount);
    }

    function test_deposit_collateral_zero_amount() public {
        address user = address(0x6);
        
        // Setup user with some collateral tokens (but will deposit 0)
        _mintCollateralAndApprove(user, 1000e18);
        
        // Get initial state
        (uint256 initialShares, uint256 initialCollateral) = c.borrowerInfo(user);
        uint256 initialContractBalance = collateralToken.balanceOf(address(c));
        uint256 initialUserBalance = collateralToken.balanceOf(user);
        
        // Deposit zero amount
        vm.prank(user);
        c.borrowerDepositCollateral(0);
        
        // Verify nothing changed
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        uint256 finalContractBalance = collateralToken.balanceOf(address(c));
        uint256 finalUserBalance = collateralToken.balanceOf(user);
        
        assertEq(finalShares, initialShares, "Borrower shares should not change");
        assertEq(finalCollateral, initialCollateral, "Collateral amount should not change");
        assertEq(finalContractBalance, initialContractBalance, "Contract balance should not change");
        assertEq(finalUserBalance, initialUserBalance, "User balance should not change");
    }

    function test_deposit_collateral_very_small_amount() public {
        uint256 depositAmount = 1; // 1 wei
        address user = address(0x7);
        
        // Setup user with minimal collateral tokens
        _mintCollateralAndApprove(user, depositAmount);
        
        // Deposit 1 wei
        vm.prank(user);
        c.borrowerDepositCollateral(depositAmount);
        
        // Verify state
        (uint256 shares, uint256 collateral) = c.borrowerInfo(user);
        assertEq(shares, 0, "Borrower shares should be 0");
        assertEq(collateral, 1, "Collateral should be 1 wei");
        
        uint256 contractBalance = collateralToken.balanceOf(address(c));
        assertEq(contractBalance, 1, "Contract should have 1 wei");
        
        uint256 userBalance = collateralToken.balanceOf(user);
        assertEq(userBalance, 0, "User should have 0 tokens left");
    }

    function test_deposit_collateral_large_amount() public {
        uint256 depositAmount = type(uint128).max; // Very large but safe amount
        address user = address(0x8);
        
        // Setup user with large amount of collateral tokens
        _mintCollateralAndApprove(user, depositAmount);
        
        // Deposit large amount
        vm.prank(user);
        c.borrowerDepositCollateral(depositAmount);
        
        // Verify state
        (uint256 shares, uint256 collateral) = c.borrowerInfo(user);
        assertEq(shares, 0, "Borrower shares should be 0");
        assertEq(collateral, depositAmount, "Collateral should equal large deposit");
        
        uint256 contractBalance = collateralToken.balanceOf(address(c));
        assertEq(contractBalance, depositAmount, "Contract should have the large amount");
    }

    function test_deposit_collateral_insufficient_balance() public {
        uint256 userBalance = 100e18;
        uint256 depositAmount = 200e18; // More than user has
        address user = address(0x9);
        
        // Setup user with insufficient balance
        _mintCollateralAndApprove(user, userBalance);
        
        // Attempt to deposit more than balance should fail
        vm.prank(user);
        vm.expectRevert(); // Should revert due to insufficient balance
        c.borrowerDepositCollateral(depositAmount);
    }

    function test_deposit_collateral_insufficient_allowance() public {
        uint256 userBalance = 200e18;
        uint256 allowanceAmount = 100e18;
        uint256 depositAmount = 150e18; // More than allowance
        address user = address(0xa);
        
        // Setup user with sufficient balance but insufficient allowance
        collateralToken.mint(user, userBalance);
        vm.prank(user);
        collateralToken.approve(address(c), allowanceAmount); // Less than deposit
        
        // Attempt to deposit more than allowance should fail
        vm.prank(user);
        vm.expectRevert(); // Should revert due to insufficient allowance
        c.borrowerDepositCollateral(depositAmount);
    }

    function test_deposit_collateral_only_affects_collateral_amount() public {
        uint256 depositAmount = 1000e18;
        address user = address(0xb);
        
        // Setup user with collateral tokens
        _mintCollateralAndApprove(user, depositAmount);
        
        // Get initial state - borrower shares should be 0, collateral should be 0
        (uint256 initialShares, uint256 initialCollateral) = c.borrowerInfo(user);
        assertEq(initialShares, 0, "Should start with no borrower shares");
        assertEq(initialCollateral, 0, "Should start with no collateral");
        
        // Deposit collateral
        vm.prank(user);
        c.borrowerDepositCollateral(depositAmount);
        
        // Verify only collateral amount changes, borrower shares remain 0
        (uint256 finalShares, uint256 finalCollateral) = c.borrowerInfo(user);
        assertEq(finalShares, 0, "Borrower shares should remain 0");
        assertEq(finalCollateral, depositAmount, "Collateral should be updated to deposit amount");
        
        // Make another deposit to verify shares still don't change
        _mintCollateralAndApprove(user, depositAmount);
        vm.prank(user);
        c.borrowerDepositCollateral(depositAmount);
        
        (uint256 secondShares, uint256 secondCollateral) = c.borrowerInfo(user);
        assertEq(secondShares, 0, "Borrower shares should still be 0 after second deposit");
        assertEq(secondCollateral, depositAmount * 2, "Collateral should accumulate");
    }

    function test_deposit_collateral_event_multiple_deposits() public {
        uint256 firstDeposit = 300e18;
        uint256 secondDeposit = 200e18;
        address user = address(0xc);
        
        // Setup user with collateral tokens
        _mintCollateralAndApprove(user, firstDeposit + secondDeposit);
        
        // First deposit - expect first event
        vm.expectEmit(true, false, false, true);
        emit SlimLend.DepositCollateral(user, firstDeposit);
        
        vm.prank(user);
        c.borrowerDepositCollateral(firstDeposit);
        
        // Second deposit - expect second event
        vm.expectEmit(true, false, false, true);
        emit SlimLend.DepositCollateral(user, secondDeposit);
        
        vm.prank(user);
        c.borrowerDepositCollateral(secondDeposit);
    }
}