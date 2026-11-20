// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {OutcomeToken} from "../../src/OutcomeToken.sol";
import {PointsToken} from "../../src/PointsToken.sol";

/// Drives three markets (b at the floor, a typical b, b at the ceiling) with random
/// trades from three traders, dust and boundary sizes included, plus transfer attempts
/// and an occasional close, resolve and redeem.
contract Handler is Test {
    PointsToken internal immutable points;
    OutcomeToken internal immutable outcomes;
    LMSRMarket[3] internal markets;
    address internal immutable admin;
    address internal immutable resolver;
    address[3] internal actors;

    uint256 public profitableRoundTrips;
    uint256 public transfersThatMovedPoints;
    uint256 public calls;

    constructor(
        PointsToken points_,
        OutcomeToken outcomes_,
        LMSRMarket[3] memory markets_,
        address admin_,
        address resolver_,
        address[3] memory actors_
    ) {
        points = points_;
        outcomes = outcomes_;
        markets = markets_;
        admin = admin_;
        resolver = resolver_;
        actors = actors_;
    }

    /// Dust (1 wei), boundary (the room left under MAX_QUANTITY) and log-uniform sizes.
    function _size(uint256 seed, uint256 b, uint256 room) internal pure returns (uint256) {
        if (room == 0) return 0;
        uint256 pick = seed % 8;
        if (pick == 0) return 1;
        if (pick == 1) return room;
        uint256 digits = (seed >> 3) % 25;
        uint256 scale = digits < 18 ? 10 ** digits : b * 10 ** (digits - 18);
        uint256 amount = 1 + ((seed >> 16) % scale);
        return amount < room ? amount : room;
    }

    function _open(LMSRMarket m) internal view returns (bool) {
        return !m.resolved() && block.timestamp < m.closeTime();
    }

    function _held(LMSRMarket m, address who, uint8 outcome) internal view returns (uint256) {
        return outcomes.balanceOf(who, outcomes.tokenId(address(m), outcome));
    }

    function buy(uint256 mSeed, uint256 aSeed, uint8 outcome, uint256 size) external {
        calls++;
        LMSRMarket m = markets[mSeed % 3];
        if (!_open(m)) return;
        outcome %= 2;
        (uint256 q0, uint256 q1) = m.quantities();
        uint256 shares = _size(size, m.liquidity(), m.MAX_QUANTITY() - (outcome == 0 ? q0 : q1));
        if (shares == 0) return;
        vm.prank(actors[aSeed % 3]);
        m.buy(outcome, shares, type(uint256).max);
    }

    function sell(uint256 mSeed, uint256 aSeed, uint8 outcome, uint256 size) external {
        calls++;
        LMSRMarket m = markets[mSeed % 3];
        if (!_open(m)) return;
        outcome %= 2;
        address who = actors[aSeed % 3];
        uint256 shares = _size(size, m.liquidity(), _held(m, who, outcome));
        if (shares == 0) return;
        vm.prank(who);
        m.sell(outcome, shares, 0);
    }

    function sets(uint256 mSeed, uint256 aSeed, bool mint, uint256 size) external {
        calls++;
        LMSRMarket m = markets[mSeed % 3];
        if (!_open(m)) return;
        address who = actors[aSeed % 3];
        (uint256 q0, uint256 q1) = m.quantities();
        uint256 room;
        if (mint) room = m.MAX_QUANTITY() - (q0 > q1 ? q0 : q1);
        else room = _held(m, who, 0) < _held(m, who, 1) ? _held(m, who, 0) : _held(m, who, 1);
        uint256 n = _size(size, m.liquidity(), room);
        if (n == 0) return;
        vm.prank(who);
        if (mint) m.mintSets(n);
        else m.burnSets(n);
    }

    /// Invariant 3: a buy followed by selling the same shares never returns more points.
    function roundTrip(uint256 mSeed, uint256 aSeed, uint8 outcome, uint256 size) external {
        calls++;
        LMSRMarket m = markets[mSeed % 3];
        if (!_open(m)) return;
        outcome %= 2;
        (uint256 q0, uint256 q1) = m.quantities();
        uint256 shares = _size(size, m.liquidity(), m.MAX_QUANTITY() - (outcome == 0 ? q0 : q1));
        if (shares == 0) return;
        address who = actors[aSeed % 3];
        uint256 before = points.balanceOf(who);
        vm.startPrank(who);
        m.buy(outcome, shares, type(uint256).max);
        m.sell(outcome, shares, 0);
        vm.stopPrank();
        if (points.balanceOf(who) >= before) profitableRoundTrips++;
    }

    /// Invariant 7: every way of moving points between accounts is refused.
    function transferPoints(uint256 aSeed, uint256 bSeed, uint256 amount, uint8 how) external {
        calls++;
        address from = actors[aSeed % 3];
        address to = actors[bSeed % 3];
        amount = bound(amount, 1, points.balanceOf(from) + 1);
        uint256 before = points.balanceOf(to);
        vm.prank(from);
        if (how % 3 == 0) {
            try points.transfer(to, amount) {} catch {}
        } else if (how % 3 == 1) {
            try points.approve(to, amount) {} catch {}
            vm.prank(to);
            try points.transferFrom(from, to, amount) {} catch {}
        } else {
            try outcomes.safeTransferFrom(from, to, outcomes.tokenId(address(markets[0]), 0), 1, "") {} catch {}
        }
        if (from != to && points.balanceOf(to) != before) transfersThatMovedPoints++;
    }

    /// Rare (1 in 64): close a market, resolve it, and redeem every winner.
    function resolveAndRedeem(uint256 mSeed, uint8 outcome, uint256 chance) external {
        calls++;
        if (chance % 64 != 0) return;
        LMSRMarket m = markets[mSeed % 3];
        if (m.resolved()) return;
        if (block.timestamp < m.closeTime()) vm.warp(m.closeTime());
        vm.prank(resolver);
        m.resolve(outcome % 2);
        for (uint256 i = 0; i < 3; i++) {
            uint256 held = _held(m, actors[i], outcome % 2);
            if (held == 0) continue;
            vm.prank(actors[i]);
            m.redeem(held);
        }
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function market(uint256 i) external view returns (LMSRMarket) {
        return markets[i];
    }
}

/// LT-5 (docs/END_GOAL.md): at full scale, FOUNDRY_PROFILE=lt5 runs it at
/// 4,000 runs x depth 256 = 1,024,000 handler calls; thresholds in perf/scenarios/lt5.md.
contract LMSRInvariants is Test {
    PointsToken internal points;
    OutcomeToken internal outcomes;
    Handler internal handler;
    LMSRMarket[3] internal markets;
    address internal admin = makeAddr("admin");
    address internal resolver = makeAddr("resolver");
    address internal funder = makeAddr("funder");

    /// ceil(b·ln 2) from lmsr-ref, for each market's b.
    uint256[3] internal maxLoss = [uint256(693147180559945310), 69314718055994530942, 693147180559945309417232121459];
    uint256[3] internal liquidities = [uint256(1e18), 100e18, 1e30];

    function setUp() public {
        points = new PointsToken(admin);
        outcomes = new OutcomeToken(admin);
        address[3] memory actors = [makeAddr("trader0"), makeAddr("trader1"), makeAddr("trader2")];
        vm.startPrank(admin);
        points.grantRole(points.MINTER_ROLE(), admin);
        outcomes.grantRole(outcomes.REGISTRAR_ROLE(), admin);
        for (uint256 i = 0; i < 3; i++) {
            markets[i] = new LMSRMarket(points, outcomes, liquidities[i], uint64(block.timestamp + 30 days), resolver);
            points.grantRole(points.MARKET_ROLE(), address(markets[i]));
            outcomes.registerMarket(address(markets[i]));
            points.mint(funder, markets[i].requiredSubsidy());
        }
        for (uint256 i = 0; i < 3; i++) {
            points.mint(actors[i], 1e34);
        }
        vm.stopPrank();
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(funder);
            markets[i].fund();
        }
        handler = new Handler(points, outcomes, markets, admin, resolver, actors);
        targetContract(address(handler));
    }

    /// Invariant 1: every open market holds at least its largest outstanding quantity; a
    /// resolved one at least its unredeemed winning shares (losing shares pay nothing).
    function invariant_solvency() public view {
        for (uint256 i = 0; i < 3; i++) {
            LMSRMarket m = markets[i];
            (uint256 q0, uint256 q1) = m.quantities();
            uint256 owed = m.resolved() ? (m.winner() == 0 ? q0 : q1) : (q0 > q1 ? q0 : q1);
            assertGe(points.balanceOf(address(m)), owed);
        }
    }

    /// The subsidy bound: the market maker never loses more than b·ln 2.
    function invariant_loss_within_b_ln_2() public view {
        for (uint256 i = 0; i < 3; i++) {
            LMSRMarket m = markets[i];
            if (m.resolved()) continue;
            (uint256 q0, uint256 q1) = m.quantities();
            uint256 maxQ = q0 > q1 ? q0 : q1;
            uint256 received = points.balanceOf(address(m)) - m.subsidy();
            uint256 loss = maxQ > received ? maxQ - received : 0;
            assertLe(loss, maxLoss[i]);
        }
    }

    /// Invariant 2: prices sum to exactly 1e18 (unsigned, so none is negative).
    function invariant_prices_sum_to_one() public view {
        for (uint256 i = 0; i < 3; i++) {
            (uint256 p0, uint256 p1) = markets[i].prices();
            assertEq(p0 + p1, 1e18);
        }
    }

    function invariant_round_trips_never_profit() public view {
        assertEq(handler.profitableRoundTrips(), 0);
    }

    function invariant_points_are_not_transferable() public view {
        assertEq(handler.transfersThatMovedPoints(), 0);
    }

    /// Outcome supply equals the market's quantities (minus what was redeemed).
    function invariant_outcome_supply_matches_quantities() public view {
        for (uint256 i = 0; i < 3; i++) {
            (uint256 q0, uint256 q1) = markets[i].quantities();
            uint256 s0;
            uint256 s1;
            for (uint256 a = 0; a < 3; a++) {
                s0 += outcomes.balanceOf(handler.actor(a), outcomes.tokenId(address(markets[i]), 0));
                s1 += outcomes.balanceOf(handler.actor(a), outcomes.tokenId(address(markets[i]), 1));
            }
            assertEq(s0, q0);
            assertEq(s1, q1);
        }
    }

    /// Points are only minted by the minter; trading moves them, never creates them.
    function invariant_points_are_conserved() public view {
        uint256 sum = points.balanceOf(funder);
        for (uint256 i = 0; i < 3; i++) {
            sum += points.balanceOf(address(markets[i])) + points.balanceOf(handler.actor(i));
        }
        assertEq(sum, points.totalSupply());
    }
}
