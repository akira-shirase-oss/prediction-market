// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../Fixture.sol";

/// Points are not transferable by token calls, but value can move between accounts through
/// any market (docs/DECISIONS.md D-007, docs/THREATS.md T-1). From q = (0, 0), with
/// L(D) = b·ln(1 + e^(-D/b)): A buys D of outcome 1, B buys D of outcome 0, A sells D of 1,
/// B sells D of 0. B gains about D - 2·b·ln 2 and the pair pays the pool only the rounding
/// margins, whatever D is. These tests pin that size, so points must never confer rank.
contract ValueMovesTest is Fixture {
    /// ceil(1e18·ln 2), from lmsr-ref.
    uint256 internal constant MAX_LOSS_B1 = 693147180559945310;

    function setUp() public {
        _setUpMarket(1e18);
    }

    /// Returns what B gained and what the pair paid the pool.
    function _move(uint256 d) internal returns (uint256 gained, uint256 pairCost) {
        _give(alice, 2 * d);
        _give(bob, 2 * d);
        uint256 a0 = points.balanceOf(alice);
        uint256 b0 = points.balanceOf(bob);
        uint256 pool0 = points.balanceOf(address(market));
        vm.prank(alice);
        market.buy(1, d, type(uint256).max);
        vm.prank(bob);
        market.buy(0, d, type(uint256).max);
        vm.prank(alice);
        market.sell(1, d, 0);
        vm.prank(bob);
        market.sell(0, d, 0);
        (uint256 q0, uint256 q1) = market.quantities();
        assertEq(q0 + q1, 0, "the pair did not unwind");
        uint256 lost = a0 - points.balanceOf(alice);
        gained = points.balanceOf(bob) - b0;
        pairCost = lost - gained;
        assertEq(points.balanceOf(address(market)) - pool0, pairCost, "the pool kept other than the pair's cost");
    }

    /// The reviewed example: b = 1e18, D = 1e6 points. B receives ~999,998.6 of A's points.
    function test_a_pair_of_accounts_moves_points_through_a_market() public {
        uint256 d = 1_000_000e18;
        uint256 e = market.costError();
        (uint256 gained, uint256 pairCost) = _move(d);
        // Each charge is within [exact, exact + 4·ERR] and each payout within [exact - 4·ERR, exact].
        assertGe(gained, d - 2 * MAX_LOSS_B1 - 8 * e, "B gained less than D - 2*b*ln 2 - 8*ERR");
        assertLe(gained, d - 2 * (MAX_LOSS_B1 - 1), "B gained more than D - 2*b*ln 2");
        assertLe(pairCost, 16 * e, "the move cost the pair more than 16*ERR");
        assertEq(gained, 999_998_613_705_638_880_109_250, "the pinned size moved");
        assertEq(pairCost, 264, "the pinned cost moved");
    }

    /// The pair's cost does not grow with D: raising b's floor would not stop the move.
    function testFuzz_the_pair_cost_is_independent_of_the_size(uint256 d) public {
        d = bound(d, 2e18, 1e29);
        (uint256 gained, uint256 pairCost) = _move(d);
        assertLe(pairCost, 16 * market.costError(), "the move cost the pair more than 16*ERR");
        assertGe(gained + 2 * MAX_LOSS_B1 + 16 * market.costError(), d, "B gained less than D - 2*b*ln 2 - 16*ERR");
    }
}
