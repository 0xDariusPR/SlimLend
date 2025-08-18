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

    function test_update_share_prices_initial() public {

        c.updateSharePrices();
        uint256 lpPrice = uint256(vm.load(address(c), LP_SHARE_PRICE_SLOT));
        uint256 borrowerPrice = uint256(vm.load(address(c), BORROWER_SHARE_PRICE_SLOT));
        
        assertEq(lpPrice, 1e18); 
        assertEq(borrowerPrice, 1e18); 
    }

    function test_deposit_get_shares_1_to_1() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x1);
        
        // Mint tokens and approve
        _mintAndApprove(user, depositAmount);
        
        // Deposit assets and expect 1:1 ratio of shares since lpSharePrice is initially 1e18
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
        
        // Check that user received exactly the same amount of shares as deposited
        uint256 userShares = c.balanceOf(user);
        assertEq(userShares, depositAmount, "Should receive 1:1 shares when lpSharePrice is 1e18");
        
        // Verify total deposited tokens increased correctly
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, depositAmount, "Total deposited tokens should equal deposit amount");
    }

    function test_deposit_emit_event() public {
        uint256 depositAmount = 500e18;
        address user = address(0x2);
        
        // Mint tokens and approve
        _mintAndApprove(user, depositAmount);
        
        // Expect the LPDeposit event to be emitted with correct parameters
        vm.expectEmit(true, false, false, true);
        emit SlimLend.LPDeposit(user, depositAmount, depositAmount); // 1:1 ratio since lpSharePrice is 1e18
        
        vm.prank(user);
        c.lpDepositAsset(depositAmount, depositAmount);
    }

    function test_deposit_shares_2_1() public {
        // Set lpSharePrice to 2e18 to simulate share price doubling
        vm.store(address(c), LP_SHARE_PRICE_SLOT, bytes32(uint256(2e18)));
        
        uint256 depositAmount = 1000e18;
        uint256 expectedShares = depositAmount / 2; // 2:1 ratio means half the shares
        address user = address(0x3);
        
        // Mint tokens and approve
        _mintAndApprove(user, depositAmount);
        
        // Deposit assets and expect 2:1 ratio (half shares for double price)
        vm.prank(user);
        c.lpDepositAsset(depositAmount, expectedShares);
        
        // Check that user received half the shares due to 2x share price
        uint256 userShares = c.balanceOf(user);
        assertEq(userShares, expectedShares, "Should receive half shares when lpSharePrice is 2e18");
        
        // Verify total deposited tokens increased correctly
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, depositAmount, "Total deposited tokens should equal deposit amount");
    }

    function test_deposit_totalDepositedTokens_increase() public {
        uint256 depositAmount1 = 500e18;
        uint256 depositAmount2 = 300e18;
        address user1 = address(0x4);
        address user2 = address(0x5);
        
        // Mint tokens and approve for both users
        _mintAndApprove(user1, depositAmount1);
        _mintAndApprove(user2, depositAmount2);
        
        // Read initial totalDepositedTokens (should be 0)
        uint256 totalDepositedBefore = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDepositedBefore, 0, "Initial totalDepositedTokens should be 0");
        
        // First deposit
        vm.prank(user1);
        c.lpDepositAsset(depositAmount1, depositAmount1);
        
        // Read totalDepositedTokens after first deposit
        uint256 totalDepositedAfterFirst = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDepositedAfterFirst, depositAmount1, "totalDepositedTokens should equal first deposit");
        
        // Second deposit
        vm.prank(user2);
        c.lpDepositAsset(depositAmount2, depositAmount2);
        
        // Read totalDepositedTokens after second deposit
        uint256 totalDepositedAfterSecond = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        uint256 expectedTotal = depositAmount1 + depositAmount2;
        assertEq(totalDepositedAfterSecond, expectedTotal, "totalDepositedTokens should equal sum of both deposits");
        
        // Verify the increase between deposits
        uint256 increase = totalDepositedAfterSecond - totalDepositedAfterFirst;
        assertEq(increase, depositAmount2, "Increase should equal second deposit amount");
    }

    function test_deposit_slippage_protection() public {
        uint256 depositAmount = 1000e18;
        address user = address(0x6);
        address user2 = address(0x7);
        address user3 = address(0x8);
        address user4 = address(0x9);
        
        // Mint tokens and approve for all users
        _mintAndApprove(user, depositAmount);
        _mintAndApprove(user2, depositAmount);
        _mintAndApprove(user3, depositAmount);
        _mintAndApprove(user4, depositAmount);
        
        // Test 1: Slippage protection should pass when minSharesOut is reasonable
        uint256 reasonableMinShares = depositAmount; // 1:1 ratio expected
        vm.prank(user);
        c.lpDepositAsset(depositAmount, reasonableMinShares);
        
        // Verify the deposit succeeded
        uint256 userShares = c.balanceOf(user);
        assertEq(userShares, depositAmount, "Deposit should succeed with reasonable minSharesOut");
        
        // Test 2: Slippage protection should fail when minSharesOut is too high
        uint256 tooHighMinShares = depositAmount + 1; // Expecting more shares than possible
        
        vm.prank(user2);
        vm.expectRevert(SlimLend.Slippage.selector);
        c.lpDepositAsset(depositAmount, tooHighMinShares);
        
        // Test 3: Test with higher share price (simulate after interest accrual)
        vm.store(address(c), LP_SHARE_PRICE_SLOT, bytes32(uint256(2e18))); // Double the share price
        
        uint256 expectedSharesAt2x = depositAmount / 2; // Half shares at 2x price
        uint256 minSharesAcceptable = expectedSharesAt2x; // Accept the correct amount
        uint256 minSharesTooHigh = expectedSharesAt2x + 1; // One more than possible
        
        // Should succeed with correct minimum
        vm.prank(user3);
        c.lpDepositAsset(depositAmount, minSharesAcceptable);
        
        // Should fail with too high minimum
        vm.prank(user4);
        vm.expectRevert(SlimLend.Slippage.selector);
        c.lpDepositAsset(depositAmount, minSharesTooHigh);
    }

    function test_deposit_zero_amount() public {
        address user = address(0xa);
        address user2 = address(0xb);
        
        // Mint tokens and approve (even for zero amount test, in case of edge cases)
        _mintAndApprove(user, 0);
        _mintAndApprove(user2, 0);
        
        // Test depositing zero amount with zero minimum shares
        vm.prank(user);
        c.lpDepositAsset(0, 0);
        
        // Verify user received zero shares
        uint256 userShares = c.balanceOf(user);
        assertEq(userShares, 0, "Zero deposit should result in zero shares");
        
        // Verify totalDepositedTokens remains zero
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, 0, "Zero deposit should not change totalDepositedTokens");
        
        // Test that zero deposit with non-zero minSharesOut fails
        vm.prank(user2);
        vm.expectRevert(SlimLend.Slippage.selector);
        c.lpDepositAsset(0, 1); // Expecting 1 share from 0 deposit should fail
    }

    function test_deposit_very_small_amounts() public {
        address user = address(0xc);
        address user2 = address(0xd);
        
        // Test depositing 1 wei
        uint256 depositAmount = 1;
        uint256 expectedShares = 10**18 * depositAmount / 1e18; // Should be 1 since lpSharePrice = 1e18
        
        // Mint tokens and approve
        _mintAndApprove(user, depositAmount);
        
        vm.prank(user);
        c.lpDepositAsset(depositAmount, expectedShares);
        
        // Verify user received correct shares (should be 1 wei of shares)
        uint256 userShares = c.balanceOf(user);
        assertEq(userShares, expectedShares, "1 wei deposit should result in 1 wei of shares");
        assertEq(userShares, 1, "1 wei deposit should result in exactly 1 wei of shares");
        
        // Verify totalDepositedTokens increased correctly
        uint256 totalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalDeposited, depositAmount, "totalDepositedTokens should equal 1 wei");
        
        // Test with slightly larger small amount (1000 wei)
        uint256 smallAmount = 1000;
        uint256 expectedSmallShares = 10**18 * smallAmount / 1e18; // Should be 1000
        
        // Mint tokens and approve for second user
        _mintAndApprove(user2, smallAmount);
        
        vm.prank(user2);
        c.lpDepositAsset(smallAmount, expectedSmallShares);
        
        uint256 user2Shares = c.balanceOf(user2);
        assertEq(user2Shares, expectedSmallShares, "Small deposit should calculate shares correctly");
        assertEq(user2Shares, 1000, "1000 wei deposit should result in 1000 wei of shares");
        
        // Verify total shares and deposits
        uint256 totalShares = c.totalSupply();
        uint256 finalTotalDeposited = uint256(vm.load(address(c), TOTAL_DEPOSITED_TOKENS_SLOT));
        assertEq(totalShares, 1 + 1000, "Total shares should be sum of both deposits");
        assertEq(finalTotalDeposited, 1 + 1000, "Total deposited should be sum of both deposits");
    }
}
