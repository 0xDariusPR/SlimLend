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

    function _setupUserWithShares(address user, uint256 shareAmount) internal {
        // Mint shares directly to user and give contract tokens
        vm.prank(address(c));
        c.mint(user, shareAmount);
        assetToken.mint(address(c), shareAmount); // 1:1 ratio for simplicity
        
        // Update totalDepositedTokens to match
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(shareAmount));
    }

    function test_update_share_prices_initial() public {
        c.updateSharePrices();
        uint256 lpPrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        uint256 borrowerPrice = uint256(vm.load(address(c), BORROWER_SHARE_PRICE_SLOT));
        
        assertEq(lpPrice, 1e18); 
        assertEq(borrowerPrice, 1e18); 
    }

    function test_redeem_get_assets_1_to_1() public {
        uint256 shareAmount = 1000e18;
        address user = address(0x1);
        
        // Setup user with shares and contract with tokens
        _setupUserWithShares(user, shareAmount);
        
        // Redeem shares and expect 1:1 ratio of assets since lpSharePrice is initially 1e18
        vm.prank(user);
        c.lpRedeemShares(shareAmount, shareAmount);
        
        // Check that user received exactly the same amount of assets as shares redeemed
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, shareAmount, "Should receive 1:1 assets when lpSharePrice is 1e18");
        
        // Verify user's shares were burned
        uint256 userShares = c.balanceOf(user);
        assertEq(userShares, 0, "User shares should be burned");
        
        // Verify total deposited tokens decreased correctly
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, 0, "Total deposited tokens should decrease by redemption amount");
    }

    function test_redeem_shares_2_1() public {
        // Set lpSharePrice to 2e18 to simulate share price doubling
        vm.store(address(c), LP_SHARE_PRICE_SLOT, bytes32(uint256(2e18)));
        
        uint256 shareAmount = 1000e18;
        uint256 expectedAssets = shareAmount * 2; // 2:1 ratio means double the assets
        address user = address(0x3);
        
        // Setup user with shares and contract with enough tokens
        _setupUserWithShares(user, shareAmount);
        assetToken.mint(address(c), expectedAssets); // Give contract extra tokens for 2x payout
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(expectedAssets));
        
        // Redeem shares and expect 2:1 ratio (double assets for same shares)
        vm.prank(user);
        c.lpRedeemShares(shareAmount, expectedAssets);
        
        // Check that user received double the assets due to 2x share price
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, expectedAssets, "Should receive double assets when lpSharePrice is 2e18");
        
        // Verify total deposited tokens decreased correctly
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, 0, "Total deposited tokens should decrease by asset amount");
    }

    function test_redeem_slippage_protection() public {
        uint256 shareAmount = 1000e18;
        address user = address(0x6);
        address user2 = address(0x7);
        address user3 = address(0x8);
        address user4 = address(0x9);
        
        // Setup all users with shares
        _setupUserWithShares(user, shareAmount);
        _setupUserWithShares(user2, shareAmount);
        _setupUserWithShares(user3, shareAmount);
        _setupUserWithShares(user4, shareAmount);
        
        // Give contract enough tokens for all redemptions
        assetToken.mint(address(c), shareAmount * 4);
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(shareAmount * 4));
        
        // Test 1: Slippage protection should pass when minAmountAssetOut is reasonable
        uint256 reasonableMinAssets = shareAmount; // 1:1 ratio expected
        vm.prank(user);
        c.lpRedeemShares(shareAmount, reasonableMinAssets);
        
        // Verify the redemption succeeded
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, shareAmount, "Redemption should succeed with reasonable minAmountAssetOut");
        
        // Test 2: Slippage protection should fail when minAmountAssetOut is too high
        uint256 tooHighMinAssets = shareAmount + 1; // Expecting more assets than possible
        
        vm.prank(user2);
        vm.expectRevert(SlimLend.Slippage.selector);
        c.lpRedeemShares(shareAmount, tooHighMinAssets);
        
        // Test 3: Test with higher share price (simulate after interest accrual)
        vm.store(address(c), LP_SHARE_PRICE_SLOT, bytes32(uint256(2e18))); // Double the share price
        
        uint256 expectedAssetsAt2x = shareAmount * 2; // Double assets at 2x price
        uint256 minAssetsAcceptable = expectedAssetsAt2x; // Accept the correct amount
        uint256 minAssetsTooHigh = expectedAssetsAt2x + 1; // One more than possible
        
        // Give contract more tokens for 2x redemption
        assetToken.mint(address(c), expectedAssetsAt2x);
        
        // Should succeed with correct minimum
        vm.prank(user3);
        c.lpRedeemShares(shareAmount, minAssetsAcceptable);
        
        // Should fail with too high minimum
        vm.prank(user4);
        vm.expectRevert(SlimLend.Slippage.selector);
        c.lpRedeemShares(shareAmount, minAssetsTooHigh);
    }

    function test_redeem_insufficient_liquidity() public {
        uint256 shareAmount = 1000e18;
        address user = address(0xa);
        
        // Setup user with shares but contract with insufficient tokens
        _setupUserWithShares(user, shareAmount);
        // Don't give contract enough tokens - it only has shareAmount, but some might be "borrowed"
        
        // Set some tokens as borrowed to create insufficient liquidity
        vm.store(address(c), TOTAL_BORROWED_TOKENS_SLOT, bytes32(shareAmount / 2));
        
        // Should fail due to insufficient liquidity
        vm.prank(user);
        vm.expectRevert("insufficient liquidity");
        c.lpRedeemShares(shareAmount, shareAmount);
    }

    function test_redeem_totalDepositedTokens_decrease() public {
        uint256 shareAmount1 = 500e18;
        uint256 shareAmount2 = 300e18;
        address user1 = address(0x4);
        address user2 = address(0x5);
        
        // Setup both users with shares and give contract tokens
        _setupUserWithShares(user1, shareAmount1);
        _setupUserWithShares(user2, shareAmount2);
        assetToken.mint(address(c), shareAmount1 + shareAmount2);
        
        // Set initial totalDepositedTokens
        uint256 initialTotal = shareAmount1 + shareAmount2;
        vm.store(address(c), TOTAL_DEPOSITED_TOKENS_SLOT, bytes32(initialTotal));
        
        // Read initial totalDepositedTokens
        uint256 totalDepositedBefore = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDepositedBefore, initialTotal, "Initial totalDepositedTokens should be sum of shares");
        
        // First redemption
        vm.prank(user1);
        c.lpRedeemShares(shareAmount1, shareAmount1);
        
        // Read totalDepositedTokens after first redemption
        uint256 totalDepositedAfterFirst = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDepositedAfterFirst, shareAmount2, "totalDepositedTokens should decrease by first redemption");
        
        // Second redemption
        vm.prank(user2);
        c.lpRedeemShares(shareAmount2, shareAmount2);
        
        // Read totalDepositedTokens after second redemption
        uint256 totalDepositedAfterSecond = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDepositedAfterSecond, 0, "totalDepositedTokens should be zero after all redemptions");
        
        // Verify the decrease between redemptions
        uint256 decrease = totalDepositedAfterFirst - totalDepositedAfterSecond;
        assertEq(decrease, shareAmount2, "Decrease should equal second redemption amount");
    }

    function test_redeem_zero_shares() public {
        address user = address(0xa);
        
        // Setup user with some shares
        _setupUserWithShares(user, 1000e18);
        
        // Test redeeming zero shares with zero minimum assets
        vm.prank(user);
        c.lpRedeemShares(0, 0);
        
        // Verify user received zero assets
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, 0, "Zero redemption should result in zero assets");
        
        // Verify totalDepositedTokens remains unchanged
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, 1000e18, "Zero redemption should not change totalDepositedTokens");
        
        // Test that zero redemption with non-zero minAmountAssetOut fails
        vm.prank(user);
        vm.expectRevert(SlimLend.Slippage.selector);
        c.lpRedeemShares(0, 1); // Expecting 1 asset from 0 shares should fail
    }

    function test_redeem_very_small_amounts() public {
        address user = address(0xc);
        address user2 = address(0xd);
        
        // Test redeeming 1 wei of shares
        uint256 shareAmount = 1;
        uint256 expectedAssets = shareAmount * 1e18 / 1e18; // Should be 1 since lpSharePrice = 1e18
        
        // Setup user with shares
        _setupUserWithShares(user, shareAmount);
        
        vm.prank(user);
        c.lpRedeemShares(shareAmount, expectedAssets);
        
        // Verify user received correct assets (should be 1 wei of assets)
        uint256 userTokens = assetToken.balanceOf(user);
        assertEq(userTokens, expectedAssets, "1 wei of shares should result in 1 wei of assets");
        assertEq(userTokens, 1, "1 wei of shares should result in exactly 1 wei of assets");
        
        // Verify totalDepositedTokens decreased correctly
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, 0, "totalDepositedTokens should decrease by 1 wei");
        
        // Test with slightly larger small amount (1000 wei)
        uint256 smallShares = 1000;
        uint256 expectedSmallAssets = smallShares * 1e18 / 1e18; // Should be 1000
        
        // Setup second user
        _setupUserWithShares(user2, smallShares);
        
        vm.prank(user2);
        c.lpRedeemShares(smallShares, expectedSmallAssets);
        
        uint256 user2Tokens = assetToken.balanceOf(user2);
        assertEq(user2Tokens, expectedSmallAssets, "Small redemption should calculate assets correctly");
        assertEq(user2Tokens, 1000, "1000 wei of shares should result in 1000 wei of assets");
    }

    function test_redeem_emit_event() public {
        uint256 shareAmount = 500e18;
        address user = address(0x2);
        
        // Setup user with shares
        _setupUserWithShares(user, shareAmount);
        
        // Expect the LPRedeem event to be emitted with correct parameters
        vm.expectEmit(true, false, false, true);
        emit SlimLend.LPRedeem(user, shareAmount, shareAmount); // 1:1 ratio since lpSharePrice is 1e18
        
        vm.prank(user);
        c.lpRedeemShares(shareAmount, shareAmount);
    }
}