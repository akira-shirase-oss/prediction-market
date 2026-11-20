// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/Test.sol";

import {LMSRMarket} from "../../src/LMSRMarket.sol";
import {Fixture} from "../Fixture.sol";

/// The M1 exit gate (docs/END_GOAL.md): the Solidity market and `lmsr-ref` take the same
/// trades and must agree within the stated bound. `lmsr-ref` computes every quantity to
/// 80 decimal places and returns it bracketed as [floor, ceil] in wei, so each check below
/// compares the contract against the exact value.
///
/// Stated bounds, per state reached:
/// - cost:   |C_sol - C_exact| <= ERR(b) = ceil(32·b/1e18) + 1 wei   (LMSRMarket.costError)
/// - prices: p0 + p1 = 1e18 exactly on chain; |p_sol - p_exact| <= PRICE_TOL = 4 wei
/// - a buy charges in [exact cost, exact cost + 4·ERR(b)]; a sell returns in
///   [exact return - 4·ERR(b), exact return]: rounding never favours the trader
/// - subsidy: the market maker's loss max(q) - (pool - subsidy) never exceeds b·ln 2
/// - path independence: C after the sequence equals C reached by buying the final
///   quantities directly
/// - no free profit loop: unwinding every position returns the trader to the starting
///   quantities strictly poorer than they began
///
/// Run: cargo build --release -p lmsr-ref && FOUNDRY_PROFILE=diff forge test
contract DifferentialTest is Fixture {
    uint256 internal constant PRICE_TOL = 4;
    uint256 internal constant OPS = 8;
    uint256 internal constant HEADER = 4;
    uint256 internal constant ROW = 6;
    uint256 internal constant WALLET = 1e33;

    enum Kind {
        Buy0,
        Buy1,
        Sell0,
        Sell1,
        Mint,
        Burn
    }

    string[] internal ops;
    uint256[] internal amounts;
    Kind[] internal kinds;

    function _refBinary() internal view returns (string memory) {
        return vm.envOr("LMSR_REF", string("../target/release/lmsr-ref"));
    }

    function _replay(uint256 b, string[] memory args) internal returns (uint256[] memory) {
        string[] memory cmd = new string[](3 + args.length);
        cmd[0] = _refBinary();
        cmd[1] = "replay";
        cmd[2] = vm.toString(b);
        for (uint256 i = 0; i < args.length; i++) {
            cmd[3 + i] = args[i];
        }
        return abi.decode(vm.ffi(cmd), (uint256[]));
    }

    /// Log-uniform amounts from 1 wei to ~1e6·b, so both the dust edge and the far tail
    /// past EXP_CUTOFF are reached.
    function _amount(uint256 seed, uint256 b) internal pure returns (uint256) {
        uint256 digits = seed % 25;
        uint256 scale = digits < 18 ? 10 ** digits : b * 10 ** (digits - 18);
        return 1 + ((seed >> 8) % scale);
    }

    /// Turns a seed into an op the market accepts, or skips it (kind stays unused).
    function _pick(uint256 seed, uint256 b) internal view returns (bool ok, Kind kind, uint256 amount) {
        kind = Kind(seed % 6);
        amount = _amount(seed >> 8, b);
        (uint256 q0, uint256 q1) = market.quantities();
        uint256 cap = market.MAX_QUANTITY();
        if (kind == Kind.Buy0) amount = _min(amount, cap - q0);
        else if (kind == Kind.Buy1) amount = _min(amount, cap - q1);
        else if (kind == Kind.Sell0) amount = _min(amount, _shares(alice, 0));
        else if (kind == Kind.Sell1) amount = _min(amount, _shares(alice, 1));
        else if (kind == Kind.Mint) amount = _min(amount, _min(cap - q0, cap - q1));
        else amount = _min(amount, _min(_shares(alice, 0), _shares(alice, 1)));
        ok = amount != 0;
    }

    function _min(uint256 a, uint256 c) internal pure returns (uint256) {
        return a < c ? a : c;
    }

    function _name(Kind kind) internal pure returns (string memory) {
        if (kind == Kind.Buy0) return "buy0:";
        if (kind == Kind.Buy1) return "buy1:";
        if (kind == Kind.Sell0) return "sell0:";
        if (kind == Kind.Sell1) return "sell1:";
        if (kind == Kind.Mint) return "mint:";
        return "burn:";
    }

    /// Executes one op on chain as alice; returns the points moved (charged or paid).
    function _exec(Kind kind, uint256 amount) internal returns (uint256 moved) {
        vm.startPrank(alice);
        if (kind == Kind.Buy0) moved = market.buy(0, amount, type(uint256).max);
        else if (kind == Kind.Buy1) moved = market.buy(1, amount, type(uint256).max);
        else if (kind == Kind.Sell0) moved = market.sell(0, amount, 0);
        else if (kind == Kind.Sell1) moved = market.sell(1, amount, 0);
        else if (kind == Kind.Mint) market.mintSets(moved = amount);
        else market.burnSets(moved = amount);
        vm.stopPrank();
    }

    function testFuzz_solidity_agrees_with_lmsr_ref(uint256 bSeed, uint256[OPS] memory seeds) public {
        uint256 b = 10 ** bound(bSeed % 13, 0, 12) * 1e18;
        b += (bSeed >> 8) % b;
        b = _min(b, 1e30);
        _setUpMarket(b);
        _give(alice, WALLET);
        uint256 start = points.balanceOf(alice);
        uint256 err = market.costError();

        uint256[] memory moved = new uint256[](OPS);
        delete ops;
        delete amounts;
        delete kinds;
        for (uint256 i = 0; i < OPS; i++) {
            (bool ok, Kind kind, uint256 amount) = _pick(seeds[i], b);
            if (!ok) continue;
            moved[ops.length] = _exec(kind, amount);
            ops.push(string.concat(_name(kind), vm.toString(amount)));
            amounts.push(amount);
            kinds.push(kind);
            _checkState(b, err, ops.length - 1, moved[ops.length - 1]);
        }
        _checkPathIndependence(b);
        _checkNoProfitLoop(start);
    }

    uint256[] internal lastRef;

    /// Re-replays the prefix through op `i` and checks the state it reached. Replaying the
    /// whole prefix each time keeps the check local; OPS is small.
    function _checkState(uint256 b, uint256 err, uint256 i, uint256 moved) internal {
        uint256[] memory w = _replay(b, ops);
        lastRef = w;
        uint256 r = HEADER + ROW * i;

        // Cost.
        uint256 c = market.cost();
        assertGe(c + err, w[r], "C below exact - ERR");
        assertLe(c, w[r + 1] + err, "C above exact + ERR");

        // Prices.
        (uint256 p0, uint256 p1) = market.prices();
        assertEq(p0 + p1, 1e18, "prices do not sum to 1");
        assertApproxEqAbs(p0, w[r + 2], PRICE_TOL, "p0 off");
        assertApproxEqAbs(p1, w[r + 3], PRICE_TOL, "p1 off");

        // The op's amount, rounded against the trader.
        Kind kind = kinds[i];
        if (kind == Kind.Buy0 || kind == Kind.Buy1) {
            assertGe(moved, w[r + 5], "buy charged below the exact cost");
            assertLe(moved, w[r + 5] + 4 * err, "buy charged above the bound");
        } else if (kind == Kind.Sell0 || kind == Kind.Sell1) {
            assertLe(moved, w[r + 4], "sell paid above the exact return");
            assertGe(moved + 4 * err, w[r + 4], "sell paid below the bound");
        } else {
            assertEq(moved, amounts[i], "a set is not one point");
            assertEq(w[r + 4], amounts[i], "lmsr-ref: a set is not one point");
        }

        // Solvency and the subsidy bound b·ln 2 (header word 1 is its ceiling).
        (uint256 q0, uint256 q1) = market.quantities();
        uint256 maxQ = q0 > q1 ? q0 : q1;
        uint256 pool = points.balanceOf(address(market));
        assertGe(pool, maxQ, "pool does not cover the worst payout");
        uint256 received = pool - market.subsidy();
        uint256 loss = maxQ > received ? maxQ - received : 0;
        assertLe(loss, w[1], "market maker lost more than b ln 2");
    }

    function _checkPathIndependence(uint256 b) internal {
        if (ops.length == 0) return;
        (uint256 q0, uint256 q1) = market.quantities();
        uint256 n = (q0 != 0 ? 1 : 0) + (q1 != 0 ? 1 : 0);
        string[] memory direct = new string[](n);
        uint256 k;
        if (q0 != 0) direct[k++] = string.concat("buy0:", vm.toString(q0));
        if (q1 != 0) direct[k++] = string.concat("buy1:", vm.toString(q1));
        uint256 finalC = lastRef[HEADER + ROW * (ops.length - 1)];
        uint256 directC = n == 0 ? lastRef[2] : _replay(b, direct)[HEADER + ROW * (n - 1)];
        assertEq(directC, finalC, "lmsr-ref: C depends on the path");
        // On chain, C is a pure function of q: a fresh market at the same q agrees exactly.
        LMSRMarket fresh = _deploy(b);
        _give(bob, WALLET);
        vm.startPrank(bob);
        if (q0 != 0) fresh.buy(0, q0, type(uint256).max);
        if (q1 != 0) fresh.buy(1, q1, type(uint256).max);
        vm.stopPrank();
        assertEq(fresh.cost(), market.cost(), "on-chain C depends on the path");
    }

    /// Unwinds every position alice holds back to the market's starting state.
    function _checkNoProfitLoop(uint256 start) internal {
        if (ops.length == 0) return;
        uint256 s0 = _shares(alice, 0);
        uint256 s1 = _shares(alice, 1);
        uint256 sets = _min(s0, s1);
        vm.startPrank(alice);
        if (sets != 0) market.burnSets(sets);
        if (s0 > sets) market.sell(0, s0 - sets, 0);
        if (s1 > sets) market.sell(1, s1 - sets, 0);
        vm.stopPrank();
        (uint256 q0, uint256 q1) = market.quantities();
        assertEq(q0 + q1, 0, "unwind did not return to the start");
        bool traded;
        for (uint256 i = 0; i < kinds.length; i++) {
            if (kinds[i] != Kind.Mint && kinds[i] != Kind.Burn) traded = true;
        }
        if (traded) assertLt(points.balanceOf(alice), start, "a trade loop made a profit");
        else assertEq(points.balanceOf(alice), start, "sets alone moved value");
    }

    /// A deterministic sweep for the PR's numbers: the largest observed cost and price
    /// errors against lmsr-ref across liquidities and spreads 0..45·b (0..1·b at the 1e30 ceiling).
    function test_measured_error_sweep() public {
        uint256[4] memory bs = [uint256(1e18), 37e18 + 123, 1e24 + 7, 1e30];
        uint256 worstCostPerB;
        uint256 worstPrice;
        for (uint256 j = 0; j < bs.length; j++) {
            uint256 b = bs[j];
            _setUpMarket(b);
            _give(alice, WALLET);
            uint256 steps = 180;
            string[] memory args = new string[](steps);
            uint256[] memory cs = new uint256[](steps);
            uint256[] memory ps = new uint256[](steps);
            uint256 step = _min(b / 4 + 12345, market.MAX_QUANTITY() / steps);
            for (uint256 i = 0; i < steps; i++) {
                uint256 amount = i % 7 == 6 ? 1 : step;
                vm.prank(alice);
                market.buy(0, amount, type(uint256).max);
                args[i] = string.concat("buy0:", vm.toString(amount));
                cs[i] = market.cost();
                (ps[i],) = market.prices();
            }
            uint256[] memory w = _replay(b, args);
            for (uint256 i = 0; i < steps; i++) {
                uint256 r = HEADER + ROW * i;
                uint256 ce = cs[i] < w[r] ? w[r] - cs[i] : (cs[i] > w[r + 1] ? cs[i] - w[r + 1] : 0);
                uint256 perB = ce * 1e18 / b;
                if (perB > worstCostPerB) worstCostPerB = perB;
                uint256 pe = ps[i] > w[r + 2] ? ps[i] - w[r + 2] : w[r + 2] - ps[i];
                if (pe > worstPrice) worstPrice = pe;
                assertLe(ce, market.costError(), "sweep: cost error above ERR(b)");
                assertLe(pe, PRICE_TOL, "sweep: price error above PRICE_TOL");
            }
        }
        console.log("worst |C_sol - C_exact| per 1e18 of b (wei):", worstCostPerB);
        console.log("worst |p_sol - p_exact| (wei):", worstPrice);
    }
}
