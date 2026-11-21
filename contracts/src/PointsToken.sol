// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title PointsToken
/// @notice Play-money collateral with no cash value. Points are not transferable by token
/// calls: they move only into and out of registered markets, with no transfer between
/// accounts, no allowance and no transferFrom (docs/END_GOAL.md invariant 7, the public-demo
/// constraint in the README). Value can still move between accounts through any market (two
/// accounts trading opposite sides, docs/DECISIONS.md D-007), which is why points confer no rank.
/// @dev Trust: an account with MARKET_ROLE can move any holder's points into itself
/// (`pull`), so only audited market code is ever registered. One admin key granting MARKET_ROLE
/// to an EOA could drain every balance: tracked to M2 (D-009, THREATS T-2).
contract PointsToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    error PointsNotTransferable();

    constructor(address admin) ERC20("Prediction Points", "POINTS") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mints points (the faucet, at M5).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice A market takes `amount` of `from`'s points into itself. Markets call it only
    /// with `from == msg.sender` of the trade they are executing.
    function pull(address from, uint256 amount) external onlyRole(MARKET_ROLE) {
        _transfer(from, msg.sender, amount);
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert PointsNotTransferable();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert PointsNotTransferable();
    }

    /// @dev Every balance change passes here: mints, burns, and moves into or out of the
    /// calling market are the only ones allowed.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            bool marketSide = from == msg.sender || to == msg.sender;
            // GUARD(points-update)
            if (!marketSide || !hasRole(MARKET_ROLE, msg.sender)) revert PointsNotTransferable();
        }
        super._update(from, to, value);
    }
}
