//! Non-negative fixed-point numbers carrying [`PREC`] decimal places, with `exp` and `ln`
//! evaluated by series to below one unit in the last place times a small constant. Every
//! operation floors; the accumulated error is a few hundred units in the 80th decimal, far
//! below the 18-decimal amounts the market deals in.

use num_bigint::BigUint;
use num_traits::{CheckedSub, One, Zero};
use std::sync::OnceLock;

/// Decimal places carried internally.
pub(crate) const PREC: u32 = 80;

/// The fixed-point one, `10^PREC`.
pub(crate) fn one() -> &'static BigUint {
    static ONE: OnceLock<BigUint> = OnceLock::new();
    ONE.get_or_init(|| BigUint::from(10u8).pow(PREC))
}

/// `ln 2` in fixed point.
pub(crate) fn ln2() -> &'static BigUint {
    static LN2: OnceLock<BigUint> = OnceLock::new();
    LN2.get_or_init(|| ln_1_to_2(&(one() * 2u8)))
}

/// `e^-x` for `x >= 0`. Below `e^-200` (about 1e-87, under one unit in the last place) the
/// result is zero.
pub(crate) fn exp_neg(x: &BigUint) -> BigUint {
    let one = one();
    if *x > one * 200u16 {
        return BigUint::zero();
    }
    // x = k·ln2 + r with r in [0, ln2): e^-x = 2^-k / e^r.
    let k = x / ln2();
    let r = x - &k * ln2();
    let er = exp_small(&r);
    let k = u64::try_from(&k).unwrap_or(u64::MAX);
    (one * one / er) >> k
}

/// `e^r` for `0 <= r < 1` by its Taylor series (every term positive).
fn exp_small(r: &BigUint) -> BigUint {
    let one = one();
    let mut sum = one.clone();
    let mut term = one.clone();
    let mut n = 1u32;
    loop {
        term = term * r / (one * n);
        if term.is_zero() {
            return sum;
        }
        sum += &term;
        n += 1;
    }
}

/// `ln x` for `1 <= x <= 2`, as `2·atanh((x-1)/(x+1))`; the series ratio is at most 1/9.
pub(crate) fn ln_1_to_2(x: &BigUint) -> BigUint {
    let one = one();
    debug_assert!(x >= one && *x <= one * 2u8);
    let z = (x - one) * one / (x + one);
    let z2 = &z * &z / one;
    let mut sum = z.clone();
    let mut power = z;
    let mut k = 1u32;
    loop {
        power = power * &z2 / one;
        let term = &power / (2 * k + 1);
        if term.is_zero() {
            return sum * 2u8;
        }
        sum += term;
        k += 1;
    }
}

/// `-ln y` for `0 < y <= 1`, by scaling `y` into `[1, 2)` with a power of two.
/// `None` for `y == 0` or `y > 1`.
pub(crate) fn neg_ln_unit(y: &BigUint) -> Option<BigUint> {
    let one = one();
    if y.is_zero() || y > one {
        return None;
    }
    let mut k = 0u64;
    let mut scaled = y.clone();
    // Shift to the bit length of one, then at most one more doubling lands in [1, 2).
    let shift = one.bits().saturating_sub(y.bits());
    scaled <<= shift;
    k += shift;
    if scaled < *one {
        scaled <<= 1u8;
        k += 1;
    }
    let ln_scaled = ln_1_to_2(&scaled);
    // -ln y = k·ln2 - ln(scaled), and k·ln2 >= ln(scaled) because y <= 1.
    Some(
        (ln2() * BigUint::from(k))
            .checked_sub(&ln_scaled)
            .unwrap_or_default(),
    )
}

/// `x / 10^PREC`, rounded down and up.
pub(crate) fn to_int(x: &BigUint) -> (BigUint, BigUint) {
    let floor = x / one();
    let ceil = if (&floor * one()) == *x {
        floor.clone()
    } else {
        &floor + BigUint::one()
    };
    (floor, ceil)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn digits(x: &BigUint, n: usize) -> String {
        let s = x.to_string();
        s[..n.min(s.len())].to_owned()
    }

    #[test]
    fn ln2_and_e_match_published_digits() {
        // OEIS A002162 (ln 2) and A001113 (e), first 50 digits.
        assert_eq!(
            digits(ln2(), 50),
            "69314718055994530941723212145817656807550013436025"
        );
        let e_inv = exp_neg(one());
        let e = one() * one() / e_inv;
        assert_eq!(
            digits(&e, 50),
            "27182818284590452353602874713526624977572470936999"
        );
    }

    #[test]
    fn exp_and_ln_invert_each_other() {
        for milli in [0u32, 1, 250, 500, 693, 999, 1000] {
            let x = one() * milli / 1000u32;
            let y = exp_neg(&x);
            let back = neg_ln_unit(&y).unwrap_or_default();
            let err = if back > x { &back - &x } else { &x - &back };
            assert!(
                err < BigUint::from(10u8).pow(PREC - 70),
                "x={milli}/1000 err={err}"
            );
        }
    }

    #[test]
    fn far_tail_is_zero_and_ln_refuses_outside_its_domain() {
        assert!(exp_neg(&(one() * 201u16)).is_zero());
        assert_eq!(exp_neg(&BigUint::zero()), *one());
        assert!(neg_ln_unit(&BigUint::zero()).is_none());
        assert!(neg_ln_unit(&(one() + 1u8)).is_none());
        assert_eq!(neg_ln_unit(one()), Some(BigUint::zero()));
    }
}
