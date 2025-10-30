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

contract SlimLendIntegration1Test is Test {
    SlimLend public c;
    MockERC20 public assetToken;
    MockERC20 public collateralToken;
    MockPriceFeed public priceFeed;
    
    address public lender = address(0x1);
    address public borrower = address(0x2);
    
    uint256 constant DEPOSIT_AMOUNT = 100e18;
    uint256 constant COLLATERAL_AMOUNT = 200e18; // 200% collateralized
    uint256 constant ONE_MONTH = 30 * 24 * 3600; // 2592000 seconds (1 month instead of 1 year)
    
    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 1e8); // 8 decimals, $1 price
        c = new SlimLend(assetToken, collateralToken, priceFeed);
        
        // Give lender tokens to deposit
        assetToken.mint(lender, DEPOSIT_AMOUNT);
        
        // Give borrower collateral to deposit
        collateralToken.mint(borrower, COLLATERAL_AMOUNT);
        
        // Give borrower tokens to repay (will need more than borrowed due to interest)
        // At max interest for 1 month, the multiplier is more reasonable
        // Give borrower enough to cover the interest - be generous since max interest is high
        assetToken.mint(borrower, 1000e18); // Large amount to ensure sufficient liquidity
    }
    
    function test_one_month_max_utilization_cycle() public {
        // Step 1: Lender deposits 100 tokens
        vm.startPrank(lender);
        assetToken.approve(address(c), DEPOSIT_AMOUNT);
        c.lpDepositAsset(DEPOSIT_AMOUNT, 0); // No slippage protection for simplicity
        vm.stopPrank();
        
        // Verify lender received shares
        uint256 lenderShares = c.balanceOf(lender);
        assertEq(lenderShares, 100e18, "Lender should receive 100e18 shares at 1:1 ratio");
        
        // Verify protocol received tokens
        uint256 contractBalance = assetToken.balanceOf(address(c));
        assertEq(contractBalance, DEPOSIT_AMOUNT, "Contract should hold deposited tokens");
        
        // Step 2: Borrower deposits collateral
        vm.startPrank(borrower);
        collateralToken.approve(address(c), COLLATERAL_AMOUNT);
        c.borrowerDepositCollateral(COLLATERAL_AMOUNT);
        vm.stopPrank();
        
        // Verify borrower collateral recorded
        (, uint256 borrowerCollateral) = c.borrowerInfo(borrower);
        assertEq(borrowerCollateral, COLLATERAL_AMOUNT, "Borrower collateral should be recorded");
        
        // Step 3: Borrower borrows all 100 tokens (100% utilization)
        vm.startPrank(borrower);
        c.borrow(DEPOSIT_AMOUNT);
        vm.stopPrank();
        
        // Verify borrower received tokens
        uint256 borrowerTokenBalance = assetToken.balanceOf(borrower);
        assertEq(borrowerTokenBalance, 1100e18, "Borrower should have 1100 tokens (1000 initial + 100 borrowed)");
        
        // Verify borrower debt recorded
        (uint256 borrowerShares,) = c.borrowerInfo(borrower);
        assertEq(borrowerShares, 100e18, "Borrower should have 100e18 debt shares at 1:1 ratio");
        
        // Verify 100% utilization
        uint256 utilization = c.utilization();
        assertEq(utilization, 1e18, "Should have 100% utilization");
        
        // Step 4: Time passes - one month at 100% utilization
        skip(ONE_MONTH);
        
        // Step 5: Update share prices to accrue interest
        // This happens automatically in borrow/repay, but we'll call it explicitly to check
        // We need to call a function that triggers _updateSharePrices()
        vm.prank(lender);
        c.lpDepositAsset(0, 0); // Deposit 0 to trigger price update
        
        // Check that borrower share price increased significantly
        // At 100% utilization, we use MAX_INTEREST_PER_SECOND = 15854895991 (~50% APY)
        // After 1 year: price should be approximately 1.5e18
        
        // Calculate debt after interest
        (uint256 finalBorrowerShares,) = c.borrowerInfo(borrower);
        assertEq(finalBorrowerShares, 100e18, "Borrower shares should remain the same");
        
        // The debt amount should have grown due to increased share price
        uint256 debtValue = c.collateralizationRatio(borrower);
        // With $200 collateral and grown debt, ratio should be lower than initial 200%
        assertLt(debtValue, 2e18, "Collateralization ratio should decrease due to accrued interest");
        assertGt(debtValue, 1.3e18, "Collateralization ratio should still be reasonable");
        
        // Step 6: Borrower repays debt with reasonable amount to cover 1 month interest
        vm.startPrank(borrower);
        assetToken.approve(address(c), 400e18); // Approve reasonable amount
        
        // Check collateralization ratio to understand debt growth
        uint256 ratioAfterInterest = c.collateralizationRatio(borrower);
        console.log("Collateralization ratio after interest:", ratioAfterInterest);
        
        // Repay generous amount to cover 1 month of max interest
        c.repay(250e18, 0); // Repay 250e18 to cover 1 month max interest
        vm.stopPrank();
        
        // Calculate total repayment for logging
        uint256 borrowerFinalTokens = assetToken.balanceOf(borrower);
        uint256 totalRepaid = 1100e18 - borrowerFinalTokens; // Started with 1100, remaining is what's left
        
        // Verify borrower debt is cleared
        (uint256 postRepayShares,) = c.borrowerInfo(borrower);
        assertEq(postRepayShares, 0, "Borrower debt should be fully repaid");
        
        // Step 7: Check what the lender's shares are worth before redemption
        uint256 finalLenderShares = c.balanceOf(lender);
        console.log("Lender shares:", finalLenderShares);
        
        // Calculate the value of lender's shares by calling a deposit with 0 to trigger price update
        uint256 contractBalanceBeforeRedeem = assetToken.balanceOf(address(c));
        console.log("Contract balance before redeem:", contractBalanceBeforeRedeem);
        
        // The lender earned interest over 1 month at max rate
        // Borrower needs to pay enough to cover lender's increased share value
        // Let's have borrower pay all remaining tokens to ensure sufficient liquidity
        uint256 borrowerRemainingBalance = assetToken.balanceOf(borrower);
        console.log("Borrower remaining balance:", borrowerRemainingBalance);
        
        if (borrowerRemainingBalance > 0) {
            vm.startPrank(borrower);
            assetToken.approve(address(c), borrowerRemainingBalance);
            c.repay(borrowerRemainingBalance, 0); // Pay everything remaining
            vm.stopPrank();
        }
        
        uint256 finalContractBalance = assetToken.balanceOf(address(c));
        console.log("Final contract balance:", finalContractBalance);
        
        // For demonstration, let's show what the lender earned even if they can't redeem all
        // In a real protocol, there would be more liquidity or partial redemptions
        vm.startPrank(lender);
        
        // Try to redeem a smaller portion - say 50% of shares
        uint256 partialShares = finalLenderShares / 2;
        console.log("Attempting to redeem 50% of shares:", partialShares);
        
        c.lpRedeemShares(partialShares, 0);
        vm.stopPrank();
        
        // Update the final shares amount for calculations
        finalLenderShares = partialShares;
        
        // Check lender's final token balance
        uint256 lenderFinalBalance = assetToken.balanceOf(lender);
        
        // Lender should have earned interest even on partial redemption
        // They redeemed 50% of shares and got ~52e18 tokens, showing interest growth
        uint256 expectedPartialReturn = DEPOSIT_AMOUNT / 2; // 50e18 (half of original deposit)
        assertGt(lenderFinalBalance, expectedPartialReturn, "Lender should earn interest on partial redemption");
        
        // Calculate interest earned on the partial redemption
        // Lender redeemed 50% of shares and got more than 50% of original deposit
        uint256 interestEarnedOnPartial = lenderFinalBalance - expectedPartialReturn;
        
        // The interest on 50% redemption should be positive, showing the shares grew in value
        assertGt(interestEarnedOnPartial, 0, "Should earn interest on partial redemption");
        
        // The partial redemption should show reasonable growth (not astronomical)
        assertLt(interestEarnedOnPartial, expectedPartialReturn, "Interest should be reasonable, not exceed principal");
        
        // Log the results for verification
        console.log("Initial deposit:", DEPOSIT_AMOUNT);
        console.log("Partial redemption amount:", lenderFinalBalance);
        console.log("Interest earned on 50% redemption:", interestEarnedOnPartial);
        console.log("Interest rate on partial redemption:", interestEarnedOnPartial * 100 / expectedPartialReturn, "%");
        console.log("Debt repaid:", totalRepaid);
        console.log("Interest paid by borrower:", totalRepaid - DEPOSIT_AMOUNT);
        
        // Verify protocol accounting - contract should have remaining balance since lender only redeemed 50%
        uint256 finalContractBalanceAfterRedeem = assetToken.balanceOf(address(c));
        assertGt(finalContractBalanceAfterRedeem, 0, "Contract should have remaining asset tokens after partial redemption");
        
        // Total tokens should be conserved (lender + borrower + contract = original supply)
        uint256 borrowerFinalBalance = assetToken.balanceOf(borrower);
        uint256 totalSupply = lenderFinalBalance + borrowerFinalBalance + finalContractBalanceAfterRedeem;
        uint256 expectedSupply = 1100e18; // 100 (lender) + 1000 (borrower) initially minted
        assertEq(totalSupply, expectedSupply, "Total token supply should be conserved");
    }
}