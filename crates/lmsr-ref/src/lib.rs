//! `lmsr-ref`: the reference binary LMSR market maker.
//!
//! Hanson's cost function `C(q) = b·ln(e^(q0/b) + e^(q1/b))` in its stable form
//! `C(q) = m + b·ln(1 + e^(-|q0-q1|/b))`, `m = max(q0, q1)`, evaluated to 80 decimal places
//! (see `fixed`). Amounts are integers in wei (18 decimals), as on chain. Each exact value
//! comes back as a [`Bracket`] — its floor and ceiling in wei — so a caller can round in the
//! pool's favour: a buy charges the ceiling, a sell pays the floor.
//!
//! The Solidity market (`contracts/src/LMSRMarket.sol`) is differentially fuzzed against this
//! crate; its bounds ([`MIN_LIQUIDITY`], [`MAX_LIQUIDITY`], [`MAX_QUANTITY`]) are the same.

mod fixed;
pub mod replay;

use fixed::{exp_neg, ln_1_to_2, ln2, neg_ln_unit, one, to_int};
use num_bigint::BigUint;
use num_traits::CheckedSub;

/// One share or one point, in wei.
pub const WAD: u128 = 1_000_000_000_000_000_000;
/// The smallest liquidity parameter `b` a market may have: one point.
pub const MIN_LIQUIDITY: u128 = WAD;
/// The largest liquidity parameter `b`: 10^12 points.
pub const MAX_LIQUIDITY: u128 = 1_000_000_000_000 * WAD;
/// The largest outstanding quantity of either outcome: 10^12 shares.
pub const MAX_QUANTITY: u128 = 1_000_000_000_000 * WAD;
/// Tries `shares_for_spend` makes stepping back over a boundary case, as on the Solidity side.
pub const STEP_BACK: usize = 8; // LIMIT(step-back)

/// Why a trade or a market was refused. The Solidity market refuses the same inputs with
/// errors of the same names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    #[error("the liquidity parameter is outside [MIN_LIQUIDITY, MAX_LIQUIDITY]")]
    LiquidityOutOfRange,
    #[error("the outcome index is not 0 or 1")]
    InvalidOutcome,
    #[error("a trade of zero shares")]
    ZeroAmount,
    #[error("the trade would take an outstanding quantity above MAX_QUANTITY")]
    QuantityOverflow,
    #[error("the trade would sell more shares than are outstanding")]
    InsufficientQuantity,
}

/// An exact value's floor and ceiling in wei (equal when the value is a whole number of wei).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Bracket {
    pub floor: u128,
    pub ceil: u128,
}

impl Bracket {
    fn of(scaled: &BigUint) -> Self {
        let (floor, ceil) = to_int(scaled);
        // Every value here is at most MAX_QUANTITY·2 + MAX_LIQUIDITY·ln 2, far below u128::MAX.
        Self {
            floor: u128::try_from(floor).unwrap_or(u128::MAX),
            ceil: u128::try_from(ceil).unwrap_or(u128::MAX),
        }
    }
}

/// A binary LMSR market's state: the liquidity parameter and the outstanding quantity of
/// each outcome, all in wei.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Market {
    b: u128,
    q: [u128; 2],
}

impl Market {
    /// A market with no shares outstanding.
    pub fn new(b: u128) -> Result<Self, Error> {
        Self::with_quantities(b, [0, 0])
    }

    /// A market at a given state.
    pub fn with_quantities(b: u128, q: [u128; 2]) -> Result<Self, Error> {
        if !(MIN_LIQUIDITY..=MAX_LIQUIDITY).contains(&b) {
            return Err(Error::LiquidityOutOfRange);
        }
        if q.iter().any(|&x| x > MAX_QUANTITY) {
            return Err(Error::QuantityOverflow);
        }
        Ok(Self { b, q })
    }

    pub fn liquidity(&self) -> u128 {
        self.b
    }

    pub fn quantities(&self) -> [u128; 2] {
        self.q
    }

    /// `C(q)`, exactly (bracketed in wei).
    pub fn cost(&self) -> Bracket {
        Bracket::of(&self.cost_scaled(self.q))
    }

    /// The market maker's worst-case loss `b·ln 2`, the subsidy a creator must lock.
    pub fn max_loss(&self) -> Bracket {
        Bracket::of(&(ln2() * self.b))
    }

    /// Prices in wei per share (1e18 = certainty). The trailing outcome's price is rounded
    /// down and the leader's is the remainder, so the two always sum to exactly 1e18.
    pub fn prices(&self) -> [u128; 2] {
        let (lead, _) = self.leader();
        let e = exp_neg(&self.spread(self.q));
        let lag_price = &e * WAD / (one() + &e);
        let lag_price = u128::try_from(lag_price).unwrap_or(0);
        let mut p = [0u128; 2];
        p[lead] = WAD - lag_price;
        p[1 - lead] = lag_price;
        p
    }

    /// The exact cost of buying `shares` of `outcome`: `C(q + shares·e_i) - C(q)`.
    pub fn quote_buy(&self, outcome: usize, shares: u128) -> Result<Bracket, Error> {
        let after = self.bought(outcome, shares)?;
        Ok(Bracket::of(
            &(self.cost_scaled(after) - self.cost_scaled(self.q)),
        ))
    }

    /// The exact return from selling `shares` of `outcome`: `C(q) - C(q - shares·e_i)`.
    pub fn quote_sell(&self, outcome: usize, shares: u128) -> Result<Bracket, Error> {
        let after = self.sold(outcome, shares)?;
        Ok(Bracket::of(
            &(self.cost_scaled(self.q) - self.cost_scaled(after)),
        ))
    }

