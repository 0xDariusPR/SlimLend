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

    function test_last_update_share_price_100pct_util() public {

    }
}
