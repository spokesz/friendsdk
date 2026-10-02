// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Fixture } from "./Fixture.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import { DrawModule } from "../src/DrawModule.sol";

/// @dev End-to-end smoke test of the integrated hub: Rare Breeds buy, play, settle, redeem and a
/// Penalty Kings pack and kick, all through the real registry, Treasury, coordinator and items.
contract SmokeTest is Fixture {
    address internal alice = makeAddr("alice");
    uint256 internal constant FRIEND = 1234;

    function setUp() public override {
        super.setUp();
        mintFriend(alice, FRIEND, 3);
    }

    function testBreedsBuyPlaySettleRedeem() public {
        giveRF(alice, 5e18);
        vm.prank(alice);
        uint256 buyId = draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 5, 0, 0);
        assertEq(items(breedsId).balanceOf(walletOf(FRIEND), LaunchTerms.BREEDS_EGG), 5);
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, 10_005e18 - 30e18);
        assertEq(reserved, 30e18);
        (,,,,, bool settled,, uint256 requestId) = draw.commits(buyId);
        assertTrue(settled);
        assertEq(requestId, 0);

        vm.prank(alice);
        uint256 playId =
            draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, keccak256("parents"), 0);
        (,,,,, settled,, requestId) = draw.commits(playId);
        assertFalse(settled);
        assertTrue(requestId != 0);
        (, reserved,,) = ledger(breedsId);
        assertEq(reserved, 30e18, "egg reserve swapped for play reserve");

        fulfill(requestId, keccak256("word"));
        draw.settle(playId);
        (free, reserved,,) = ledger(breedsId);
        uint256 owed;
        (,, owed,) = ledger(breedsId);
        assertEq(reserved, 24e18);
        uint16 tier;
        for (uint16 id = 2; id <= 5; ++id) {
            if (items(breedsId).balanceOf(walletOf(FRIEND), id) == 1) tier = id;
        }
        assertTrue(tier != 0, "a tier token was minted");
        assertEq(owed, LaunchTerms.breedsClasses()[tier - 1].value);
        assertEq(free + reserved + owed, 10_005e18);
        assertSolvent(address(rf));

        vm.prank(alice);
        draw.redeem(breedsId, FRIEND, tier, 1, 0);
        assertEq(rf.balanceOf(walletOf(FRIEND)), owed);
        (,, owed,) = ledger(breedsId);
        assertEq(owed, 0);
        assertSolvent(address(rf));
    }

    function testParkPackAndKick() public {
        giveUSDG(alice, 4e6);
        vm.prank(alice);
        uint256 packId = draw.commit(parkId, LaunchTerms.PARK_PACK, FRIEND, 2, 0, 0);
        (,,,,,,, uint256 requestId) = draw.commits(packId);
        fulfill(requestId, keccak256("pack"));
        draw.settle(packId);
        uint256 balls;
        for (uint256 id = 1; id <= 7; ++id) {
            balls += items(parkId).balanceOf(walletOf(FRIEND), id);
        }
        assertEq(balls, 4, "two packs mint four balls");
        // Gen 3: edge 700 bps on 4 USDG = 280_000, operator 70_000, developer 210_000.
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), 210_000);
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), 70_000);
        (uint256 free,,,) = ledger(parkId);
        assertEq(free, 5000e6 + 3_720_000);

        // Kick the first ball the wallet holds.
        uint16 ball;
        for (uint16 id = 1; id <= 7; ++id) {
            if (items(parkId).balanceOf(walletOf(FRIEND), id) != 0) {
                ball = id;
                break;
            }
        }
        vm.prank(alice);
        uint256 kickId = draw.commit(parkId, LaunchTerms.parkKickAction(ball), FRIEND, 1, 0, 0);
        (, uint256 reserved,,) = ledger(parkId);
        assertEq(reserved, LaunchTerms.parkMaxPrize(ball));
        (,,,,,,, requestId) = draw.commits(kickId);
        fulfill(requestId, keccak256("kick"));
        draw.settle(kickId);
        (, reserved,,) = ledger(parkId);
        assertEq(reserved, 0);
        assertSolvent(address(usdg));
        treasury.payFees(address(usdg), PARK_DEVELOPER);
        assertEq(usdg.balanceOf(PARK_DEVELOPER), 210_000);
    }
}
