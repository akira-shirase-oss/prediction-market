// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title OutcomeToken
/// @notice ERC-1155 positions for every market: token id `uint160(market) << 8 | outcome`.
/// Only the market that owns an id mints or burns it. Positions are not transferable
/// between accounts by token calls: a transferable complete set would carry points from one
/// account to another for free. (Opposite trades through a market can still move value at
/// the cost of the rounding margins: D-007.)
contract OutcomeToken is ERC1155, AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    mapping(address market => bool) public isMarket;

    error OutcomeNotTransferable();
    error NotMarket(address caller);

    event MarketRegistered(address indexed market);

    constructor(address admin) ERC1155("") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function tokenId(address market, uint8 outcome) public pure returns (uint256) {
        return (uint256(uint160(market)) << 8) | outcome;
    }

    /// @notice Lets `market` mint and burn its own ids (the factory, at M2).
    function registerMarket(address market) external onlyRole(REGISTRAR_ROLE) {
        isMarket[market] = true;
        emit MarketRegistered(market);
    }

    function mint(address to, uint8 outcome, uint256 amount) external {
        // GUARD(outcome-mint)
        if (!isMarket[msg.sender]) revert NotMarket(msg.sender);
        _mint(to, tokenId(msg.sender, outcome), amount, "");
    }

    function burn(address from, uint8 outcome, uint256 amount) external {
        // GUARD(outcome-burn)
        if (!isMarket[msg.sender]) revert NotMarket(msg.sender);
        _burn(from, tokenId(msg.sender, outcome), amount);
    }

    function setApprovalForAll(address, bool) public pure override {
        revert OutcomeNotTransferable();
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        // GUARD(outcome-update)
        if (from != address(0) && to != address(0)) revert OutcomeNotTransferable();
        super._update(from, to, ids, values);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
