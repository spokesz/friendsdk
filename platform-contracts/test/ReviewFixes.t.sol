// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { Fixture } from "./Fixture.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { Rolls } from "../src/libraries/Rolls.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";

/// @dev Regression tests for the review findings fixed after the first implementation pass.
contract ReviewFixesTest is Fixture {
    address internal alice = makeAddr("alice");
    uint256 internal constant FRIEND = 4242;

    function setUp() public override {
        super.setUp();
        mintFriend(alice, FRIEND, 2);
    }

    /// @dev A two-draw action with a nonzero maximum reserves maxPayable × draws × quantity.
    function testMultiDrawCommitReservesEveryDraw() public {
        vm.startPrank(owner);
        uint256 gameId = registry.createGame(
            address(draw), address(rf), funder, address(0), address(0), address(0), 1, ""
        );
        DrawTables.Class[] memory classes = new DrawTables.Class[](1);
        draw.defineClasses(gameId, classes);
        DrawTables.Action memory a =
            DrawTables.Action(DrawTables.Input.Currency, 0, 0, 1e18, 2, 3, false);
        DrawTables.Split[6] memory s;
        for (uint256 g; g < 6; ++g) {
            s[g] = DrawTables.Split(10_000, 0, 0, 0, 0);
        }
        DrawTables.Row[][] memory t = new DrawTables.Row[][](1);
        t[0] = new DrawTables.Row[](2);
        t[0][0] = DrawTables.Row(5000, 0, 2e18);
        t[0][1] = DrawTables.Row(5000, 0, 0);
        draw.defineAction(gameId, a, s, t);
        registry.activateGame(gameId);
        coordinator.setBudget(gameId, 1 ether);
        vm.stopPrank();
        fundGame(gameId, 100e18);

        giveRF(alice, 3e18);
        vm.prank(alice);
        uint256 commitId = draw.commit(gameId, 1, FRIEND, 3, 0, 0);
        (, uint256 reserved,,) = ledger(gameId);
        assertEq(reserved, 2e18 * 2 * 3, "six outcomes can each pay the maximum");
        (,,,,,,, uint256 requestId) = draw.commits(commitId);
        // A word whose six rolls all land in the paying row settles without under-reservation.
        bytes32 word;
        for (uint256 nonce; nonce < 5000; ++nonce) {
            word = keccak256(abi.encode("all-pay", nonce));
            bool allPay = true;
            for (uint256 i; i < 6 && allPay; ++i) {
                allPay = _roll(word, commitId, i) < 5000;
            }
            if (allPay) break;
        }
        fulfill(requestId, word);
        draw.settle(commitId);
        assertEq(rf.balanceOf(walletOf(FRIEND)), 12e18, "every draw paid");
        (, reserved,,) = ledger(gameId);
        assertEq(reserved, 0);
        assertSolvent(address(rf));
    }

    /// @dev A valued class can never be an action input: its liability would be stranded.
    function testValuedClassCannotBeBurnInput() public {
        vm.startPrank(owner);
        uint256 gameId = registry.createGame(
            address(draw), address(rf), funder, address(0), address(0), address(0), 1, ""
        );
        DrawTables.Class[] memory classes = new DrawTables.Class[](1);
        classes[0] = DrawTables.Class(1e18, 0);
        draw.defineClasses(gameId, classes);
        DrawTables.Action memory a =
            DrawTables.Action(DrawTables.Input.BurnClass, 1, 1, 0, 1, 1, false);
        DrawTables.Split[6] memory s;
        DrawTables.Row[][] memory t = new DrawTables.Row[][](1);
        t[0] = new DrawTables.Row[](1);
        t[0][0] = DrawTables.Row(10_000, 0, 0);
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        vm.stopPrank();
    }

    function testZeroPotTermsRejected() public {
        vm.startPrank(owner);
        uint256 gameId = registry.createGame(
            address(round), address(rf), funder, address(0), address(0), settler, 0, ""
        );
        RoundModule.Terms memory t = royaleTerms();
        t.potBps = 0;
        t.burnBps = 5000;
        t.rewardsBps = 5000;
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        round.defineTerms(gameId, t, LaunchTerms.royaleKindPrices());
        vm.stopPrank();
    }

    /// @dev A Round game cannot change module while any round is live; it can once none is.
    function testRoundSuccessionWaitsForLiveRounds() public {
        RoundModule v2 = new RoundModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        vm.startPrank(owner);
        registry.allowModule(address(v2));
        v2.defineTerms(royaleId, royaleTerms(), LaunchTerms.royaleKindPrices());
        vm.stopPrank();
        vm.prank(settler);
        uint256 roundId = round.openRound(royaleId, keccak256(abi.encode(keccak256("s"))));
        assertEq(round.liveRounds(royaleId), 1);
        assertFalse(round.succeedable(royaleId));
        vm.prank(owner);
        vm.expectRevert(GameRegistry.ModuleBusy.selector);
        registry.succeedModule(royaleId, address(v2));
        // Closing with no entrants refunds the round and frees the game for succession.
        vm.prank(settler);
        round.closeRound(roundId);
        assertEq(round.liveRounds(royaleId), 0);
        assertTrue(round.succeedable(royaleId));
        vm.prank(owner);
        registry.succeedModule(royaleId, address(v2));
        assertEq(registry.currentModule(royaleId), address(v2));
        assertTrue(draw.succeedable(breedsId), "Draw games are always succeedable");
    }

    /// @dev A retry the reclaimed fee pays for in full ignores the fee cap; a dearer one does not.
    function testRetryIgnoresCapWhenReclaimedCoversTheFee() public {
        giveRF(alice, 1e18);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        vm.prank(alice);
        uint256 commitId = draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        (,,,,,,, uint256 requestId) = draw.commits(commitId);
        vm.prank(owner);
        coordinator.setMaxFee(0);
        vm.roll(block.number + dice.refundDelayBlocks());
        vm.recordLogs();
        coordinator.retry(requestId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(coordinator)) {
                assertTrue(
                    logs[i].topics[0] != RandomnessCoordinator.Deposited.selector,
                    "Dice refunds are not reported as deposits"
                );
            }
        }
        (,,, uint64 sequence, uint32 attempt,,) = coordinator.requests(requestId);
        assertEq(attempt, 1);
        assertTrue(sequence != 0);
        // A higher quote than the reclaimed fee still respects the cap.
        dice.setFee(DICE_FEE + 1);
        vm.roll(block.number + dice.refundDelayBlocks());
        vm.expectRevert(RandomnessCoordinator.FeeAboveCap.selector);
        coordinator.retry(requestId);
    }

    function _roll(bytes32 word, uint256 commitId, uint256 index) private view returns (uint16) {
        return Rolls.roll(word, address(draw), block.chainid, commitId, index);
    }
}
