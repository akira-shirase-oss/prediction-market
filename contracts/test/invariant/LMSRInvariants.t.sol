// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {OutcomeToken} from "../../src/OutcomeToken.sol";
import {PointsToken} from "../../src/PointsToken.sol";

/// Drives three markets (b at the floor, a typical b, b at the ceiling) with random
/// trades from three traders, dust and boundary sizes included, plus transfer attempts
/// run as the holder and, in the resolution campaign, an occasional close, resolve and redeem.
contract Handler is Test {
    PointsToken internal immutable points;
    OutcomeToken internal immutable outcomes;
    LMSRMarket[3] internal markets;
    address internal immutable admin;
    address internal immutable resolver;
    address[3] internal actors;

    uint256 public profitableRoundTrips;
    uint256 public transfersThatMovedPoints;
    uint256 public transfersThatMovedShares;
    /// A transfer attempt that succeeded, or reverted for a reason other than the token's own
    /// no-transfer error (an approval check, say): the refusal under test did not run.
    uint256 public transfersRefusedForAnotherReason;
    /// Outcome transfer attempts where `from` held the shares it tried to move.
    uint256 public heldShareTransfersTried;
    uint256 public calls;
    /// Ghost: trades that executed (a round trip is two); the LT-5 threshold counts these.
    uint256 public trades;
    uint256 public resolutions;

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
        trades++;
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
        trades++;
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
        trades++;
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
        trades += 2;
        if (points.balanceOf(who) >= before) profitableRoundTrips++;
    }

    function _refused(bytes memory reason, bytes4 expected) internal {
        if (reason.length < 4 || bytes4(reason) != expected) transfersRefusedForAnotherReason++;
    }

    function _tryPoints(address from, address to, uint256 amount, bool viaAllowance) internal {
        bytes4 noPoints = PointsToken.PointsNotTransferable.selector;
        vm.prank(from);
        if (!viaAllowance) {
            try points.transfer(to, amount) {
                transfersRefusedForAnotherReason++;
            } catch (bytes memory r) {
                _refused(r, noPoints);
            }
            return;
        }
        try points.approve(to, amount) {
            transfersRefusedForAnotherReason++;
        } catch (bytes memory r) {
            _refused(r, noPoints);
        }
        vm.prank(to);
        try points.transferFrom(from, to, amount) {
            transfersRefusedForAnotherReason++;
        } catch (bytes memory r) {
            _refused(r, noPoints);
        }
    }

    function _tryShares(address from, address to, uint256 id, uint256 held, uint256 seed) internal {
        uint256 n = held == 0 ? 1 : 1 + (seed >> 1) % held;
        if (held != 0) heldShareTransfersTried++;
        // The id is computed before the prank: an external call in the arguments would take it.
        vm.prank(from);
        try outcomes.safeTransferFrom(from, to, id, n, "") {
            transfersRefusedForAnotherReason++;
        } catch (bytes memory r) {
            _refused(r, OutcomeToken.OutcomeNotTransferable.selector);
        }
    }

    function _tryBatch(address from, address to, uint256 id0, uint256 id1, uint256 held0, uint256 held1, uint256 seed)
        internal
    {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory ns = new uint256[](2);
        ids[0] = id0;
        ids[1] = id1;
        ns[0] = held0 == 0 ? 1 : 1 + seed % held0;
        ns[1] = held1 == 0 ? 1 : 1 + (seed >> 128) % held1;
        if (held0 != 0 || held1 != 0) heldShareTransfersTried++;
        vm.prank(from);
        try outcomes.safeBatchTransferFrom(from, to, ids, ns, "") {
            transfersRefusedForAnotherReason++;
        } catch (bytes memory r) {
            _refused(r, OutcomeToken.OutcomeNotTransferable.selector);
        }
    }

    function _checkUnmoved(address from, address to, uint256 id0, uint256 id1, uint256[6] memory before) internal {
        if (points.balanceOf(from) != before[0] || points.balanceOf(to) != before[1]) transfersThatMovedPoints++;
        if (
            outcomes.balanceOf(from, id0) != before[2] || outcomes.balanceOf(from, id1) != before[3]
                || outcomes.balanceOf(to, id0) != before[4] || outcomes.balanceOf(to, id1) != before[5]
        ) transfersThatMovedShares++;
    }

    /// Invariant 7: every token call that would move points or shares between two accounts,
    /// made as the holder, is refused by the token's own no-transfer error.
    function transferPoints(uint256 aSeed, uint256 bSeed, uint256 amount, uint8 how, uint256 mSeed) external {
        calls++;
        address from = actors[aSeed % 3];
        address to = actors[(aSeed % 3 + 1 + bSeed % 2) % 3];
        uint256 id0 = outcomes.tokenId(address(markets[mSeed % 3]), 0);
        uint256 id1 = id0 | 1;
        uint256[6] memory before = [
            points.balanceOf(from),
            points.balanceOf(to),
            outcomes.balanceOf(from, id0),
            outcomes.balanceOf(from, id1),
            outcomes.balanceOf(to, id0),
            outcomes.balanceOf(to, id1)
        ];
        uint256 path = how % 4;
        if (path < 2) {
            _tryPoints(from, to, bound(amount, 1, before[0] + 1), path == 1);
        } else if (path == 2) {
            _tryShares(from, to, amount % 2 == 0 ? id0 : id1, amount % 2 == 0 ? before[2] : before[3], amount);
        } else {
            _tryBatch(from, to, id0, id1, before[2], before[3], amount);
        }
        _checkUnmoved(from, to, id0, id1, before);
    }

    /// Rare (1 in 64, hashed so the fuzzer's dictionary values, multiples of 64, do not bias
    /// it): close a market, resolve it, and redeem every winner. Only the resolution campaign
    /// targets it; closes are staggered there, so resolving one market leaves later ones open.
    function resolveAndRedeem(uint256 mSeed, uint8 outcome, uint256 chance) external {
        calls++;
        if (uint256(keccak256(abi.encode(chance))) % 64 != 0) return;
        LMSRMarket m = markets[mSeed % 3];
        if (m.resolved()) return;
        if (block.timestamp < m.closeTime()) vm.warp(m.closeTime());
        vm.prank(resolver);
        m.resolve(outcome % 2);
        resolutions++;
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

/// The campaigns' shared deployment, invariants and ghost report. LT-5 (docs/END_GOAL.md) at
/// full scale is FOUNDRY_PROFILE=lt5 through scripts/lt5.sh; thresholds in perf/scenarios/lt5.md.
abstract contract InvariantBase is Test {
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

    function _closeTime(uint256 i) internal view virtual returns (uint64);

    function _targets() internal view virtual returns (bytes4[] memory);

    function _campaign() internal pure virtual returns (string memory);

    function setUp() public {
        points = new PointsToken(admin);
        outcomes = new OutcomeToken(admin);
        address[3] memory actors = [makeAddr("trader0"), makeAddr("trader1"), makeAddr("trader2")];
        vm.startPrank(admin);
        points.grantRole(points.MINTER_ROLE(), admin);
        outcomes.grantRole(outcomes.REGISTRAR_ROLE(), admin);
        for (uint256 i = 0; i < 3; i++) {
            markets[i] = new LMSRMarket(points, outcomes, liquidities[i], _closeTime(i), resolver);
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
        targetSelector(FuzzSelector({addr: address(handler), selectors: _targets()}));
    }

    /// One file per run, "trades calls held-share-transfers resolutions", when scripts/lt5.sh
    /// names a directory (only the lt5 profile may write there). Named by a fingerprint of the
    /// run's end state, so parallel workers never share a file and a repeated call on the last
    /// run rewrites its own.
    function afterInvariant() public {
        string memory dir = vm.envOr("LT5_GHOST_DIR", string(""));
        if (bytes(dir).length == 0) return;
        vm.writeFile(
            string.concat(dir, "/", _campaign(), "-", vm.toString(_fingerprint()), ".txt"),
            string.concat(
                vm.toString(handler.trades()),
                " ",
                vm.toString(handler.calls()),
                " ",
                vm.toString(handler.heldShareTransfersTried()),
                " ",
                vm.toString(handler.resolutions()),
                "\n"
            )
        );
    }

    function _fingerprint() internal view returns (bytes32 h) {
        h = keccak256(abi.encode(handler.trades(), handler.calls(), block.timestamp));
        for (uint256 i = 0; i < 3; i++) {
            (uint256 q0, uint256 q1) = markets[i].quantities();
            h = keccak256(
                abi.encode(h, q0, q1, points.balanceOf(handler.actor(i)), points.balanceOf(address(markets[i])))
            );
        }
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

    function invariant_shares_are_not_transferable() public view {
        assertEq(handler.transfersThatMovedShares(), 0);
    }

    /// The no-transfer errors themselves refused every attempt: a test that reverts for
    /// another reason (a lost prank, an approval check) proves nothing about invariant 7.
    function invariant_transfers_are_refused_by_the_token() public view {
        assertEq(handler.transfersRefusedForAnotherReason(), 0);
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

/// The trading campaign: every market shares one close a month out and nothing warps time, so
/// every trade a run asks for executes. LT-5's executed-trade threshold applies here.
contract LMSRInvariants is InvariantBase {
    function _closeTime(uint256) internal view override returns (uint64) {
        return uint64(block.timestamp + 30 days);
    }

    function _targets() internal pure override returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = Handler.buy.selector;
        s[1] = Handler.sell.selector;
        s[2] = Handler.sets.selector;
        s[3] = Handler.roundTrip.selector;
        s[4] = Handler.transferPoints.selector;
    }

    function _campaign() internal pure override returns (string memory) {
        return "trading";
    }

    /// Nothing in this campaign closes a market: a run never degrades into no-op calls.
    function invariant_markets_stay_open() public view {
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(markets[i].resolved());
            assertLt(block.timestamp, markets[i].closeTime());
        }
    }
}

/// The resolution campaign: the same handler plus close, resolve and redeem, with closes
/// staggered 10, 20 and 30 days out so resolving one market leaves the later ones trading.
contract LMSRInvariantsResolution is InvariantBase {
    function _closeTime(uint256 i) internal view override returns (uint64) {
        return uint64(block.timestamp + (i + 1) * 10 days);
    }

    function _targets() internal pure override returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = Handler.buy.selector;
        s[1] = Handler.sell.selector;
        s[2] = Handler.sets.selector;
        s[3] = Handler.roundTrip.selector;
        s[4] = Handler.transferPoints.selector;
        s[5] = Handler.resolveAndRedeem.selector;
    }

    function _campaign() internal pure override returns (string memory) {
        return "resolution";
    }
}
