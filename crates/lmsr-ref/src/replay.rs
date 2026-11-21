//! The command-line oracle the Foundry differential fuzz calls through `vm.ffi`:
//!
//! `lmsr-ref replay <b> <op>...` with each op `buy0:<shares>`, `buy1:<shares>`,
//! `sell0:<shares>`, `sell1:<shares>`, `mint:<sets>` or `burn:<sets>` (decimal wei).
//!
//! It prints one ABI-encoded `uint256[]` as `0x…` hex (which `vm.ffi` decodes): a header of
//! [`HEADER`] words — `b·ln 2` floor and ceiling, `C(0)` floor and ceiling — then [`ROW`]
//! words per op: `C(q)` floor and ceiling after the op, the two prices, and the op's exact
//! amount (cost or return) floor and ceiling. A refused op is an error naming its index.

use crate::{Error, Market};

/// Words before the first row.
pub const HEADER: usize = 4;
/// Words per op.
pub const ROW: usize = 6;
/// The most ops one call replays, so a hostile argument list cannot make the oracle run
/// unbounded work.
pub const MAX_OPS: usize = 512; // LIMIT(replay-ops)
/// The longest decimal amount accepted: `u128::MAX` has 39 digits.
const MAX_DIGITS: usize = 39;

/// Why a replay was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ReplayError {
    #[error("usage: lmsr-ref replay <b> <op>... (op: buy0|buy1|sell0|sell1|mint|burn:<wei>)")]
    Usage,
    #[error("more than {MAX_OPS} ops")]
    TooManyOps,
    #[error("argument {0} is not a decimal amount of at most 39 digits")]
    BadAmount(usize),
    #[error("argument {0} is not an op")]
    BadOp(usize),
    #[error("the market was refused: {0}")]
    Market(Error),
    #[error("op {index} was refused: {error}")]
    Op { index: usize, error: Error },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Op {
    Buy(usize, u128),
    Sell(usize, u128),
    Mint(u128),
    Burn(u128),
}

fn amount(s: &str, arg: usize) -> Result<u128, ReplayError> {
    if s.is_empty() || s.len() > MAX_DIGITS || !s.bytes().all(|c| c.is_ascii_digit()) {
        return Err(ReplayError::BadAmount(arg));
    }
    s.parse().map_err(|_| ReplayError::BadAmount(arg))
}

fn op(s: &str, arg: usize) -> Result<Op, ReplayError> {
    let (kind, value) = s.split_once(':').ok_or(ReplayError::BadOp(arg))?;
    let value = amount(value, arg)?;
    Ok(match kind {
        "buy0" => Op::Buy(0, value),
        "buy1" => Op::Buy(1, value),
        "sell0" => Op::Sell(0, value),
        "sell1" => Op::Sell(1, value),
        "mint" => Op::Mint(value),
        "burn" => Op::Burn(value),
        _ => return Err(ReplayError::BadOp(arg)),
    })
}

/// Replays the ops from `args` (everything after the program name) and returns the words.
pub fn replay(args: &[String]) -> Result<Vec<u128>, ReplayError> {
    let [command, b, ops @ ..] = args else {
        return Err(ReplayError::Usage);
    };
    if command != "replay" {
        return Err(ReplayError::Usage);
    }
    if ops.len() > MAX_OPS {
        return Err(ReplayError::TooManyOps);
    }
    let mut market = Market::new(amount(b, 1)?).map_err(ReplayError::Market)?;
    let parsed = ops
        .iter()
        .enumerate()
        .map(|(i, s)| op(s, i + 2))
        .collect::<Result<Vec<_>, _>>()?;
    let mut words = Vec::with_capacity(HEADER + ROW * parsed.len());
    let (max_loss, cost) = (market.max_loss(), market.cost());
    words.extend([max_loss.floor, max_loss.ceil, cost.floor, cost.ceil]);
    for (index, op) in parsed.into_iter().enumerate() {
        let refused = |error| ReplayError::Op { index, error };
        let (floor, ceil) = match op {
            Op::Buy(i, x) => {
                let exact = market.quote_buy(i, x).map_err(refused)?;
                market.buy(i, x).map_err(refused)?;
                (exact.floor, exact.ceil)
            }
            Op::Sell(i, x) => {
                let exact = market.quote_sell(i, x).map_err(refused)?;
                market.sell(i, x).map_err(refused)?;
                (exact.floor, exact.ceil)
            }
            Op::Mint(x) => {
                let paid = market.mint_sets(x).map_err(refused)?;
                (paid, paid)
            }
            Op::Burn(x) => {
                let paid = market.burn_sets(x).map_err(refused)?;
                (paid, paid)
            }
        };
        let cost = market.cost();
        let prices = market.prices();
        words.extend([cost.floor, cost.ceil, prices[0], prices[1], floor, ceil]);
    }
    Ok(words)
}

