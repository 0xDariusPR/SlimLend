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

    bytes32 constant BORROWER_INFO_SLOT = bytes32(uint256(10));

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 1e8); // 8 decimals, $1 price
        c = new SlimLend(assetToken, collateralToken, priceFeed);
    }

    function _setCollateralAmount(address user, uint256 amount) internal {
        // borrowerInfo mapping storage slot calculation
        // For mapping storage: keccak256(abi.encode(key, slot))
        bytes32 slot = keccak256(abi.encode(user, BORROWER_INFO_SLOT));
        
        // BorrowerInfo struct has borrowerShares at offset 0, collateralTokenAmount at offset 1
        bytes32 collateralSlot = bytes32(uint256(slot) + 1);
        
        vm.store(address(c), collateralSlot, bytes32(amount));
    }

    function test_collateral_value_basic() public {
        address user = address(0x1);
        uint256 collateralAmount = 1e18; // 1 token with 18 decimals
        
        // Set collateral amount directly in storage
        _setCollateralAmount(user, collateralAmount);
        
        // Oracle returns 1e8 (representing $1 with 8 decimals)
        // Expected: collateralValue should be 1e18 (1 token * $1 = $1 in 18 decimals)
        uint256 value = c.collateralValue(user);
        assertEq(value, 1e18, "Collateral value should be 1e18 when price is 1e8 and amount is 1e18");
    }

    function test_collateral_value_different_prices() public {
        address user = address(0x2);
        uint256 collateralAmount = 1e18; // 1 token
        
        _setCollateralAmount(user, collateralAmount);
        
        // Test with $2000 price (2000e8)
        priceFeed.setPrice(2000e8);
        uint256 value = c.collateralValue(user);
        assertEq(value, 2000e18, "Collateral value should be 2000e18 when price is 2000e8");
        
        // Test with $0.50 price (50000000 = 0.5e8)
        priceFeed.setPrice(50000000);
        value = c.collateralValue(user);
        assertEq(value, 0.5e18, "Collateral value should be 0.5e18 when price is 0.5e8");
        
        // Test with very small price (1 = 0.00000001e8)
        priceFeed.setPrice(1);
        value = c.collateralValue(user);
        assertEq(value, 0.00000001e18, "Collateral value should be 0.00000001e18 when price is 1");
    }

    function test_collateral_value_different_amounts() public {
        address user = address(0x3);
        
        // Set price to $1 (1e8)
        priceFeed.setPrice(1e8);
        
        // Test with 5 tokens
        _setCollateralAmount(user, 5e18);
        uint256 value = c.collateralValue(user);
        assertEq(value, 5e18, "5 tokens at $1 should be worth $5");
        
        // Test with 0.1 tokens
        _setCollateralAmount(user, 0.1e18);
        value = c.collateralValue(user);
        assertEq(value, 0.1e18, "0.1 tokens at $1 should be worth $0.1");
        
        // Test with very large amount
        _setCollateralAmount(user, 1000000e18);
        value = c.collateralValue(user);
        assertEq(value, 1000000e18, "1M tokens at $1 should be worth $1M");
    }

    function test_collateral_value_zero_amount() view public {
        address user = address(0x4);
        
        // Don't set any collateral (defaults to 0)
        uint256 value = c.collateralValue(user);
        assertEq(value, 0, "Zero collateral should have zero value");
    }

    function test_collateral_value_multiple_users() public {
        address user1 = address(0x5);
        address user2 = address(0x6);
        
        // Set different amounts for different users
        _setCollateralAmount(user1, 10e18);
        _setCollateralAmount(user2, 3e18);
        
        // Set price to $100
        priceFeed.setPrice(100e8);
        
        uint256 value1 = c.collateralValue(user1);
        uint256 value2 = c.collateralValue(user2);
        
        assertEq(value1, 1000e18, "User1: 10 tokens at $100 should be worth $1000");
        assertEq(value2, 300e18, "User2: 3 tokens at $100 should be worth $300");
    }

    function test_collateral_value_precision() public {
        address user = address(0x7);
        
        // Test with 1 wei of collateral
        _setCollateralAmount(user, 1);
        
        // Price of $1
        priceFeed.setPrice(1e8);
        
        uint256 value = c.collateralValue(user);
        assertEq(value, 1, "1 wei of collateral should have proportional value");
        
        // Test with fractional price that doesn't divide evenly
        priceFeed.setPrice(33333333); // $0.33333333
        value = c.collateralValue(user);
        assertEq(value, 0, "Very small amounts might round down to 0");
    }

    function test_collateral_value_large_numbers() public {
        address user = address(0x8);
        
        // Test with maximum realistic amounts
        uint256 maxCollateral = type(uint128).max; // Large but not overflow-prone
        _setCollateralAmount(user, maxCollateral);
        
        // Price of $10000
        priceFeed.setPrice(10000e8);
        
        uint256 value = c.collateralValue(user);
        
        // Should not overflow and should calculate correctly
        uint256 expected = maxCollateral * 10000e8 / 1e8;
        assertEq(value, expected, "Large amounts should calculate correctly without overflow");
    }
}