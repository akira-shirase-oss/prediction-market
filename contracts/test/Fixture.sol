// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {LMSRMarket} from "../src/LMSRMarket.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {PointsToken} from "../src/PointsToken.sol";

/// Deploys the tokens and one funded market on the local test chain.
abstract contract Fixture is Test {
    PointsToken internal points;
    OutcomeToken internal outcomes;
    LMSRMarket internal market;

    address internal admin = makeAddr("admin");
    address internal resolver = makeAddr("resolver");
    address internal funder = makeAddr("funder");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint64 internal closeTime;

    function _deploy(uint256 b) internal returns (LMSRMarket m) {
        m = new LMSRMarket(points, outcomes, b, closeTime, resolver);
        vm.startPrank(admin);
        points.grantRole(points.MARKET_ROLE(), address(m));
        outcomes.registerMarket(address(m));
        points.mint(funder, m.requiredSubsidy());
        vm.stopPrank();
        vm.prank(funder);
        m.fund();
    }

    function _setUpMarket(uint256 b) internal {
        closeTime = uint64(block.timestamp + 7 days);
        points = new PointsToken(admin);
        outcomes = new OutcomeToken(admin);
        vm.startPrank(admin);
        points.grantRole(points.MINTER_ROLE(), admin);
        outcomes.grantRole(outcomes.REGISTRAR_ROLE(), admin);
        vm.stopPrank();
        market = _deploy(b);
    }

    function _give(address to, uint256 amount) internal {
        vm.prank(admin);
        points.mint(to, amount);
    }

    function _shares(address who, uint8 outcome) internal view returns (uint256) {
        return outcomes.balanceOf(who, outcomes.tokenId(address(market), outcome));
    }
}
