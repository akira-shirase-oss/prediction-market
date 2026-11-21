//! The LMSR's properties, checked on the reference to 80 decimal places: the worked example
//! in docs/KNOWLEDGE.md, the boundary cases (`END_GOAL` failure case 2), and the invariants
//! (prices sum to one, path independence, the b·ln 2 subsidy bound, no profitable round trip).

use lmsr_ref::{Error, MAX_LIQUIDITY, MAX_QUANTITY, MIN_LIQUIDITY, Market, WAD};
use proptest::prelude::*;

const CENT: u128 = WAD / 100;

fn hundredths(x: u128) -> u128 {
    (x + CENT / 2) / CENT
}

#[test]
fn the_worked_example_in_knowledge() {
    let mut m = Market::new(100 * WAD).unwrap();
    assert_eq!(hundredths(m.max_loss().ceil), 6931);
    assert_eq!(m.prices(), [WAD / 2, WAD / 2]);
    assert_eq!(hundredths(m.shares_for_spend(0, 10 * WAD).unwrap()), 1909);
    let cost = m.buy(0, 50 * WAD).unwrap();
    assert_eq!(hundredths(cost), 2809);
    assert_eq!(m.prices()[0] / (WAD / 1000), 622);
    let back = m.sell(0, 50 * WAD).unwrap();
    assert!(
        back < cost,
        "a round trip must not profit: paid {cost}, got back {back}"
    );
    assert!(cost - back <= 1);

    let mut thin = Market::new(20 * WAD).unwrap();
    assert_eq!(hundredths(thin.buy(0, 50 * WAD).unwrap()), 3771);
    assert_eq!(thin.prices()[0] / (WAD / 1000), 924);
}

#[test]
fn bounds_are_refused() {
    assert_eq!(
        Market::new(MIN_LIQUIDITY - 1),
        Err(Error::LiquidityOutOfRange)
    );
    assert_eq!(
        Market::new(MAX_LIQUIDITY + 1),
        Err(Error::LiquidityOutOfRange)
    );
    assert_eq!(
        Market::with_quantities(WAD, [MAX_QUANTITY + 1, 0]),
        Err(Error::QuantityOverflow)
    );
    let mut m = Market::with_quantities(WAD, [MAX_QUANTITY, 0]).unwrap();
    assert_eq!(m.buy(0, 1), Err(Error::QuantityOverflow));
    assert_eq!(m.buy(1, u128::MAX), Err(Error::QuantityOverflow));
    assert_eq!(m.mint_sets(1), Err(Error::QuantityOverflow));
    assert_eq!(m.buy(0, 0), Err(Error::ZeroAmount));
    assert_eq!(m.sell(1, 1), Err(Error::InsufficientQuantity));
    assert_eq!(m.burn_sets(1), Err(Error::InsufficientQuantity));
    assert_eq!(m.buy(2, 1), Err(Error::InvalidOutcome));
    assert_eq!(m.shares_for_spend(0, 0), Err(Error::ZeroAmount));
}

#[test]
fn far_apart_quantities_price_the_laggard_at_zero_without_failing() {
    // 1,000·b apart: e^-1000 is far below one wei of price.
    let b = WAD;
    let mut m = Market::with_quantities(b, [1000 * b, 0]).unwrap();
    assert_eq!(m.prices(), [WAD, 0]);
    // C(q) is the leader's quantity to within a wei.
    assert!(m.cost().floor >= 1000 * b && m.cost().ceil <= 1000 * b + 1);
    // Just inside PRBMath's exp threshold (-41.45) the laggard's price is a few wei; just
    // past it, below one wei.
    let near = Market::with_quantities(b, [40 * b, 0]).unwrap();
    assert!(near.prices()[1] > 0 && near.prices()[1] < 1_000);
    let past = Market::with_quantities(b, [42 * b, 0]).unwrap();
    assert_eq!(past.prices(), [WAD, 0]);
    // Shares for spend on the zero-priced outcome: no division by its price.
    let shares = m.shares_for_spend(1, WAD).unwrap();
    assert!(shares > 0);
    assert!(m.quote_buy(1, shares).unwrap().ceil <= WAD);
    // The leader: a spend buys about spend/price ≈ spend shares.
    let lead = m.shares_for_spend(0, WAD).unwrap();
    assert!(lead.abs_diff(WAD) <= 2, "lead {lead}");
    m.buy(1, shares).unwrap();
}

