// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {OutcomeToken} from "../../src/OutcomeToken.sol";
import {PointsToken} from "../../src/PointsToken.sol";
import {Fixture} from "../Fixture.sol";

contract TokensTest is Fixture {
    function setUp() public {
        _setUpMarket(100e18);
        _give(alice, 1_000e18);
        vm.prank(alice);
        market.buy(0, 10e18, type(uint256).max);
    }

    function test_points_cannot_be_transferred_between_accounts() public {
        vm.prank(alice);
        vm.expectRevert(PointsToken.PointsNotTransferable.selector);
        points.transfer(bob, 1);
    }

    function test_points_cannot_be_approved() public {
        vm.prank(alice);
        vm.expectRevert(PointsToken.PointsNotTransferable.selector);
        points.approve(bob, 1);
    }

    function test_points_cannot_be_transferred_from() public {
        vm.prank(bob);
        vm.expectRevert(PointsToken.PointsNotTransferable.selector);
        points.transferFrom(alice, bob, 1);
    }

    function test_a_market_cannot_move_points_between_two_other_accounts() public {
        // A market's transfer always starts at the market itself; it has no way to name
        // another sender, and a plain transfer from an account is refused.
        vm.prank(address(market));
        points.transfer(bob, 1);
        vm.prank(bob);
        vm.expectRevert(PointsToken.PointsNotTransferable.selector);
        points.transfer(alice, 1);
    }

    function test_only_a_market_can_pull_points() public {
        bytes32 role = points.MARKET_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, role));
        points.pull(alice, 1);
    }

    function test_only_a_minter_can_mint_points() public {
        bytes32 role = points.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        points.mint(alice, 1);
    }

    function test_outcome_shares_cannot_be_transferred() public {
        uint256 id = outcomes.tokenId(address(market), 0);
        vm.prank(alice);
        vm.expectRevert(OutcomeToken.OutcomeNotTransferable.selector);
        outcomes.safeTransferFrom(alice, bob, id, 1, "");
    }

    function test_outcome_shares_cannot_be_approved() public {
        vm.prank(alice);
        vm.expectRevert(OutcomeToken.OutcomeNotTransferable.selector);
        outcomes.setApprovalForAll(bob, true);
    }

    function test_only_a_registered_market_mints_outcome_shares() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OutcomeToken.NotMarket.selector, alice));
        outcomes.mint(alice, 0, 1);
    }

    function test_only_a_registered_market_burns_outcome_shares() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OutcomeToken.NotMarket.selector, bob));
        outcomes.burn(alice, 0, 1);
    }

    function test_a_market_mints_only_its_own_ids() public {
        // Ids embed the minting market's address, so one market cannot touch another's.
        assertEq(outcomes.tokenId(address(market), 0) >> 8, uint256(uint160(address(market))));
        vm.prank(address(market));
        outcomes.mint(bob, 1, 5);
        assertEq(outcomes.balanceOf(bob, outcomes.tokenId(address(market), 1)), 5);
        assertEq(outcomes.balanceOf(bob, outcomes.tokenId(address(this), 1)), 0);
    }
}