    /// Buys `shares` of `outcome`, returning the points charged: the exact cost rounded up.
    pub fn buy(&mut self, outcome: usize, shares: u128) -> Result<u128, Error> {
        let charged = self.quote_buy(outcome, shares)?.ceil;
        self.q = self.bought(outcome, shares)?;
        Ok(charged)
    }

    /// Sells `shares` of `outcome`, returning the points paid: the exact return rounded down.
    pub fn sell(&mut self, outcome: usize, shares: u128) -> Result<u128, Error> {
        let paid = self.quote_sell(outcome, shares)?.floor;
        self.q = self.sold(outcome, shares)?;
        Ok(paid)
    }

    /// Mints `sets` complete sets (one of each outcome) for exactly `sets` points.
    /// `C(q + s·1) = C(q) + s`, so prices do not move.
    pub fn mint_sets(&mut self, sets: u128) -> Result<u128, Error> {
        let after = self.bought(1, sets)?;
        let after = Self {
            b: self.b,
            q: after,
        }
        .bought(0, sets)?;
        self.q = after;
        Ok(sets)
    }

    /// Burns `sets` complete sets back into exactly `sets` points.
    pub fn burn_sets(&mut self, sets: u128) -> Result<u128, Error> {
        let after = self.sold(1, sets)?;
        let after = Self {
            b: self.b,
            q: after,
        }
        .sold(0, sets)?;
        self.q = after;
        Ok(sets)
    }

    /// How many shares of `outcome` a spend of `spend` points buys at the exact cost, rounded
    /// down, so `quote_buy(outcome, result).ceil <= spend`. Uses the stable inversion
    /// `q_i + Δ = C' + b·ln(1 - e^((q_j - C')/b))` with `C' = C(q) + spend`; it never divides
    /// by a price, so an outcome priced at zero is handled. Zero when `spend` buys less than one
    /// wei of shares.
    pub fn shares_for_spend(&self, outcome: usize, spend: u128) -> Result<u128, Error> {
        if outcome > 1 {
            return Err(Error::InvalidOutcome);
        }
        if spend == 0 {
            return Err(Error::ZeroAmount);
        }
        let one = one();
        let target = self.cost_scaled(self.q) + one * spend;
        let other = one * self.q[1 - outcome];
        // C' > C(q) >= q_j, so t > 0; spend >= 1 wei and b <= 1e30 keep t >= 1e-30.
        let t = (&target - &other) / self.b;
        let complement = one - exp_neg(&t);
        let Some(neg_ln) = neg_ln_unit(&complement) else {
            return Ok(0);
        };
        let reach = target.checked_sub(&(neg_ln * self.b)).unwrap_or_default();
        let current = one * self.q[outcome];
        let delta = reach.checked_sub(&current).unwrap_or_default() / one;
        let delta = u128::try_from(delta)
            .unwrap_or(u128::MAX)
            .min(MAX_QUANTITY - self.q[outcome]);
        self.step_back(outcome, spend, delta)
    }

    /// The inversion is exact to ~1e-70 wei; step back one wei over a boundary case. Bounded
    /// like the Solidity side: `STEP_BACK` tries, then 0 (never more shares than `spend` buys).
    fn step_back(&self, outcome: usize, spend: u128, mut delta: u128) -> Result<u128, Error> {
        for _ in 0..STEP_BACK {
            if delta == 0 || self.quote_buy(outcome, delta)?.ceil <= spend {
                return Ok(delta);
            }
            delta -= 1;
        }
        Ok(0)
    }

    fn leader(&self) -> (usize, u128) {
        if self.q[0] >= self.q[1] {
            (0, self.q[0])
        } else {
            (1, self.q[1])
        }
    }

    /// `|q0 - q1| / b` in fixed point.
    fn spread(&self, q: [u128; 2]) -> BigUint {
        let gap = q[0].abs_diff(q[1]);
        one() * gap / self.b
    }

    /// `C(q)` in wei, in fixed point.
    fn cost_scaled(&self, q: [u128; 2]) -> BigUint {
        let m = q[0].max(q[1]);
        let tail = ln_1_to_2(&(one() + exp_neg(&self.spread(q))));
        one() * m + tail * self.b
    }

    fn bought(&self, outcome: usize, shares: u128) -> Result<[u128; 2], Error> {
        if outcome > 1 {
            return Err(Error::InvalidOutcome);
        }
        if shares == 0 {
            return Err(Error::ZeroAmount);
        }
        let mut q = self.q;
        q[outcome] = match q[outcome].checked_add(shares) {
            Some(x) if x <= MAX_QUANTITY => x,
            _ => return Err(Error::QuantityOverflow),
        };
        Ok(q)
    }

    fn sold(&self, outcome: usize, shares: u128) -> Result<[u128; 2], Error> {
        if outcome > 1 {
            return Err(Error::InvalidOutcome);
        }
        if shares == 0 {
            return Err(Error::ZeroAmount);
        }
        let mut q = self.q;
        q[outcome] = q[outcome]
            .checked_sub(shares)
            .ok_or(Error::InsufficientQuantity)?;
        Ok(q)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A start far past the exact inverse (an API quote at LT-4 must not loop on it): the step
    /// back gives up after its bound and answers 0, never an overspending amount.
    #[test]
    fn step_back_gives_up_after_its_bound() {
        let m = Market::new(WAD).unwrap();
        let exact = m.shares_for_spend(0, WAD).unwrap();
        assert!(exact > 0);
        assert_eq!(m.step_back(0, WAD, exact), Ok(exact));
        assert_eq!(
            m.step_back(0, WAD, exact + STEP_BACK as u128 - 1),
            Ok(exact)
        );
        assert_eq!(m.step_back(0, WAD, exact + STEP_BACK as u128), Ok(0));
        assert_eq!(m.step_back(0, WAD, exact + 10_000), Ok(0));
    }
}
