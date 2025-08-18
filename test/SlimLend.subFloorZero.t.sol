// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SlimLend, IPriceFeed} from "../src/SlimLend.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
}

contract MockPriceFeed is IPriceFeed {
    uint8 public decimals = 8;
    int256 public price = 1e8;
    
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

// Test contract that exposes the internal _subFloorZero function
contract TestableSlimLend is SlimLend {
    constructor(MockERC20 _assetToken, MockERC20 _collateralToken, MockPriceFeed _priceFeed) 
        SlimLend(_assetToken, _collateralToken, _priceFeed) {}
    
    // Expose the internal function for testing
    function subFloorZero(uint256 x, uint256 y) external pure returns (uint256) {
        return _subFloorZero(x, y);
    }
}

contract SubFloorZeroTest is Test {
    TestableSlimLend public c;
    MockERC20 public assetToken;
    MockERC20 public collateralToken;
    MockPriceFeed public priceFeed;

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed();
        c = new TestableSlimLend(assetToken, collateralToken, priceFeed);
    }

    function test_subFloorZero_normal_subtraction() public {
        // Normal case: x > y
        uint256 result = c.subFloorZero(100, 30);
        assertEq(result, 70, "100 - 30 should equal 70");
        
        result = c.subFloorZero(1000, 250);
        assertEq(result, 750, "1000 - 250 should equal 750");
        
        result = c.subFloorZero(1e18, 0.5e18);
        assertEq(result, 0.5e18, "1e18 - 0.5e18 should equal 0.5e18");
    }

    function test_subFloorZero_equal_values() public {
        // Edge case: x == y
        uint256 result = c.subFloorZero(100, 100);
        assertEq(result, 0, "100 - 100 should equal 0");
        
        result = c.subFloorZero(1e18, 1e18);
        assertEq(result, 0, "1e18 - 1e18 should equal 0");
        
        result = c.subFloorZero(0, 0);
        assertEq(result, 0, "0 - 0 should equal 0");
    }

    function test_subFloorZero_underflow_protection() public {
        // Critical case: x < y (would normally underflow)
        uint256 result = c.subFloorZero(50, 100);
        assertEq(result, 0, "50 - 100 should floor to 0 (not underflow)");
        
        result = c.subFloorZero(1, 1000);
        assertEq(result, 0, "1 - 1000 should floor to 0");
        
        result = c.subFloorZero(0.5e18, 1e18);
        assertEq(result, 0, "0.5e18 - 1e18 should floor to 0");
        
        result = c.subFloorZero(0, 100);
        assertEq(result, 0, "0 - 100 should floor to 0");
    }

    function test_subFloorZero_large_numbers() public {
        // Test with large numbers
        uint256 large1 = type(uint256).max;
        uint256 large2 = type(uint256).max - 1000;
        
        uint256 result = c.subFloorZero(large1, large2);
        assertEq(result, 1000, "max - (max-1000) should equal 1000");
        
        result = c.subFloorZero(large2, large1);
        assertEq(result, 0, "(max-1000) - max should floor to 0");
        
        result = c.subFloorZero(large1, large1);
        assertEq(result, 0, "max - max should equal 0");
    }

    function test_subFloorZero_edge_cases() public {
        // Test with very small numbers
        uint256 result = c.subFloorZero(2, 1);
        assertEq(result, 1, "2 - 1 should equal 1");
        
        result = c.subFloorZero(1, 2);
        assertEq(result, 0, "1 - 2 should floor to 0");
        
        result = c.subFloorZero(1, 1);
        assertEq(result, 0, "1 - 1 should equal 0");
        
        // Test with one zero
        result = c.subFloorZero(100, 0);
        assertEq(result, 100, "100 - 0 should equal 100");
        
        result = c.subFloorZero(0, 50);
        assertEq(result, 0, "0 - 50 should floor to 0");
    }

    function test_subFloorZero_precision_decimals() public {
        // Test with 18-decimal precision numbers
        uint256 x = 123.456789e18; // 123.456789 tokens
        uint256 y = 23.456789e18;  // 23.456789 tokens
        
        uint256 result = c.subFloorZero(x, y);
        uint256 expected = 100e18; // 100.0 tokens exactly
        assertEq(result, expected, "Should handle decimal precision correctly");
        
        // Test near-zero differences
        x = 1.000000000000000001e18;
        y = 1e18;
        result = c.subFloorZero(x, y);
        assertEq(result, 1, "Should handle tiny differences correctly");
        
        // Test reverse (underflow case)
        result = c.subFloorZero(y, x);
        assertEq(result, 0, "Reverse should floor to 0");
    }

    function test_subFloorZero_boundary_conditions() public {
        // Test at uint256 boundaries
        uint256 maxUint = type(uint256).max;
        uint256 result;
        
        // Max minus small number
        result = c.subFloorZero(maxUint, 1);
        assertEq(result, maxUint - 1, "max - 1 should work correctly");
        
        // Max minus itself
        result = c.subFloorZero(maxUint, maxUint);
        assertEq(result, 0, "max - max should equal 0");
        
        // Small number minus max (underflow protection)
        result = c.subFloorZero(1, maxUint);
        assertEq(result, 0, "1 - max should floor to 0");
        
        // Zero minus max
        result = c.subFloorZero(0, maxUint);
        assertEq(result, 0, "0 - max should floor to 0");
    }

    function test_subFloorZero_real_world_scenarios() public {
        // Scenario 1: User debt repayment (normal case)
        uint256 userDebt = 1000e18; // $1000 debt
        uint256 repayAmount = 300e18; // $300 repayment
        
        uint256 result = c.subFloorZero(userDebt, repayAmount);
        assertEq(result, 700e18, "Should have $700 debt remaining");
        
        // Scenario 2: User over-repayment (underflow protection)
        repayAmount = 1500e18; // $1500 repayment (more than debt)
        result = c.subFloorZero(userDebt, repayAmount);
        assertEq(result, 0, "Over-repayment should result in 0 debt");
        
        // Scenario 3: Exact repayment
        repayAmount = 1000e18; // Exact debt amount
        result = c.subFloorZero(userDebt, repayAmount);
        assertEq(result, 0, "Exact repayment should result in 0 debt");
        
        // Scenario 4: Global borrowed tokens update
        uint256 totalBorrowed = 5000e18;
        uint256 singleRepayment = 2000e18;
        result = c.subFloorZero(totalBorrowed, singleRepayment);
        assertEq(result, 3000e18, "Global debt should decrease correctly");
        
        // Scenario 5: Last borrower repaying more than total (edge case)
        totalBorrowed = 100e18;
        singleRepayment = 150e18; // More than total borrowed
        result = c.subFloorZero(totalBorrowed, singleRepayment);
        assertEq(result, 0, "Total borrowed should floor to 0, not underflow");
    }

    function test_subFloorZero_gas_efficiency() public {
        // Test that function is gas efficient for common cases
        uint256 gasBefore = gasleft();
        c.subFloorZero(1000e18, 500e18);
        uint256 gasUsed = gasBefore - gasleft();
        
        // Should be very efficient (just a conditional and subtraction)
        assertTrue(gasUsed < 10000, "Function should be gas efficient");
        
        // Test efficiency for underflow case too
        gasBefore = gasleft();
        c.subFloorZero(500e18, 1000e18);
        gasUsed = gasBefore - gasleft();
        
        assertTrue(gasUsed < 10000, "Underflow case should also be gas efficient");
    }

    // Fuzz testing to catch edge cases
    function testFuzz_subFloorZero(uint256 x, uint256 y) public {
        uint256 result = c.subFloorZero(x, y);
        
        if (x >= y) {
            assertEq(result, x - y, "When x >= y, should return x - y");
        } else {
            assertEq(result, 0, "When x < y, should return 0");
        }
        
        // Result should never be greater than x
        assertLe(result, x, "Result should never exceed x");
    }
}