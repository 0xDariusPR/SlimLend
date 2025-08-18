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
    bytes32 constant BORROWER_SHARE_PRICE_SLOT = bytes32(uint256(8));

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 1e8); // 8 decimals, $1 price
        c = new SlimLend(assetToken, collateralToken, priceFeed);
    }

    function _setBorrowerShares(address user, uint256 shares) internal {
        // borrowerInfo mapping storage slot calculation
        bytes32 slot = keccak256(abi.encode(user, BORROWER_INFO_SLOT));
        // BorrowerInfo struct has borrowerShares at offset 0
        vm.store(address(c), slot, bytes32(shares));
    }

    function _setCollateralAmount(address user, uint256 amount) internal {
        // borrowerInfo mapping storage slot calculation
        bytes32 slot = keccak256(abi.encode(user, BORROWER_INFO_SLOT));
        // BorrowerInfo struct has collateralTokenAmount at offset 1
        bytes32 collateralSlot = bytes32(uint256(slot) + 1);
        vm.store(address(c), collateralSlot, bytes32(amount));
    }

    function _setBorrowerSharePrice(uint256 price) internal {
        vm.store(address(c), BORROWER_SHARE_PRICE_SLOT, bytes32(price));
    }

    function test_collateralization_ratio_no_debt() public {
        address user = address(0x1);
        
        // Set collateral but no debt
        _setCollateralAmount(user, 1000e18);
        _setBorrowerShares(user, 0);
        
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, type(uint256).max, "No debt should return infinite collateralization ratio");
    }

    function test_collateralization_ratio_no_collateral_no_debt() public {
        address user = address(0x2);
        
        // No collateral and no debt (both default to 0)
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, type(uint256).max, "No debt should return infinite collateralization ratio even with no collateral");
    }

    function test_collateralization_ratio_basic_200_percent() public {
        address user = address(0x3);
        
        // Set collateral: 200 tokens at $1 = $200
        _setCollateralAmount(user, 200e18);
        
        // Set debt: 100 shares at 1e18 share price = $100 debt
        _setBorrowerShares(user, 100e18);
        _setBorrowerSharePrice(1e18);
        
        // Set price to $1
        priceFeed.setPrice(1e8);
        
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, 2e18, "200% collateralization: $200 collateral / $100 debt = 2.0");
    }

    function test_collateralization_ratio_150_percent() public {
        address user = address(0x4);
        
        // Set collateral: 150 tokens at $1 = $150
        _setCollateralAmount(user, 150e18);
        
        // Set debt: 100 shares at 1e18 share price = $100 debt  
        _setBorrowerShares(user, 100e18);
        _setBorrowerSharePrice(1e18);
        
        priceFeed.setPrice(1e8);
        
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, 1.5e18, "150% collateralization: $150 collateral / $100 debt = 1.5");
    }

    function test_collateralization_ratio_under_collateralized() public {
        address user = address(0x5);
        
        // Set collateral: 70 tokens at $1 = $70
        _setCollateralAmount(user, 70e18);
        
        // Set debt: 100 shares at 1e18 share price = $100 debt
        _setBorrowerShares(user, 100e18);
        _setBorrowerSharePrice(1e18);
        
        priceFeed.setPrice(1e8);
        
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, 0.7e18, "70% collateralization: $70 collateral / $100 debt = 0.7");
    }

    function test_collateralization_ratio_no_collateral_with_debt() public {
        address user = address(0x6);
        
        // Set no collateral but has debt
        _setCollateralAmount(user, 0);
        _setBorrowerShares(user, 100e18);
        _setBorrowerSharePrice(1e18);
        
        priceFeed.setPrice(1e8);
        
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, 0, "No collateral with debt should return 0% collateralization");
    }

    function test_collateralization_ratio_different_prices() public {
        address user = address(0x7);
        
        // Set collateral: 100 tokens
        _setCollateralAmount(user, 100e18);
        
        // Set debt: 100 shares at 1e18 share price = $100 debt
        _setBorrowerShares(user, 100e18);
        _setBorrowerSharePrice(1e18);
        
        // Test with $2 price: 100 tokens * $2 = $200 collateral
        priceFeed.setPrice(2e8);
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, 2e18, "At $2 price: $200 collateral / $100 debt = 2.0");
        
        // Test with $0.5 price: 100 tokens * $0.5 = $50 collateral
        priceFeed.setPrice(0.5e8);
        ratio = c.collateralization_ratio(user);
        assertEq(ratio, 0.5e18, "At $0.5 price: $50 collateral / $100 debt = 0.5");
    }

    function test_collateralization_ratio_different_share_prices() public {
        address user = address(0x8);
        
        // Set collateral: 200 tokens at $1 = $200
        _setCollateralAmount(user, 200e18);
        priceFeed.setPrice(1e8);
        
        // Set debt: 100 shares
        _setBorrowerShares(user, 100e18);
        
        // Test with 1e18 share price: 100 shares * 1e18 = $100 debt
        _setBorrowerSharePrice(1e18);
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, 2e18, "With 1e18 share price: $200 collateral / $100 debt = 2.0");
        
        // Test with 2e18 share price: 100 shares * 2e18 = $200 debt
        _setBorrowerSharePrice(2e18);
        ratio = c.collateralization_ratio(user);
        assertEq(ratio, 1e18, "With 2e18 share price: $200 collateral / $200 debt = 1.0");
        
        // Test with 0.5e18 share price: 100 shares * 0.5e18 = $50 debt
        _setBorrowerSharePrice(0.5e18);
        ratio = c.collateralization_ratio(user);
        assertEq(ratio, 4e18, "With 0.5e18 share price: $200 collateral / $50 debt = 4.0");
    }

    function test_collateralization_ratio_very_small_amounts() public {
        address user = address(0x9);
        
        // Set very small collateral: 1 wei
        _setCollateralAmount(user, 1);
        
        // Set very small debt: 1 wei worth of shares
        _setBorrowerShares(user, 1);
        _setBorrowerSharePrice(1e18);
        
        priceFeed.setPrice(1e8);
        
        uint256 ratio = c.collateralization_ratio(user);
        // 1 wei collateral * 1e8 price / 1e8 decimals = 1 wei collateral value
        // 1 wei shares * 1e18 share price / 1e18 = 1 wei debt value
        // ratio = 1e18 * 1 / 1 = 1e18 (100% collateralized)
        assertEq(ratio, 1e18, "Very small amounts should still calculate correctly");
    }

    function test_collateralization_ratio_multiple_users() public {
        address user1 = address(0xa);
        address user2 = address(0xb);
        
        // User1: Well collateralized (200%)
        _setCollateralAmount(user1, 200e18);
        _setBorrowerShares(user1, 100e18);
        
        // User2: Under-collateralized (80%)
        _setCollateralAmount(user2, 80e18);
        _setBorrowerShares(user2, 100e18);
        
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        
        uint256 ratio1 = c.collateralization_ratio(user1);
        uint256 ratio2 = c.collateralization_ratio(user2);
        
        assertEq(ratio1, 2e18, "User1 should be 200% collateralized");
        assertEq(ratio2, 0.8e18, "User2 should be 80% collateralized");
    }

    function test_collateralization_ratio_boundary_values() public {
        address user = address(0xc);
        
        // Set collateral and debt
        _setCollateralAmount(user, 100e18);
        _setBorrowerShares(user, 100e18);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        
        // Test exactly 100% collateralized
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, 1e18, "Should be exactly 100% collateralized");
        
        // Test MIN_COLLATERALIZATION_RATIO (80%)
        _setCollateralAmount(user, 80e18);
        ratio = c.collateralization_ratio(user);
        assertEq(ratio, 0.8e18, "Should match MIN_COLLATERALIZATION_RATIO");
        
        // Test LIQUIDATION_THRESHOLD (90%)
        _setCollateralAmount(user, 90e18);
        ratio = c.collateralization_ratio(user);
        assertEq(ratio, 0.9e18, "Should match LIQUIDATION_THRESHOLD");
    }

    function test_collateralization_ratio_large_numbers() public {
        address user = address(0xd);
        
        // Test with large amounts to check for overflow
        uint256 largeCollateral = type(uint128).max / 1e10; // Large but safe amount
        uint256 largeDebt = largeCollateral / 2; // 200% collateralized
        
        _setCollateralAmount(user, largeCollateral);
        _setBorrowerShares(user, largeDebt);
        _setBorrowerSharePrice(1e18);
        priceFeed.setPrice(1e8);
        
        uint256 ratio = c.collateralization_ratio(user);
        assertEq(ratio, 2e18, "Large numbers should calculate correctly without overflow");
    }
}