/// `abi.encode(uint256[])` as `0x`-prefixed lower-case hex.
pub fn abi_encode_words(words: &[u128]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(2 + 64 * (words.len() + 2));
    out.push_str("0x");
    let word = |out: &mut String, x: u128| {
        let _ = write!(out, "{x:064x}");
    };
    word(&mut out, 32);
    word(&mut out, words.len() as u128);
    for &x in words {
        word(&mut out, x);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn a_replay_reports_each_step() {
        let b = "100000000000000000000";
        let words = replay(&args(&[
            "replay",
            b,
            "buy0:50000000000000000000",
            "sell0:50000000000000000000",
        ]))
        .unwrap();
        assert_eq!(words.len(), HEADER + 2 * ROW);
        // The worked example in docs/KNOWLEDGE.md: 50 YES at b = 100 cost 28.09.
        assert_eq!(words[HEADER + 4] / 10_000_000_000_000_000, 2809);
        // Selling straight back returns the same exact amount (path independence) ...
        assert!(words[HEADER + ROW + 4].abs_diff(words[HEADER + 4]) <= 1);
        // ... and the market is back at C(0).
        assert_eq!(words[HEADER + ROW], words[2]);
    }

    #[test]
    fn refusals_name_what_was_wrong() {
        assert_eq!(replay(&args(&["replay"])), Err(ReplayError::Usage));
        assert_eq!(replay(&args(&["quote", "1"])), Err(ReplayError::Usage));
        assert_eq!(
            replay(&args(&["replay", "x"])),
            Err(ReplayError::BadAmount(1))
        );
        assert_eq!(
            replay(&args(&["replay", "1"])),
            Err(ReplayError::Market(Error::LiquidityOutOfRange))
        );
        let b = "1000000000000000000";
        assert_eq!(
            replay(&args(&["replay", b, "buy2:1"])),
            Err(ReplayError::BadOp(2))
        );
        assert_eq!(
            replay(&args(&["replay", b, "buy0:-1"])),
            Err(ReplayError::BadAmount(2))
        );
        assert_eq!(
            replay(&args(&["replay", b, "buy0:1", "sell1:1"])),
            Err(ReplayError::Op {
                index: 1,
                error: Error::InsufficientQuantity
            })
        );
        assert_eq!(
            replay(&args(&["replay", b, "buy0:0"])),
            Err(ReplayError::Op {
                index: 0,
                error: Error::ZeroAmount
            })
        );
    }

    #[test]
    fn more_than_max_ops_is_refused_before_any_work() {
        let b = "1000000000000000000".to_owned();
        let mut list = vec!["replay".to_owned(), b];
        list.extend(std::iter::repeat_n("mint:1".to_owned(), MAX_OPS));
        assert!(replay(&list).is_ok());
        list.push("mint:1".to_owned());
        assert_eq!(replay(&list), Err(ReplayError::TooManyOps));
    }

    #[test]
    fn the_encoding_is_abi_uint256_array() {
        let hex = abi_encode_words(&[1, u128::MAX]);
        assert_eq!(hex.len(), 2 + 64 * 4);
        assert!(
            hex.starts_with("0x0000000000000000000000000000000000000000000000000000000000000020")
        );
        assert!(hex.ends_with("00000000000000000000000000000000ffffffffffffffffffffffffffffffff"));
    }

    proptest! {
        // Untrusted input: any argument list is answered with words or a typed refusal,
        // never a panic.
        #[test]
        fn arbitrary_arguments_never_panic(list in proptest::collection::vec("[a-z0-9:-]{0,48}", 0..8)) {
            let mut full = vec!["replay".to_owned(), "1000000000000000000".to_owned()];
            full.extend(list.clone());
            let _ = replay(&full);
            let _ = replay(&list);
        }
    }
}
