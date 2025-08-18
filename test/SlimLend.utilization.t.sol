// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SlimLend, IPriceFeed} from "../src/SlimLend.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract SlimLendTest is Test {
    SlimLend public c;
    MockERC20 public assetToken;
    MockERC20 public collateralToken;
    MockPriceFeed public priceFeed;
    
    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 2000e8); // 8 decimals, $2000 price
        c = new SlimLend(assetToken, collateralToken, priceFeed);
    }

    bytes32 constant TOTAL_DEPOSITED_TOKENS_SLOT = bytes32(uint256(5));
    bytes32 constant TOTAL_BORROWED_TOKENS_SLOT = bytes32(uint256(6));

    function test_utilization_init() public view {
        uint256 u = c.utilization();
        assertEq(u, 0, "utilization should be zero at init");
    }

    function test_utilization_lend_no_borrow(uint256 amount) public {
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(uint256(amount)));
        uint256 u = c.utilization();
        assertEq(u, 0, "utilization should be zero with no borrows");
    }

    function test_utilization_50pct_borrow() public {
        uint256 amount = 100e18;

        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(uint256(amount)));
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(uint256(amount / 2)));
 
        uint256 u = c.utilization();
        assertEq(u, 0.5e18, "utilization should be 50%");        
    }

    function test_100pct_utilization() public {
        uint256 amount = 123e18;

        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(uint256(amount)));
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(uint256(amount)));
 
        uint256 u = c.utilization();
        assertEq(u, 1e18, "utilization should be 100%");        
    }
}