fn trades() -> impl Strategy<Value = (u128, Vec<(u8, u128)>)> {
    let b = prop_oneof![
        Just(MIN_LIQUIDITY),
        Just(MAX_LIQUIDITY),
        MIN_LIQUIDITY..=1_000_000 * WAD
    ];
    let size = prop_oneof![
        1u128..=1_000,
        1u128..=1_000 * WAD,
        1u128..=100_000_000 * WAD
    ];
    (b, proptest::collection::vec((0u8..4, size), 1..24))
}

/// Applies `ops` as buys (0, 1) and sells (2, 3), skipping refused ones. Returns the points
/// paid in and paid out.
fn apply(m: &mut Market, ops: &[(u8, u128)]) -> (u128, u128) {
    let (mut paid, mut got) = (0u128, 0u128);
    for &(kind, size) in ops {
        let outcome = usize::from(kind % 2);
        if kind < 2 {
            if let Ok(c) = m.buy(outcome, size) {
                paid += c;
            }
        } else {
            let size = size.min(m.quantities()[outcome]);
            if let Ok(r) = m.sell(outcome, size) {
                got += r;
            }
        }
    }
    (paid, got)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn prices_sum_to_one(b in MIN_LIQUIDITY..=MAX_LIQUIDITY, q0 in 0..=MAX_QUANTITY, q1 in 0..=MAX_QUANTITY) {
        let p = Market::with_quantities(b, [q0, q1]).unwrap().prices();
        prop_assert_eq!(p[0] + p[1], WAD);
        prop_assert!((q0 >= q1) == (p[0] >= p[1]) || q0 == q1);
    }

    #[test]
    fn solvency_and_the_subsidy_bound_hold((b, ops) in trades()) {
        let mut m = Market::new(b).unwrap();
        let subsidy = m.max_loss().ceil;
        let (paid, got) = apply(&mut m, &ops);
        let held = subsidy + paid - got;
        let q = m.quantities();
        // The pool covers every payout ...
        prop_assert!(held >= q[0].max(q[1]), "held {} < max q {:?}", held, q);
        // ... and the maker's worst-case loss never exceeds b·ln 2.
        let worst = q[0].max(q[1]).saturating_sub(paid - got.min(paid));
        prop_assert!(worst <= subsidy);
    }

    #[test]
    fn the_cost_is_path_independent((b, ops) in trades()) {
        let mut m = Market::new(b).unwrap();
        let start = m.cost();
        let (paid, got) = apply(&mut m, &ops);
        let end = m.cost();
        // Each rounding moves at most one wei, in the pool's favour.
        let exact_lo = end.floor.saturating_sub(start.ceil);
        let exact_hi = end.ceil - start.floor;
        let net = paid.cast_signed() - got.cast_signed();
        prop_assert!(net >= exact_lo.cast_signed() - 1);
        prop_assert!(net <= exact_hi.cast_signed() + 25);
    }

    #[test]
    fn a_round_trip_never_profits((b, ops) in trades()) {
        let mut m = Market::new(b).unwrap();
        let (paid, mut got) = apply(&mut m, &ops);
        let q = m.quantities();
        if q[0] > 0 { got += m.sell(0, q[0]).unwrap(); }
        if q[1] > 0 { got += m.sell(1, q[1]).unwrap(); }
        prop_assert_eq!(m.quantities(), [0, 0]);
        prop_assert!(got <= paid, "paid {} got {}", paid, got);
    }

    #[test]
    fn complete_sets_cost_exactly_their_size(b in MIN_LIQUIDITY..=MAX_LIQUIDITY, q0 in 0..MAX_QUANTITY / 2, q1 in 0..MAX_QUANTITY / 2, s in 1..MAX_QUANTITY / 2) {
        let mut m = Market::with_quantities(b, [q0, q1]).unwrap();
        let (before, prices) = (m.cost(), m.prices());
        m.mint_sets(s).unwrap();
        prop_assert_eq!(m.prices(), prices);
        prop_assert!(m.cost().floor.abs_diff(before.floor + s) <= 1);
    }

    #[test]
    fn shares_for_spend_never_overspends(b in MIN_LIQUIDITY..=1_000_000 * WAD, q0 in 0..1_000_000 * WAD, q1 in 0..1_000_000 * WAD, spend in 1u128..=1_000_000 * WAD, outcome in 0usize..2) {
        let m = Market::with_quantities(b, [q0, q1]).unwrap();
        let shares = m.shares_for_spend(outcome, spend).unwrap();
        if shares > 0 {
            prop_assert!(m.quote_buy(outcome, shares).unwrap().ceil <= spend);
        }
        // And one more wei of shares (beyond ~1e-70 slack) would overspend.
        if let Ok(next) = m.quote_buy(outcome, shares + 2) {
            prop_assert!(next.floor + 1 >= spend);
        }
    }
}
