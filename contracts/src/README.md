# src/

M1 (docs/ROADMAP.md): points only, local chain only — no deployment script exists.

- `LMSRMarket.sol` — binary LMSR in its stable form, `C = max(q) + b·ln(1 + e^(-|q0-q1|/b))`.
  Bounds: `b ∈ [1e18, 1e30]`, each `q ≤ 1e30` (WAD), `e^(-d)` taken as 0 for `d ≥ 42`
  (PRBMath underflows there anyway), so `exp` never sees a positive argument. Buys pay
  `C + costError()`, sells receive `C − costError()`, `costError = ⌈32·b/1e18⌉ + 1` wei,
  twice the measured worst error against `lmsr-ref`: rounding always favours the pool.
- `PointsToken.sol` — ERC-20 play-money points with no cash value: no transfer, approve or
  transferFrom; only a registered market moves points, and only into or out of itself.
- `OutcomeToken.sol` — ERC-1155 shares, id = `market << 8 | outcome`; only that market
  mints or burns them, and they do not transfer.
