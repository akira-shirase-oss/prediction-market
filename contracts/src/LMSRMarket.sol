// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SD59x18, sd} from "@prb/math/src/SD59x18.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";

import {PointsToken} from "./PointsToken.sol";
import {OutcomeToken} from "./OutcomeToken.sol";

/// @title LMSRMarket
/// @notice A binary market priced by Hanson's LMSR, cost C(q) = b·ln(e^(q0/b) + e^(q1/b)),
/// in its numerically stable log-sum-exp form
///     C(q) = max(q) + b·ln(1 + e^(-d)),   d = |q0 - q1| / b,
/// so the only exponent is e^(-d) with -d <= 0: it never overflows, whatever the quantities.
/// Points only (no cash value); collateral covers every payout at every reachable state.
///
/// Fixed-point bounds (all amounts are 18-decimal wei of points or shares):
/// - b in [MIN_LIQUIDITY, MAX_LIQUIDITY] = [1e18, 1e30]; each q_i <= MAX_QUANTITY = 1e30.
///   So d <= 1e30·1e18/1e18 fits easily, and every product below stays far under 2^256.
/// - d >= EXP_CUTOFF (42e18): e^(-d) < 1e-18, below one wei of the 18-decimal result, so it
///   is taken as 0 (PRBMath's exp returns 0 there too, at d > ~41.45).
/// - Each computed C is within ERR(b) = ceil(ERR_WAD·b/1e18) + 1 wei of the exact value, ERR_WAD = 32 (twice the
///   worst 14 wei per 1e18 of b the differential sweep measures)
///   (ERR_WAD covers d's floor, exp and ln errors; the differential fuzz measures it).
///   A buy charges ΔC + 2·ERR(b) and a sell returns ΔC - 2·ERR(b), so every charge is at
///   least the exact cost and every return at most the exact return: rounding never
///   favours the trader. The funder's subsidy is C(0) + ERR(b) >= b·ln 2, the most the
///   exact market maker can lose, which is the solvency proof.
contract LMSRMarket is ReentrancyGuardTransient {
    uint256 public constant WAD = 1e18;
    uint256 public constant MIN_LIQUIDITY = 1e18;
    uint256 public constant MAX_LIQUIDITY = 1e30;
    uint256 public constant MAX_QUANTITY = 1e30;
    uint256 public constant EXP_CUTOFF = 42e18;
    uint256 public constant ERR_WAD = 32;

    PointsToken public immutable points;
    OutcomeToken public immutable outcomes;
    uint256 public immutable liquidity;
    uint64 public immutable closeTime;
    address public immutable resolver;

    uint256[2] internal q;
    uint256 public subsidy;
    bool public resolved;
    uint8 public winner;

    error LiquidityOutOfRange(uint256 b);
    error ZeroAmount();
    error InvalidOutcome(uint256 outcome);
    error QuantityOverflow();
    error InsufficientQuantity();
    error SlippageExceeded(uint256 amount, uint256 limit);
    error MarketNotFunded();
    error AlreadyFunded();
    error MarketClosed();
    error MarketResolved();
    error MarketStillOpen();
    error MarketNotResolved();
    error NotResolver(address caller);
    error ZeroAddress();

    event Funded(address indexed funder, uint256 subsidy);
    event Bought(address indexed trader, uint8 indexed outcome, uint256 shares, uint256 cost);
    event Sold(address indexed trader, uint8 indexed outcome, uint256 shares, uint256 payout);
    event SetsMinted(address indexed trader, uint256 sets);
    event SetsBurned(address indexed trader, uint256 sets);
    event Resolved(uint8 indexed winner);
    event Redeemed(address indexed holder, uint256 shares);

    constructor(PointsToken points_, OutcomeToken outcomes_, uint256 b, uint64 closeTime_, address resolver_) {
        if (b < MIN_LIQUIDITY || b > MAX_LIQUIDITY) revert LiquidityOutOfRange(b);
        if (address(points_) == address(0) || address(outcomes_) == address(0) || resolver_ == address(0)) {
            revert ZeroAddress();
        }
        points = points_;
        outcomes = outcomes_;
        liquidity = b;
        closeTime = closeTime_;
        resolver = resolver_;
    }

    // ---------------------------------------------------------------- views

    function quantities() external view returns (uint256, uint256) {
        return (q[0], q[1]);
    }

    /// @notice C(q) as computed here (within ERR(b) of the exact value).
    function cost() external view returns (uint256) {
        return _cost(q[0], q[1]);
    }

    /// @notice The bound on |computed C - exact C|, in wei.
    function costError() public view returns (uint256) {
        return Math.mulDiv(ERR_WAD, liquidity, WAD, Math.Rounding.Ceil) + 1;
    }

    /// @notice The subsidy a funder pays: C(0) + ERR(b), at least b·ln 2.
    function requiredSubsidy() public view returns (uint256) {
        return _cost(0, 0) + costError();
    }

    /// @notice Marginal prices in wei; they sum to exactly 1e18.
    function prices() external view returns (uint256 p0, uint256 p1) {
        (uint256 lag, bool zeroLeads) = _lagPrice(q[0], q[1]);
        return zeroLeads ? (WAD - lag, lag) : (lag, WAD - lag);
    }

    function quoteBuy(uint8 outcome, uint256 shares) public view returns (uint256) {
        (uint256 a0, uint256 a1) = _after(outcome, shares, true);
        uint256 before = _cost(q[0], q[1]);
        uint256 later = _cost(a0, a1);
        return (later > before ? later - before : 0) + 2 * costError();
    }

    function quoteSell(uint8 outcome, uint256 shares) public view returns (uint256) {
        (uint256 a0, uint256 a1) = _after(outcome, shares, false);
        uint256 before = _cost(q[0], q[1]);
        uint256 later = _cost(a0, a1);
        uint256 gross = before > later ? before - later : 0;
        uint256 margin = 2 * costError();
        return gross > margin ? gross - margin : 0;
    }

    /// @notice The most shares of `outcome` that `spend` points buy: quoteBuy(result) <= spend.
    /// Inverts C in its stable form, q_i' = C' - b·(-ln(1 - e^(-(C' - q_j)/b))), where
    /// C' = C(q) + spend - 2·ERR(b) > q_j, so the exponent is negative and nothing divides
    /// by zero, however far apart the quantities are. Returns 0 when spend buys nothing.
    function sharesForSpend(uint8 outcome, uint256 spend) external view returns (uint256 shares) {
        if (outcome > 1) revert InvalidOutcome(outcome);
        if (spend == 0) revert ZeroAmount();
        uint256 margin = 2 * costError();
        if (spend <= margin) return 0;
        uint256 target = _cost(q[0], q[1]) + spend - margin;
        uint256 other = q[1 - outcome];
        uint256 current = q[outcome];
        uint256 t = Math.mulDiv(target - other, WAD, liquidity);
        uint256 y = t >= EXP_CUTOFF ? 0 : uint256(sd(-int256(t)).exp().unwrap()); // forge-lint: disable-line(unsafe-typecast)
        if (y >= WAD) return 0;
        // -ln(1 - y) >= 0; rounded up so the estimate errs towards fewer shares.
        uint256 negLn = uint256(-sd(int256(WAD - y)).ln().unwrap()) + 1; // forge-lint: disable-line(unsafe-typecast)
        uint256 back = Math.mulDiv(negLn, liquidity, WAD, Math.Rounding.Ceil);
        if (back >= target) return 0;
        uint256 reach = target - back;
        if (reach <= current) return 0;
        shares = Math.min(reach - current, MAX_QUANTITY - current);
        // The estimate is within a few ERR(b) of the exact inverse; shrink it (cost is
        // convex with C(0 shares) = 0, so scaling shares down scales the cost down at least
        // as much) until the quote fits. Bounded: 8 steps, then 0.
        for (uint256 i = 0; i < 8 && shares != 0; i++) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            uint256 quote = quoteBuy(outcome, shares);
            if (quote <= spend) return shares;
            shares = Math.mulDiv(shares, spend - margin, quote - margin + 1);
        }
        return 0;
    }

    // ---------------------------------------------------------------- lifecycle

    /// @notice Pays the subsidy that opens the market. Needs this market registered with
    /// both tokens.
    function fund() external nonReentrant {
        if (subsidy != 0) revert AlreadyFunded();
        if (block.timestamp >= closeTime) revert MarketClosed();
        uint256 amount = requiredSubsidy();
        subsidy = amount;
        emit Funded(msg.sender, amount);
        points.pull(msg.sender, amount);
    }

    function resolve(uint8 outcome) external {
        if (msg.sender != resolver) revert NotResolver(msg.sender);
        if (outcome > 1) revert InvalidOutcome(outcome);
        if (resolved) revert MarketResolved();
        if (block.timestamp < closeTime) revert MarketStillOpen();
        resolved = true;
        winner = outcome;
        emit Resolved(outcome);
    }

    /// @notice Pays 1 point per winning share.
    function redeem(uint256 shares) external nonReentrant {
        if (!resolved) revert MarketNotResolved();
        if (shares == 0) revert ZeroAmount();
        q[winner] -= shares;
        emit Redeemed(msg.sender, shares);
        outcomes.burn(msg.sender, winner, shares);
        if (!points.transfer(msg.sender, shares)) revert InsufficientQuantity();
    }

    // ---------------------------------------------------------------- trading

    function buy(uint8 outcome, uint256 shares, uint256 maxCost) external nonReentrant returns (uint256 charged) {
        _requireOpen();
        charged = quoteBuy(outcome, shares);
        if (charged > maxCost) revert SlippageExceeded(charged, maxCost);
        q[outcome] += shares;
        emit Bought(msg.sender, outcome, shares, charged);
        points.pull(msg.sender, charged);
        outcomes.mint(msg.sender, outcome, shares);
    }

    function sell(uint8 outcome, uint256 shares, uint256 minPayout) external nonReentrant returns (uint256 paid) {
        _requireOpen();
        paid = quoteSell(outcome, shares);
        if (paid < minPayout) revert SlippageExceeded(paid, minPayout);
        q[outcome] -= shares;
        emit Sold(msg.sender, outcome, shares, paid);
        outcomes.burn(msg.sender, outcome, shares);
        if (paid != 0 && !points.transfer(msg.sender, paid)) revert InsufficientQuantity();
    }

    /// @notice One share of each outcome for one point each: C(q + n·1) = C(q) + n exactly,
    /// and prices do not move.
    function mintSets(uint256 sets) external nonReentrant {
        _requireOpen();
        (uint256 a0,) = _after(0, sets, true);
        (, uint256 a1) = _after(1, sets, true);
        (q[0], q[1]) = (a0, a1);
        emit SetsMinted(msg.sender, sets);
        points.pull(msg.sender, sets);
        outcomes.mint(msg.sender, 0, sets);
        outcomes.mint(msg.sender, 1, sets);
    }

    function burnSets(uint256 sets) external nonReentrant {
        _requireOpen();
        (uint256 a0,) = _after(0, sets, false);
        (, uint256 a1) = _after(1, sets, false);
        (q[0], q[1]) = (a0, a1);
        emit SetsBurned(msg.sender, sets);
        outcomes.burn(msg.sender, 0, sets);
        outcomes.burn(msg.sender, 1, sets);
        if (!points.transfer(msg.sender, sets)) revert InsufficientQuantity();
    }

    // ---------------------------------------------------------------- internals

    function _requireOpen() internal view {
        if (resolved) revert MarketResolved();
        if (block.timestamp >= closeTime) revert MarketClosed();
        if (subsidy == 0) revert MarketNotFunded();
    }

    /// @dev Quantities after adding (or removing) `shares` of `outcome`, with every refusal.
    function _after(uint8 outcome, uint256 shares, bool add) internal view returns (uint256 a0, uint256 a1) {
        if (outcome > 1) revert InvalidOutcome(outcome);
        if (shares == 0) revert ZeroAmount();
        (a0, a1) = (q[0], q[1]);
        uint256 current = outcome == 0 ? a0 : a1;
        uint256 next;
        if (add) {
            if (shares > MAX_QUANTITY - current) revert QuantityOverflow();
            next = current + shares;
        } else {
            if (shares > current) revert InsufficientQuantity();
            next = current - shares;
        }
        if (outcome == 0) a0 = next;
        else a1 = next;
    }

    /// @dev e^(-d) in wei, d = |q0 - q1|/b; 0 past EXP_CUTOFF.
    function _expNegSpread(uint256 q0, uint256 q1) internal view returns (uint256) {
        uint256 gap = q0 > q1 ? q0 - q1 : q1 - q0;
        uint256 d = Math.mulDiv(gap, WAD, liquidity);
        if (d >= EXP_CUTOFF) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(sd(-int256(d)).exp().unwrap());
    }

    /// @dev C(q) = max(q) + b·ln(1 + e^(-d)), floored.
    function _cost(uint256 q0, uint256 q1) internal view returns (uint256) {
        uint256 tailWad = ud(WAD + _expNegSpread(q0, q1)).ln().unwrap();
        return Math.max(q0, q1) + Math.mulDiv(tailWad, liquidity, WAD);
    }

    /// @dev The trailing outcome's price e^(-d)/(1 + e^(-d)), floored, and whether outcome 0 leads.
    function _lagPrice(uint256 q0, uint256 q1) internal view returns (uint256 lag, bool zeroLeads) {
        uint256 e = _expNegSpread(q0, q1);
        return (Math.mulDiv(e, WAD, WAD + e), q0 >= q1);
    }
}
