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
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SlimLendTest is Test {
    ESlimLend public c;
    MockERC20 public assetToken;
    MockERC20 public collateralToken;
    MockPriceFeed public priceFeed;

    bytes32 constant TOTAL_DEPOSITED_TOKENS_SLOT = bytes32(uint256(5));
    bytes32 constant TOTAL_BORROWED_TOKENS_SLOT = bytes32(uint256(6));
    bytes32 constant LP_SHARE_PRICE_SLOT = bytes32(uint256(7));
    bytes32 constant BORROWER_SHARE_PRICE_SLOT = bytes32(uint256(8));
    bytes32 constant LAST_UPDATE_TIME_SLOT = bytes32(uint256(9));

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        priceFeed = new MockPriceFeed(8, 2000e8); // 8 decimals, $2000 price
        c = new ESlimLend(assetToken, collateralToken, priceFeed);
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        assetToken.mint(user, amount);
        vm.prank(user);
        assetToken.approve(address(c), amount);
    }

    function _setUtilization(uint256 totalDeposited, uint256 totalBorrowed) internal {
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(totalDeposited));
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(totalBorrowed));
    }

    function _prepareForRedemption(uint256 expectedAssets) internal {
        // Give contract enough tokens and ensure sufficient liquidity
        assetToken.mint(address(c), expectedAssets);
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(0));
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(expectedAssets));
    }

    function test_deposit_time_passage_redeem_no_utilization() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x1);
        
        // Setup user with tokens
        _mintAndApprove(user, depositAmount);
        
        // Initial deposit
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 initialShares = c.balanceOf(user);
        assertEq(initialShares, depositAmount, "Initial shares should be 1:1");
        
        // Advance time by 1 year but with no utilization (no borrowing)
        skip(365 days);
        
        // Since there's no utilization, share price shouldn't change
        uint256 sharePrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        assertEq(sharePrice, 1e18, "Share price should remain 1e18 with no utilization");
        
        // Redeem should give back the same amount
        vm.prank(user);
        c.lpRedeemShares(initialShares, depositAmount);
        
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, depositAmount, "Should get back exactly the same amount with no interest");
    }

    function test_deposit_time_passage_redeem_with_utilization() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x1);
        
        // Setup user with tokens
        _mintAndApprove(user, depositAmount);
        
        // Initial deposit
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 initialShares = c.balanceOf(user);
        
        // Set 50% utilization
        _setUtilization(depositAmount, depositAmount / 2);
        
        // Advance time by 1 year
        skip(365 days);
        
        // Manually trigger share price update
        c.updateSharePrices();
        
        // Check that share price increased due to interest
        uint256 sharePrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        assertGt(sharePrice, 1e18, "Share price should increase with utilization and time");
        
        // Calculate expected assets (shares * new price)
        uint256 expectedAssets = initialShares * sharePrice / 1e18;
        
        // Prepare contract for redemption
        _prepareForRedemption(expectedAssets);
        
        // Redeem and verify user gets more assets due to interest
        vm.prank(user);
        c.lpRedeemShares(initialShares, expectedAssets);
        
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, expectedAssets, "Should get more assets due to interest");
        assertGt(userTokens, depositAmount, "Should get more than originally deposited");
    }

    function test_deposit_utilization_change_redeem() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x1);
        
        // Setup user with tokens
        _mintAndApprove(user, depositAmount);
        
        // Initial deposit with 25% utilization
        _setUtilization(depositAmount, depositAmount / 4);
        
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 initialShares = c.balanceOf(user);
        
        // Advance time by 6 months at 25% utilization
        skip(180 days);
        
        // Update prices for first period
        c.updateSharePrices();
        
        // Change to 75% utilization (higher interest rate)
        _setUtilization(depositAmount * 2, (depositAmount * 2 * 3) / 4); // 75% of doubled pool
        
        // Advance another 6 months at higher utilization
        skip(180 days);
        
        // Update prices for second period
        c.updateSharePrices();
        
        // Share price should have increased more in the second period
        uint256 sharePrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        assertGt(sharePrice, 1e18, "Share price should increase with utilization");
        
        // Redeem all shares
        uint256 expectedAssets = initialShares * sharePrice / 1e18;
        _prepareForRedemption(expectedAssets);
        vm.prank(user);
        c.lpRedeemShares(initialShares, expectedAssets);
        
        uint256 userTokens = assetToken.balanceOf(user);
        assertGt(userTokens, depositAmount, "Should earn interest from both periods");
    }

    function test_deposit_redeem_multiple_users_with_time() public {
        uint256 depositAmount = 1000e18;
        address user1 = address(0x1);
        address user2 = address(0x2);
        
        // Setup users with tokens
        _mintAndApprove(user1, depositAmount);
        _mintAndApprove(user2, depositAmount);
        
        // User1 deposits first
        vm.prank(user1);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 user1Shares = c.balanceOf(user1);
        
        // Set utilization and advance time
        _setUtilization(depositAmount, depositAmount / 2); // 50%
        skip(365 days);
        
        // User2 deposits after interest has accrued (share price is higher)
        vm.prank(user2);
        c.lpDepositAsset(depositAmount, 0); // Accept any amount of shares
        
        uint256 user2Shares = c.balanceOf(user2);
        uint256 sharePrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        
        // User2 should get fewer shares due to higher share price
        assertLt(user2Shares, user1Shares, "User2 should get fewer shares due to higher price");
        
        // Both users redeem their shares
        // Prepare contract for redemptions by ensuring sufficient liquidity
        uint256 totalExpectedAssets = (user1Shares + user2Shares) * sharePrice / 1e18;
        _prepareForRedemption(totalExpectedAssets);
        
        vm.prank(user1);
        c.lpRedeemShares(user1Shares, 0);
        
        vm.prank(user2);
        c.lpRedeemShares(user2Shares, 0);
        
        uint256 user1Tokens = assetToken.balanceOf(user1);
        uint256 user2Tokens = assetToken.balanceOf(user2);
        
        // Both should get back approximately their deposit + interest
        assertGt(user1Tokens, depositAmount, "User1 should earn interest");
        assertApproxEqRel(user2Tokens, depositAmount, 0.01e18, "User2 should get back ~same amount (deposited at current price)");
    }

    function test_deposit_max_utilization_redeem() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x1);
        
        // Setup user with tokens
        _mintAndApprove(user, depositAmount);
        
        // Initial deposit
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 initialShares = c.balanceOf(user);
        
        // Set 100% utilization (maximum interest rate)
        _setUtilization(depositAmount, depositAmount);
        
        // Advance time by 1 month at max interest
        skip(30 days);
        
        // Update share prices
        c.updateSharePrices();
        
        uint256 sharePrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        assertGt(sharePrice, 1e18, "Share price should increase significantly at 100% utilization");
        
        // Redeem and verify high interest earned
        uint256 expectedAssets = initialShares * sharePrice / 1e18;
        _prepareForRedemption(expectedAssets);
        vm.prank(user);
        c.lpRedeemShares(initialShares, expectedAssets);
        
        uint256 userTokens = assetToken.balanceOf(user);
        assertGt(userTokens, depositAmount * 101 / 100, "Should earn significant interest at max utilization");
    }

    function test_deposit_optimal_utilization_redeem() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x1);
        
        // Setup user with tokens
        _mintAndApprove(user, depositAmount);
        
        // Initial deposit
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 initialShares = c.balanceOf(user);
        
        // Set optimal utilization (95%)
        uint256 optimalUtilization = 95; // 95%
        _setUtilization(depositAmount, depositAmount * optimalUtilization / 100);
        
        // Advance time by 1 year at optimal utilization
        skip(365 days);
        
        // Update share prices
        c.updateSharePrices();
        
        uint256 sharePrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        
        // Redeem at the kink point utilization
        uint256 expectedAssets = initialShares * sharePrice / 1e18;
        _prepareForRedemption(expectedAssets);
        vm.prank(user);
        c.lpRedeemShares(initialShares, expectedAssets);
        
        uint256 userTokens = assetToken.balanceOf(user);
        assertGt(userTokens, depositAmount, "Should earn interest at optimal utilization");
    }

    function test_deposit_redeem_precision_after_interest() public {
        uint256 depositAmount = 1; // 1 wei
        address user = address(0x1);
        
        // Setup user with minimal tokens
        _mintAndApprove(user, depositAmount);
        
        // Initial deposit of 1 wei
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 initialShares = c.balanceOf(user);
        assertEq(initialShares, 1, "Should get 1 share for 1 wei");
        
        // Set utilization and advance time
        _setUtilization(1000e18, 500e18); // 50% utilization on larger pool
        skip(365 days);
        
        // Update share prices
        c.updateSharePrices();
        
        // Check share price increased
        uint256 sharePrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        assertGt(sharePrice, 1e18, "Share price should increase");
        
        // Redeem the 1 wei share
        uint256 expectedAssets = initialShares * sharePrice / 1e18;
        _prepareForRedemption(expectedAssets);
        vm.prank(user);
        c.lpRedeemShares(initialShares, expectedAssets);
        
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, expectedAssets, "Should get calculated asset amount");
        assertGe(userTokens, 1, "Should get at least 1 wei back");
    }

    function test_multiple_deposits_time_single_redeem() public {
        uint256 depositAmount = 500e18;
        address user = address(0x1);
        
        // Setup user with tokens for multiple deposits
        _mintAndApprove(user, depositAmount * 3);
        
        // First deposit
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 firstShares = c.balanceOf(user);
        
        // Set utilization and advance time
        _setUtilization(depositAmount, depositAmount / 4); // 25%
        skip(180 days);
        
        // Second deposit (at higher share price)
        vm.prank(user);
        c.lpDepositAsset(depositAmount, 0);
        
        uint256 totalShares = c.balanceOf(user);
        uint256 secondDepositShares = totalShares - firstShares;
        assertLt(secondDepositShares, firstShares, "Second deposit should get fewer shares");
        
        // Advance more time
        skip(180 days);
        
        // Third deposit (at even higher share price)
        vm.prank(user);
        c.lpDepositAsset(depositAmount, 0);
        
        uint256 finalShares = c.balanceOf(user);
        uint256 thirdDepositShares = finalShares - totalShares;
        assertLt(thirdDepositShares, secondDepositShares, "Third deposit should get even fewer shares");
        
        // Redeem all shares at once
        uint256 sharePrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        uint256 expectedAssets = finalShares * sharePrice / 1e18;
        
        // Prepare contract for redemption by ensuring sufficient liquidity
        _prepareForRedemption(expectedAssets);
        
        vm.prank(user);
        c.lpRedeemShares(finalShares, expectedAssets);
        
        uint256 userTokens = assetToken.balanceOf(user);
        assertGt(userTokens, depositAmount * 3, "Should get more than total deposits due to interest");
    }

    function test_deposit_redeem_round_trip_consistency() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x1);
        
        // Setup user with tokens
        _mintAndApprove(user, depositAmount);
        
        // Deposit -> immediate redeem (no time passage)
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        uint256 shares = c.balanceOf(user);
        
        vm.prank(user);
        c.lpRedeemShares(shares, depositAmount);
        
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, depositAmount, "Round trip with no time should return exact amount");
        
        // Verify contract state is clean
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, 0, "Total deposited should be zero after round trip");
        assertEq(c.totalSupply(), 0, "Total share supply should be zero");
    }
}