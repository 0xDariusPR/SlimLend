// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SlimLend, IPriceFeed} from "../src/SlimLend.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
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
    constructor(IERC20 _assetToken, IERC20 _collateralToken, MockPriceFeed _priceFeed) 
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

    bytes32 constant TOTAL_DEPOSITED_TOKENS_SLOT = bytes32(uint256(5));
    bytes32 constant TOTAL_BORROWED_TOKENS_SLOT = bytes32(uint256(6));
    bytes32 constant LP_SHARE_PRICE_SLOT = bytes32(uint256(7));
    bytes32 constant BORROWER_SHARE_PRICE_SLOT = bytes32(uint256(8));
    bytes32 constant LAST_UPDATE_TIME_SLOT = bytes32(uint256(9));

    function test_update_share_prices_initial() public {
        c.updateSharePrices();
        uint256 lpPrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        uint256 borrowerPrice = uint256(vm.load(address(c), BORROWER_SHARE_PRICE_SLOT));
        
        assertEq(lpPrice, 1e18); 
        assertEq(borrowerPrice, 1e18); 
    }

    function test_last_update_updated() public {
        c.updateSharePrices();
        uint256 timeBefore = uint256(vm.load(address(c), LAST_UPDATE_TIME_SLOT)); 
        skip(100);

        c.updateSharePrices();
        uint256 timeAfter = uint256(vm.load(address(c), LAST_UPDATE_TIME_SLOT));
        assertEq(timeAfter - timeBefore, 100);
    }

    function test_share_price_accrual_with_utilization() public {
        // Setup: Create 100% utilization (all deposited tokens are borrowed)
        uint256 deposited = 1000e18;
        uint256 borrowed = 1000e18;
        
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(uint256(deposited)));
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(uint256(borrowed)));
        
        // Initial share prices
        uint256 initialLpPrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        uint256 initialBorrowerPrice = uint256(vm.load(address(c), BORROWER_SHARE_PRICE_SLOT));
        
        // Verify initial state
        assertEq(initialLpPrice, 1e18, "LP price should start at 1e18");
        assertEq(initialBorrowerPrice, 1e18, "Borrower price should start at 1e18");
        
        // Skip time forward by 1 year (365 * 24 * 3600 = 31536000 seconds)
        uint256 timeElapsed = 31536000;
        skip(timeElapsed);
        
        c.updateSharePrices();
        
        uint256 finalLpPrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        uint256 finalBorrowerPrice = uint256(vm.load(address(c), BORROWER_SHARE_PRICE_SLOT));
        
        // At 100% utilization, we use the MAX_INTEREST_PER_SECOND rate
        // MAX_INTEREST_PER_SECOND = 15854895991 (approximately 50% APY)
        // After 1 year, borrower price should be approximately 1.5e18 (50% higher)
        // LP price should also increase but less (due to utilization factor)
        
        // These bounds ensure the division by 1e18 is working
        // Without division: prices would be astronomical (> 1e28)
        // With division: prices should be reasonable (around 1.1-1.6e18 range)
        assertGt(finalBorrowerPrice, 1.4e18, "Borrower price should increase significantly over 1 year");
        assertLt(finalBorrowerPrice, 1.6e18, "Borrower price should not be astronomical");
        
        assertGt(finalLpPrice, 1.4e18, "LP price should increase over 1 year"); 
        assertLt(finalLpPrice, 1.6e18, "LP price should not be astronomical");
        
        // Borrower rate should be higher than LP rate at 100% utilization
        assertGe(finalBorrowerPrice, finalLpPrice, "Borrower rate should be >= LP rate");
    }
    
    function test_share_price_accrual_catches_missing_division_bug() public {
        // This test specifically catches the missing /1e18 division bug
        // Setup minimal utilization to get predictable rates
        uint256 deposited = 1000e18;
        uint256 borrowed = 950e18; // 95% utilization (at OPTIMAL_UTILIZATION)
        
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(uint256(deposited)));
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(uint256(borrowed)));
        
        // Skip just 1 second to make the calculation simple
        skip(1);
        
        c.updateSharePrices();
        
        uint256 finalBorrowerPrice = uint256(vm.load(address(c), BORROWER_SHARE_PRICE_SLOT));
        
        // At 95% utilization, borrower rate = KINK_INTEREST_PER_SECOND = 1585489599
        // After 1 second with correct division: 1e18 + (1e18 * 1585489599 * 1) / 1e18 = ~1.001585e18
        // After 1 second WITHOUT division: 1e18 + (1e18 * 1585489599 * 1) = ~1.585e27 (astronomical!)
        
        // This assertion would fail without the /1e18 division
        assertLt(finalBorrowerPrice, 1.01e18, "Borrower price should increase modestly after 1 second");
        assertGt(finalBorrowerPrice, 1e18, "Borrower price should increase");
        
        // More specifically, it should be very close to the expected value
        uint256 expectedIncrease = 1e18 * 1585489599 / 1e18; // ≈ 1.585e9 wei
        uint256 expectedPrice = 1e18 + expectedIncrease;
        
        // Allow some tolerance for calculation precision
        assertApproxEqRel(finalBorrowerPrice, expectedPrice, 0.001e18, "Price should match expected calculation");
    }
    
    function test_share_price_no_time_elapsed() public {
        // Setup some utilization
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(uint256(1000e18)));
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(uint256(500e18)));
        
        // Don't skip time - same block
        c.updateSharePrices();
        
        uint256 lpPrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        uint256 borrowerPrice = uint256(vm.load(address(c), BORROWER_SHARE_PRICE_SLOT));
        
        // Prices should remain unchanged when no time elapsed
        assertEq(lpPrice, 1e18, "LP price should be unchanged with no time elapsed");
        assertEq(borrowerPrice, 1e18, "Borrower price should be unchanged with no time elapsed");
    }
    
    function test_share_price_zero_utilization() public {
        // Setup: deposits but no borrows (0% utilization)
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(uint256(1000e18)));
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(uint256(0)));
        
        skip(31536000); // 1 year
        
        c.updateSharePrices();
        
        uint256 lpPrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        uint256 borrowerPrice = uint256(vm.load(address(c), BORROWER_SHARE_PRICE_SLOT));
        
        // At 0% utilization, both rates should be 0, so prices unchanged
        assertEq(lpPrice, 1e18, "LP price should be unchanged at 0% utilization");
        assertEq(borrowerPrice, 1e18, "Borrower price should be unchanged at 0% utilization");
    }
}
