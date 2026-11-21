// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {stdError} from "forge-std/StdError.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {Fixture} from "../Fixture.sol";

contract LMSRMarketTest is Fixture {
    uint256 internal constant B = 100e18;

    function setUp() public {
        _setUpMarket(B);
        _give(alice, 1e32);
        _give(bob, 1e32);
    }

    function _buy(address who, uint8 outcome, uint256 shares) internal returns (uint256) {
        vm.prank(who);
        return market.buy(outcome, shares, type(uint256).max);
    }

    function _sell(address who, uint8 outcome, uint256 shares) internal returns (uint256) {
        vm.prank(who);
        return market.sell(outcome, shares, 0);
    }

    // ------------------------------------------------------------ the worked example

    /// docs/KNOWLEDGE.md: b = 100, buying 50 YES from (0, 0) costs 100·ln((e^0.5 + 1)/2)
    /// = 28.09298... points and moves the YES price to 0.6225.
    function test_worked_example_from_knowledge() public {
        uint256 charged = _buy(alice, 0, 50e18);
        // lmsr-ref: the exact cost lies in [28092980362016137145, 28092980362016137146].
        assertGe(charged, 28_092_980_362_016_137_146, "charge below the exact cost");
        assertLe(charged, 28_092_980_362_016_137_146 + 4 * market.costError(), "charge above the stated bound");
        (uint256 p0, uint256 p1) = market.prices();
        assertEq(p0 + p1, 1e18);
        assertApproxEqAbs(p0, 622_459_331_201_854_565, 4);
        assertEq(_shares(alice, 0), 50e18);
    }

    // ------------------------------------------------------------ bounds and overflow

    function test_liquidity_below_the_floor_is_refused() public {
        vm.expectRevert(abi.encodeWithSelector(LMSRMarket.LiquidityOutOfRange.selector, 1e18 - 1));
        new LMSRMarket(points, outcomes, 1e18 - 1, closeTime, resolver);
    }

    function test_liquidity_above_the_ceiling_is_refused() public {
        vm.expectRevert(abi.encodeWithSelector(LMSRMarket.LiquidityOutOfRange.selector, 1e30 + 1));
        new LMSRMarket(points, outcomes, 1e30 + 1, closeTime, resolver);
    }

    function test_a_zero_resolver_is_refused() public {
        vm.expectRevert(LMSRMarket.ZeroAddress.selector);
        new LMSRMarket(points, outcomes, 1e18, closeTime, address(0));
    }

    function test_buy_past_the_quantity_ceiling_is_refused() public {
        _buy(alice, 0, 1e30 - 1);
        vm.expectRevert(LMSRMarket.QuantityOverflow.selector);
        _buy(alice, 0, 2);
    }

    function test_max_uint_buy_is_refused_as_overflow() public {
        vm.expectRevert(LMSRMarket.QuantityOverflow.selector);
        _buy(alice, 1, type(uint256).max);
    }

    /// A naive e^(q/b) overflows PRBMath's exp at q/b > 133; the stable form prices a
    /// 1e12·b spread and charges for it.
    function test_extreme_spread_prices_without_overflow() public {
        LMSRMarket thin = _deploy(1e18);
        vm.prank(alice);
        uint256 charged = thin.buy(0, 1e30, type(uint256).max);
        (uint256 p0, uint256 p1) = thin.prices();
        assertEq(p0, 1e18);
        assertEq(p1, 0);
        // The exact cost is 1e30 + ln((1 + e^-1e12)/2)·1e18 ≈ 1e30 - 0.693e18.
        assertGe(charged, 1e30 - 693_147_180_559_945_309);
        assertLe(charged, 1e30);
    }

    // ------------------------------------------------------------ zero and negative

    function test_zero_buy_is_refused() public {
        vm.expectRevert(LMSRMarket.ZeroAmount.selector);
        _buy(alice, 0, 0);
    }

    function test_zero_sell_is_refused() public {
        _buy(alice, 0, 1e18);
        vm.expectRevert(LMSRMarket.ZeroAmount.selector);
        _sell(alice, 0, 0);
    }

    function test_zero_sets_are_refused() public {
        vm.prank(alice);
        vm.expectRevert(LMSRMarket.ZeroAmount.selector);
        market.mintSets(0);
        vm.prank(alice);
        vm.expectRevert(LMSRMarket.ZeroAmount.selector);
        market.burnSets(0);
    }

    function test_zero_redeem_is_refused() public {
        _closeAndResolve(0);
        vm.prank(alice);
        vm.expectRevert(LMSRMarket.ZeroAmount.selector);
        market.redeem(0);
    }

    /// Amounts are unsigned: a negative amount reaches the contract as its two's
    /// complement, a number near 2^256, which is refused as overflow, never wrapped.
    function test_negative_buy_is_refused() public {
        uint256 minusFive;
        unchecked {
            minusFive = uint256(-int256(5e18));
        }
        vm.expectRevert(LMSRMarket.QuantityOverflow.selector);
        _buy(alice, 0, minusFive);
    }

    function test_negative_sell_is_refused() public {
        _buy(alice, 0, 10e18);
        uint256 minusFive;
        unchecked {
            minusFive = uint256(-int256(5e18));
        }
        vm.expectRevert(LMSRMarket.InsufficientQuantity.selector);
        _sell(alice, 0, minusFive);
    }

    function test_selling_more_than_the_market_sold_is_refused() public {
        _buy(alice, 0, 10e18);
        vm.expectRevert(LMSRMarket.InsufficientQuantity.selector);
        _sell(alice, 0, 10e18 + 1);
    }

    /// The burn is from the seller: bob, holding none, cannot sell alice's shares back, and
    /// nothing moves (scripts/prove-contracts.sh: sell-burn).
    function test_selling_shares_you_do_not_hold_is_refused() public {
        _buy(alice, 0, 10e18);
        uint256 id = outcomes.tokenId(address(market), 0);
        uint256[4] memory before = _ledger();
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, 0, 1e18, id));
        _sell(bob, 0, 1e18);
        _assertLedger(before);
        assertEq(_shares(alice, 0), 10e18);
        assertEq(_shares(bob, 0), 0);
    }

    /// q0, q1, the market's points, alice's + bob's points.
    function _ledger() internal view returns (uint256[4] memory l) {
        (l[0], l[1]) = market.quantities();
        l[2] = points.balanceOf(address(market));
        l[3] = points.balanceOf(alice) + points.balanceOf(bob);
    }

    function _assertLedger(uint256[4] memory before) internal view {
        uint256[4] memory later = _ledger();
        assertEq(later[0], before[0], "q0 moved");
        assertEq(later[1], before[1], "q1 moved");
        assertEq(later[2], before[2], "the market's points moved");
        assertEq(later[3], before[3], "the traders' points moved");
    }

    function test_invalid_outcome_is_refused() public {
        vm.expectRevert(abi.encodeWithSelector(LMSRMarket.InvalidOutcome.selector, 2));
        _buy(alice, 2, 1e18);
    }

    function test_slippage_limits_are_enforced() public {
        uint256 quote = market.quoteBuy(0, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LMSRMarket.SlippageExceeded.selector, quote, quote - 1));
        market.buy(0, 10e18, quote - 1);
        _buy(alice, 0, 10e18);
        uint256 back = market.quoteSell(0, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LMSRMarket.SlippageExceeded.selector, back, back + 1));
        market.sell(0, 10e18, back + 1);
    }

    // ------------------------------------------------------------ lifecycle

    function _closeAndResolve(uint8 outcome) internal {
        vm.warp(closeTime);
        vm.prank(resolver);
        market.resolve(outcome);
    }

    function test_unfunded_market_refuses_trades() public {
        LMSRMarket unfunded = new LMSRMarket(points, outcomes, B, closeTime, resolver);
        vm.prank(alice);
        vm.expectRevert(LMSRMarket.MarketNotFunded.selector);
        unfunded.buy(0, 1e18, type(uint256).max);
    }

    function test_funding_twice_is_refused() public {
        vm.prank(funder);
        vm.expectRevert(LMSRMarket.AlreadyFunded.selector);
        market.fund();
    }

    function test_buy_in_a_closed_market_is_refused() public {
        vm.warp(closeTime);
        vm.expectRevert(LMSRMarket.MarketClosed.selector);
        _buy(alice, 0, 1e18);
    }

    function test_sell_in_a_closed_market_is_refused() public {
        _buy(alice, 0, 1e18);
        vm.warp(closeTime);
        vm.expectRevert(LMSRMarket.MarketClosed.selector);
        _sell(alice, 0, 1e18);
    }

    function test_sets_in_a_closed_market_are_refused() public {
        vm.prank(alice);
        market.mintSets(1e18);
        vm.warp(closeTime);
        vm.prank(alice);
        vm.expectRevert(LMSRMarket.MarketClosed.selector);
        market.mintSets(1e18);
        vm.prank(alice);
        vm.expectRevert(LMSRMarket.MarketClosed.selector);
        market.burnSets(1e18);
    }

    function test_buy_in_a_resolved_market_is_refused() public {
        _closeAndResolve(1);
        vm.expectRevert(LMSRMarket.MarketResolved.selector);
        _buy(alice, 0, 1e18);
    }

    function test_sell_in_a_resolved_market_is_refused() public {
        _buy(alice, 0, 1e18);
        _closeAndResolve(0);
        vm.expectRevert(LMSRMarket.MarketResolved.selector);
        _sell(alice, 0, 1e18);
    }

    function test_resolving_before_close_is_refused() public {
        vm.prank(resolver);
        vm.expectRevert(LMSRMarket.MarketStillOpen.selector);
        market.resolve(0);
    }

    function test_resolving_by_anyone_else_is_refused() public {
        vm.warp(closeTime);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LMSRMarket.NotResolver.selector, alice));
        market.resolve(1);
        assertFalse(market.resolved());
        assertEq(market.winner(), 0);
    }

    function test_resolving_twice_is_refused() public {
        _closeAndResolve(0);
        vm.prank(resolver);
        vm.expectRevert(LMSRMarket.MarketResolved.selector);
        market.resolve(1);
        assertTrue(market.resolved());
        assertEq(market.winner(), 0);
    }

    function test_redeem_before_resolution_is_refused() public {
        _buy(alice, 0, 1e18);
        vm.prank(alice);
        vm.expectRevert(LMSRMarket.MarketNotResolved.selector);
        market.redeem(1e18);
    }

    /// Losing shares: q[winner] is 0, so the checked subtraction refuses before any burn.
    function test_redeeming_losing_shares_is_refused() public {
        _buy(alice, 1, 1e18);
        _closeAndResolve(0);
        uint256[4] memory before = _ledger();
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        market.redeem(1e18);
        _assertLedger(before);
        assertEq(_shares(alice, 1), 1e18);
    }

    /// The burn is from the redeemer: bob holds the winners, alice holds none and cannot be
    /// paid for his (q[winner] covers it, so only the burn refuses; scripts/prove-contracts.sh:
    /// redeem-burn). Bob still redeems his own afterwards.
    function test_redeeming_shares_you_do_not_hold_is_refused() public {
        _buy(bob, 0, 1e18);
        _closeAndResolve(0);
        uint256 id = outcomes.tokenId(address(market), 0);
        uint256[4] memory before = _ledger();
        uint256 aliceBefore = points.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 0, 1e18, id));
        market.redeem(1e18);
        _assertLedger(before);
        assertEq(points.balanceOf(alice), aliceBefore);
        assertEq(_shares(alice, 0), 0);
        assertEq(_shares(bob, 0), 1e18);
        uint256 bobBefore = points.balanceOf(bob);
        vm.prank(bob);
        market.redeem(1e18);
        assertEq(points.balanceOf(bob) - bobBefore, 1e18);
        assertEq(_shares(bob, 0), 0);
    }

    function test_winners_redeem_one_point_per_share_and_the_pool_covers_them() public {
        _buy(alice, 0, 300e18);
        _buy(bob, 1, 20e18);
        _closeAndResolve(0);
        uint256 before = points.balanceOf(alice);
        vm.prank(alice);
        market.redeem(300e18);
        assertEq(points.balanceOf(alice) - before, 300e18);
        assertEq(_shares(alice, 0), 0);
    }

    // ------------------------------------------------------------ rounding favours the pool

    function test_one_wei_buy_is_never_free() public {
        assertGe(market.quoteBuy(0, 1), 1);
        uint256 before = points.balanceOf(alice);
        _buy(alice, 0, 1);
        assertGt(before - points.balanceOf(alice), 0);
    }

    function test_one_wei_sell_returns_nothing() public {
        _buy(alice, 0, 1e18);
        assertEq(market.quoteSell(0, 1), 0);
    }

    function test_dust_buy_sell_loop_never_profits() public {
        uint256 before = points.balanceOf(alice);
        for (uint256 i = 0; i < 50; i++) {
            _buy(alice, 0, 1);
            _sell(alice, 0, 1);
        }
        assertLt(points.balanceOf(alice), before);
    }

    function testFuzz_round_trip_never_profits(uint8 outcome, uint256 shares) public {
        outcome = uint8(bound(outcome, 0, 1));
        shares = bound(shares, 1, 1e24);
        uint256 paid = _buy(alice, outcome, shares);
        uint256 back = _sell(alice, outcome, shares);
        assertLt(back, paid);
    }

    function testFuzz_prices_sum_to_one(uint256 a, uint256 b) public {
        a = bound(a, 0, 1e24);
        b = bound(b, 0, 1e24);
        if (a != 0) _buy(alice, 0, a);
        if (b != 0) _buy(bob, 1, b);
        (uint256 p0, uint256 p1) = market.prices();
        assertEq(p0 + p1, 1e18);
    }

    /// C depends only on q: two orders that reach the same quantities leave the same cost,
    /// and each path's total charge is within its rounding margins of the other's.
    function testFuzz_cost_is_path_independent(uint256 a, uint256 b) public {
        a = bound(a, 1, 1e24);
        b = bound(b, 1, 1e24);
        uint256 viaZero = _buy(alice, 0, a) + _buy(alice, 1, b);
        uint256 costA = market.cost();
        LMSRMarket other = _deploy(B);
        vm.startPrank(bob);
        uint256 viaOne = other.buy(1, b, type(uint256).max) + other.buy(0, a, type(uint256).max);
        vm.stopPrank();
        assertEq(other.cost(), costA);
        assertApproxEqAbs(viaZero, viaOne, 4 * market.costError());
    }

    function testFuzz_pool_covers_every_payout(uint256 a, uint256 b, uint256 s) public {
        a = bound(a, 1, 1e24);
        b = bound(b, 1, 1e24);
        _buy(alice, 0, a);
        _buy(bob, 1, b);
        s = bound(s, 1, a);
        _sell(alice, 0, s);
        (uint256 q0, uint256 q1) = market.quantities();
        uint256 pool = points.balanceOf(address(market));
        assertGe(pool, q0 > q1 ? q0 : q1);
    }

    function test_sets_cost_one_point_each_and_keep_prices() public {
        _buy(alice, 0, 40e18);
        (uint256 p0,) = market.prices();
        uint256 before = points.balanceOf(bob);
        vm.prank(bob);
        market.mintSets(7e18);
        assertEq(before - points.balanceOf(bob), 7e18);
        (uint256 p0After,) = market.prices();
        assertEq(p0After, p0);
        vm.prank(bob);
        market.burnSets(7e18);
        assertEq(points.balanceOf(bob), before);
    }

    function test_subsidy_covers_the_exact_bound() public view {
        // b·ln 2 for b = 100e18 is 69.314718055994530941...e18.
        assertGe(market.subsidy(), 69_314_718_055_994_530_942);
        assertEq(market.subsidy(), market.requiredSubsidy());
    }

    // ------------------------------------------------------------ shares for spend

    function test_shares_for_spend_inverts_the_worked_example() public view {
        // 28.0930 points buy (just under) 50 shares at (0, 0).
        uint256 shares = market.sharesForSpend(0, 28_092_980_362_016_137_146 + 4 * market.costError());
        assertApproxEqAbs(shares, 50e18, 1e9);
        assertLe(market.quoteBuy(0, shares), 28_092_980_362_016_137_146 + 4 * market.costError());
    }

    function test_shares_for_zero_spend_is_refused() public {
        vm.expectRevert(LMSRMarket.ZeroAmount.selector);
        market.sharesForSpend(0, 0);
    }

    function test_shares_for_dust_spend_is_zero() public view {
        assertEq(market.sharesForSpend(0, 2 * market.costError()), 0);
    }

    /// END_GOAL failure case 2: far apart quantities, past PRBMath's exp threshold; both
    /// the leader (price ~1) and the laggard (price ~0) are quoted without a revert.
    function test_shares_for_spend_far_apart_never_divides_by_zero() public {
        LMSRMarket thin = _deploy(1e18);
        vm.prank(alice);
        thin.buy(0, 1_000e18, type(uint256).max);
        uint256 lead = thin.sharesForSpend(0, 5e18);
        assertLe(thin.quoteBuy(0, lead), 5e18);
        assertApproxEqAbs(lead, 5e18, 1e6);
        uint256 lag = thin.sharesForSpend(1, 5e18);
        assertLe(thin.quoteBuy(1, lag), 5e18);
        assertGt(lag, 990e18);
    }

    function testFuzz_shares_for_spend_never_overspends(uint256 a, uint256 spend, uint8 outcome) public {
        outcome = uint8(bound(outcome, 0, 1));
        a = bound(a, 0, 1e24);
        spend = bound(spend, 1, 1e24);
        if (a != 0) _buy(bob, 0, a);
        uint256 shares = market.sharesForSpend(outcome, spend);
        if (shares == 0) return;
        assertLe(market.quoteBuy(outcome, shares), spend);
        uint256 before = points.balanceOf(alice);
        _buy(alice, outcome, shares);
        assertLe(before - points.balanceOf(alice), spend);
    }

    // ------------------------------------------------------------ attacker

    function test_reentry_from_the_outcome_callback_is_refused() public {
        Reenterer attacker = new Reenterer(market);
        _give(address(attacker), 1e24);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        attacker.attack();
    }
}

/// Buys, and from the ERC-1155 receive hook tries to sell back before the buy completes.
contract Reenterer is IERC1155Receiver {
    LMSRMarket internal immutable market;

    constructor(LMSRMarket market_) {
        market = market_;
    }

    function attack() external {
        market.buy(0, 1e18, type(uint256).max);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        market.sell(0, 1e18, 0);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId;
    }
}
