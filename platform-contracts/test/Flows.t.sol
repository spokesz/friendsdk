// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC1155 } from "lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Fixture } from "./Fixture.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { Treasury } from "../src/Treasury.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { FriendAccess } from "../src/libraries/FriendAccess.sol";
import { Rolls } from "../src/libraries/Rolls.sol";
import { MockFriendWallet } from "./doubles/ExternalDoubles.sol";

/// @dev docs/SPEC.md section 7 flows 7.1, 7.2, 7.3 and 7.6 as end-to-end tests through the
/// real registry, Treasury, coordinator, modules and items, with the ordered events a keeper
/// and an indexer rely on and the Treasury solvency invariant (I1) asserted after every step.
contract FlowsTest is Fixture {
    /// @dev `O` of section 7: owns Friend 1234 (gen 3) whose wallet is `W`.
    address internal o = makeAddr("O");
    address internal keeper = makeAddr("keeper");
    uint256 internal constant FRIEND = 1234;
    uint256 internal constant CUSTODIED = 777;
    address internal w;

    bytes32 internal constant A1 = keccak256("orderId A1");
    bytes32 internal constant A2 = keccak256("orderId A2");
    bytes32 internal constant A3 = keccak256("orderId A3");

    // Golden Boot (ball 7) kick table for a generation-3 Friend: section 3.3 with bonus 150.
    // Cumulative boundaries: 100, 200, 400, 800, 1600, 5650, 10_000.
    uint16 internal constant GB_SAVED_GEN3 = 4350;

    function setUp() public override {
        super.setUp();
        mintFriend(o, FRIEND, 3);
        w = walletOf(FRIEND);
    }

    // ---------------------------------------------------------------------------- helpers

    function _legs(uint256 toFree, uint256 toReserved, uint256 dev, uint256 op)
        internal
        pure
        returns (ITreasury.Legs memory)
    {
        return ITreasury.Legs(toFree, toReserved, dev, op, 0, 0);
    }

    function _assertLedger(uint256 gameId, uint256 free, uint256 reserved, uint256 owed)
        internal
        view
    {
        (uint256 f, uint256 r, uint256 ow, uint256 c) = ledger(gameId);
        assertEq(f, free, "free");
        assertEq(r, reserved, "reserved");
        assertEq(ow, owed, "owed");
        assertEq(c, 0, "credit");
    }

    function _rows1(uint8 a) internal pure returns (uint8[] memory out) {
        out = new uint8[](1);
        out[0] = a;
    }

    function _ids1(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _ids4(uint256 a, uint256 b, uint256 c, uint256 d)
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](4);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
    }

    function _ones(uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = 1;
        }
    }

    /// @dev Cumulative upper bounds (exclusive) of a stored table, in declared row order.
    function _bounds(uint256 gameId, uint8 actionId, uint8 tableIndex)
        internal
        view
        returns (uint16[] memory bounds)
    {
        DrawTables.Row[] memory table = draw.rows(gameId, actionId, tableIndex);
        bounds = new uint16[](table.length);
        uint16 cumulative;
        for (uint256 i; i < table.length; ++i) {
            cumulative += table[i].weightBps;
            bounds[i] = cumulative;
        }
    }

    /// @dev A word whose roll for draw 0 of `commitId` equals exactly `target`.
    function _wordForRoll(uint256 commitId, uint16 target) internal view returns (bytes32) {
        uint16[] memory lows = new uint16[](1);
        uint16[] memory highs = new uint16[](1);
        lows[0] = target;
        highs[0] = target;
        return this.search(commitId, lows, highs);
    }

    /// @dev A word whose rolls for draws `0..rows.length` of `commitId` pick exactly `rows`
    /// out of the table at `(gameId, actionId, tableIndex)`.
    function _wordForRows(
        uint256 commitId,
        uint256 gameId,
        uint8 actionId,
        uint8 tableIndex,
        uint8[] memory rows_
    ) internal view returns (bytes32) {
        uint16[] memory bounds = _bounds(gameId, actionId, tableIndex);
        uint16[] memory lows = new uint16[](rows_.length);
        uint16[] memory highs = new uint16[](rows_.length);
        for (uint256 i; i < rows_.length; ++i) {
            lows[i] = rows_[i] == 0 ? 0 : bounds[rows_[i] - 1];
            highs[i] = bounds[rows_[i]] - 1;
        }
        return this.search(commitId, lows, highs);
    }

    /// @dev Finds a word whose roll for every draw `i` of `commitId` lies in `[lows[i],
    /// highs[i]]`. Runs in its own frame and hashes in scratch memory so the search never grows
    /// memory; the result is verified against the real sampler before it is returned.
    function search(uint256 commitId, uint16[] memory lows, uint16[] memory highs)
        external
        view
        returns (bytes32 word)
    {
        address module = address(draw);
        uint256 chainId = block.chainid;
        uint256 limit = type(uint256).max - (type(uint256).max % Rolls.RANGE);
        uint256 n = lows.length;
        for (uint256 nonce;; ++nonce) {
            bool ok = true;
            for (uint256 i; i < n; ++i) {
                uint256 value;
                assembly ("memory-safe") {
                    mstore(0, nonce)
                    word := keccak256(0, 32)
                    let p := mload(0x40)
                    mstore(p, word)
                    mstore(add(p, 32), module)
                    mstore(add(p, 64), chainId)
                    mstore(add(p, 96), commitId)
                    mstore(add(p, 128), i)
                    value := keccak256(p, 160)
                }
                // A rejected sample is simply another nonce; the real sampler decides below.
                if (value >= limit) {
                    ok = false;
                    break;
                }
                uint256 roll = value % Rolls.RANGE;
                if (roll < lows[i] || roll > highs[i]) {
                    ok = false;
                    break;
                }
            }
            if (ok) break;
        }
        for (uint256 i; i < n; ++i) {
            uint16 roll = Rolls.roll(word, module, chainId, commitId, i);
            assertTrue(roll >= lows[i] && roll <= highs[i], "search");
        }
    }

    /// @dev Like `Fixture.viaWallet`, with the wallet resolved before the prank so the prank is
    /// consumed by `execute` itself rather than by the `tokenBoundAccount` view call.
    function _viaWallet(address friendOwner, uint256 friendId, address target, bytes memory data)
        internal
        returns (bytes memory)
    {
        MockFriendWallet wallet = MockFriendWallet(payable(walletOf(friendId)));
        vm.prank(friendOwner);
        return wallet.execute(target, 0, data, 0);
    }

    function _requestOf(uint256 commitId) internal view returns (uint256 requestId) {
        (,,,,,,, requestId) = draw.commits(commitId);
    }

    function _isSettled(uint256 commitId) internal view returns (bool settled) {
        (,,,,, settled,,) = draw.commits(commitId);
    }

    /// @dev Reveal `word` for the commit's request, asserting the coordinator's `Fulfilled`.
    function _reveal(uint256 commitId, bytes32 word) internal {
        uint256 requestId = _requestOf(commitId);
        uint64 sequence = sequenceOf(requestId);
        vm.expectEmit(address(coordinator));
        emit RandomnessCoordinator.Fulfilled(requestId, sequence, word);
        assertTrue(dice.reveal(sequence, word), "callback failed");
    }

    // ------------------------------------------------------------------- 7.1 Rare Breeds

    /// @dev Section 7.1 steps 1..10: buy 5 eggs (inline settlement), play one, Dice word,
    /// settle to Spotted, redeem; every ledger trace of step 10 and the ordered events.
    function testFlow71BreedsBuyFiveEggsPlayOneSettleRedeem() public {
        bytes32 context = keccak256(abi.encode("parentA", "parentB"));
        uint256 game = breedsId;
        address itemsAddr = address(items(game));

        // Step 1: O approves the Treasury for 5 RF.
        giveRF(o, 5e18);
        _assertLedger(game, 10_000e18, 0, 0);

        // Steps 2..4: collect 5 RF into free, reserve 30 RF, commit 1, inline settlement.
        vm.expectEmit(address(treasury));
        emit Treasury.Collected(game, o, _legs(5e18, 0, 0, 0));
        vm.expectEmit(address(treasury));
        emit Treasury.Reserved(game, 30e18);
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(1, game, FRIEND, w, LaunchTerms.BREEDS_BUY, 5, 3, 30e18, 0, 0, 0);
        vm.expectEmit(address(treasury));
        emit Treasury.Resolved(game, 30e18, 0, 30e18, w, 0);
        // OpenZeppelin emits TransferSingle for a one-id mintBatch.
        vm.expectEmit(itemsAddr);
        emit IERC1155.TransferSingle(address(draw), address(0), w, LaunchTerms.BREEDS_EGG, 5);
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(1, game, FRIEND, w, new uint8[](5), 0, 0);
        vm.prank(o);
        uint256 buyId = draw.commit(game, LaunchTerms.BREEDS_BUY, FRIEND, 5, 0, 0);
        assertEq(buyId, 1, "commitId 1");
        assertTrue(_isSettled(buyId), "inline settlement");
        assertEq(_requestOf(buyId), 0, "no word for a one-row table");
        assertEq(items(game).balanceOf(w, LaunchTerms.BREEDS_EGG), 5, "five eggs");
        assertEq(rf.balanceOf(o), 0, "O paid 5 RF");
        // Step 10 trace after step 4: balance 10_005 = free 9_975 + reserved 30.
        _assertLedger(game, 9975e18, 30e18, 0);
        assertEq(rf.balanceOf(address(treasury)), 10_005e18);
        assertSolvent(address(rf));

        // Steps 5..6: play one egg: burn, release 6, reserve 6, request a word.
        vm.expectEmit(itemsAddr);
        emit IERC1155.TransferSingle(address(draw), w, address(0), LaunchTerms.BREEDS_EGG, 1);
        vm.expectEmit(address(treasury));
        emit Treasury.Released(game, 6e18);
        vm.expectEmit(address(treasury));
        emit Treasury.Reserved(game, 6e18);
        vm.expectEmit(address(coordinator));
        emit RandomnessCoordinator.Requested(
            1, game, address(draw), bytes32(uint256(2)), 1, DICE_FEE
        );
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(
            2, game, FRIEND, w, LaunchTerms.BREEDS_PLAY, 1, 3, 6e18, 1, context, 0
        );
        vm.prank(o);
        uint256 playId = draw.commit(game, LaunchTerms.BREEDS_PLAY, FRIEND, 1, context, 0);
        assertEq(playId, 2, "commitId 2");
        assertFalse(_isSettled(playId));
        assertEq(_requestOf(playId), 1, "requestId 1");
        assertEq(items(game).balanceOf(w, LaunchTerms.BREEDS_EGG), 4, "one egg burned");
        // The pending play holds exactly the egg's 6 RF: reserved is unchanged.
        _assertLedger(game, 9975e18, 30e18, 0);
        assertSolvent(address(rf));

        // Before the word: settlement and rollFor wait.
        vm.expectRevert(DrawModule.RandomnessPending.selector);
        draw.settle(playId);
        vm.expectRevert(DrawModule.RandomnessPending.selector);
        draw.rollFor(playId, 0);

        // Step 7: Dice delivers a word whose roll is 7_100 -> row 1 Spotted (class 3, 1 RF).
        bytes32 word = _wordForRoll(playId, 7100);
        _reveal(playId, word);
        assertEq(draw.rollFor(playId, 0), 7100, "rollFor reproduces the roll");
        _assertLedger(game, 9975e18, 30e18, 0);

        // Step 8: anyone settles: reserved 24, owed 1, free 9_980; one Spotted minted.
        vm.expectEmit(address(treasury));
        emit Treasury.Resolved(game, 6e18, 1e18, 0, w, 0);
        vm.expectEmit(itemsAddr);
        emit IERC1155.TransferSingle(address(draw), address(0), w, LaunchTerms.BREEDS_SPOTTED, 1);
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(playId, game, FRIEND, w, _rows1(1), 0, 1e18);
        vm.prank(keeper);
        draw.settle(playId);
        assertTrue(_isSettled(playId));
        assertEq(items(game).balanceOf(w, LaunchTerms.BREEDS_SPOTTED), 1, "Spotted minted");
        // Step 10 trace after step 8: 10_005 = 9_980 + 24 + 1.
        _assertLedger(game, 9980e18, 24e18, 1e18);
        assertEq(rf.balanceOf(address(treasury)), 10_005e18);
        assertSolvent(address(rf));

        vm.expectRevert(DrawModule.AlreadySettled.selector);
        draw.settle(playId);

        // Step 9: trade in the Spotted for its fixed 1 RF, paid from owed to the wallet.
        vm.expectEmit(itemsAddr);
        emit IERC1155.TransferSingle(address(draw), w, address(0), LaunchTerms.BREEDS_SPOTTED, 1);
        vm.expectEmit(address(treasury));
        emit Treasury.OwedPaid(game, w, 1e18);
        vm.expectEmit(address(draw));
        emit DrawModule.Redeemed(game, FRIEND, w, LaunchTerms.BREEDS_SPOTTED, 1, 1e18, 0);
        vm.prank(o);
        draw.redeem(game, FRIEND, LaunchTerms.BREEDS_SPOTTED, 1, 0);
        assertEq(rf.balanceOf(w), 1e18, "redemption lands in the wallet");
        assertEq(rf.balanceOf(o), 0, "never the owner address");
        assertEq(items(game).balanceOf(w, LaunchTerms.BREEDS_SPOTTED), 0);
        // Step 10 trace after step 9: 10_004 = 9_980 + 24 + 0.
        _assertLedger(game, 9980e18, 24e18, 0);
        assertEq(rf.balanceOf(address(treasury)), 10_004e18);
        assertSolvent(address(rf));

        // Eggs cannot be redeemed (no value) and an empty tier cannot be redeemed twice.
        vm.expectRevert(DrawModule.NotRedeemable.selector);
        vm.prank(o);
        draw.redeem(game, FRIEND, LaunchTerms.BREEDS_EGG, 1, 0);
    }

    /// @dev Section 7.1 step 1, the alternative: paying from the Friend wallet means calling
    /// through `W.execute`, which makes the wallet the payer; there is no payer parameter.
    function testFlow71BreedsBuyPaidFromTheWalletThroughExecute() public {
        uint256 game = breedsId;
        rf.mint(w, 2e18);
        _viaWallet(o, FRIEND, address(rf), abi.encodeCall(rf.approve, (address(treasury), 2e18)));

        vm.expectEmit(address(treasury));
        emit Treasury.Collected(game, w, _legs(2e18, 0, 0, 0));
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(1, game, FRIEND, w, LaunchTerms.BREEDS_BUY, 2, 3, 12e18, 0, 0, 0);
        _viaWallet(
            o,
            FRIEND,
            address(draw),
            abi.encodeCall(draw.commit, (game, LaunchTerms.BREEDS_BUY, FRIEND, 2, 0, 0))
        );
        assertEq(rf.balanceOf(w), 0, "the wallet paid");
        assertEq(items(game).balanceOf(w, LaunchTerms.BREEDS_EGG), 2);
        _assertLedger(game, 10_002e18 - 12e18, 12e18, 0);
        assertSolvent(address(rf));

        // A stranger holding an allowance can never be charged for someone else's Friend.
        address stranger = makeAddr("stranger");
        giveRF(stranger, 1e18);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        vm.prank(stranger);
        draw.commit(game, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
    }

    // ---------------------------------------------------------- 7.2 Penalty Kings, owned

    /// @dev Section 7.2 steps 1..3: O buys a 2-pack (gen 3 split), the word picks rows
    /// `[0, 2, 6, 1]` -> balls 1, 3, 7, 2; no Treasury call at settlement. Returns the ledger.
    function _parkPackWithGoldenBoot() internal returns (uint256 free) {
        uint256 game = parkId;
        giveUSDG(o, 4e6);

        // Steps 1..2: collect routes 93% to free and accrues both fees; nothing reserved.
        vm.expectEmit(address(treasury));
        emit Treasury.Collected(game, o, _legs(3_720_000, 0, 210_000, 70_000));
        vm.expectEmit(address(coordinator));
        emit RandomnessCoordinator.Requested(
            1, game, address(draw), bytes32(uint256(1)), 1, DICE_FEE
        );
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(1, game, FRIEND, w, LaunchTerms.PARK_PACK, 2, 3, 0, 1, 0, 0);
        vm.prank(o);
        uint256 packId = draw.commit(game, LaunchTerms.PARK_PACK, FRIEND, 2, 0, 0);
        assertEq(packId, 1);
        assertEq(usdg.balanceOf(o), 0, "O paid 4 USDG");
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), 210_000, "developer fee");
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), 70_000, "operator fee");
        assertEq(usdg.balanceOf(PARK_DEVELOPER), 0, "fees accrue, never transferred inline");
        free = 5000e6 + 3_720_000;
        _assertLedger(game, free, 0, 0);
        assertSolvent(address(usdg));

        // Step 3: four rolls pick rows [0, 2, 6, 1]; mints aggregate per class, ids ascending.
        uint8[] memory picked = new uint8[](4);
        picked[0] = 0;
        picked[1] = 2;
        picked[2] = 6;
        picked[3] = 1;
        bytes32 word = _wordForRows(packId, game, LaunchTerms.PARK_PACK, 0, picked);
        _reveal(packId, word);
        uint16[] memory bounds = _bounds(game, LaunchTerms.PARK_PACK, 0);
        for (uint256 i; i < 4; ++i) {
            uint16 roll = draw.rollFor(packId, i);
            assertTrue(roll < bounds[picked[i]], "rollFor below the row's upper bound");
            assertTrue(picked[i] == 0 || roll >= bounds[picked[i] - 1], "rollFor at or above");
        }
        vm.expectEmit(address(items(game)));
        emit IERC1155.TransferBatch(address(draw), address(0), w, _ids4(1, 2, 3, 7), _ones(4));
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(packId, game, FRIEND, w, picked, 0, 0);
        vm.prank(keeper);
        draw.settle(packId);
        assertEq(items(game).balanceOf(w, 1), 1, "Scuffed");
        assertEq(items(game).balanceOf(w, 2), 1, "Training");
        assertEq(items(game).balanceOf(w, 3), 1, "Match");
        assertEq(items(game).balanceOf(w, 7), 1, "Golden Boot");
        _assertLedger(game, free, 0, 0);
        assertSolvent(address(usdg));
    }

    /// @dev Section 7.2 steps 4..8: kick the Golden Boot, reserve its 64 USDG maximum, a
    /// blocked USDG wallet keeps the reservation and the commit retryable, roll 150 pays 32
    /// USDG, fees are paid out permissionlessly.
    function testFlow72ParkPackSettleKickGoldenBootSettlePayFees() public {
        uint256 game = parkId;
        uint256 free = _parkPackWithGoldenBoot();
        uint8 kick = LaunchTerms.parkKickAction(7);
        assertEq(kick, 8, "action 8 = kick Golden Boot");

        // Steps 4..5: burn the ball (reserve 0, no release), reserve 64 USDG, request a word.
        vm.expectEmit(address(items(game)));
        emit IERC1155.TransferSingle(address(draw), w, address(0), 7, 1);
        vm.expectEmit(address(treasury));
        emit Treasury.Reserved(game, 64e6);
        vm.expectEmit(address(coordinator));
        emit RandomnessCoordinator.Requested(
            2, game, address(draw), bytes32(uint256(2)), 2, DICE_FEE
        );
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(2, game, FRIEND, w, kick, 1, 3, 64e6, 2, 0, 0);
        vm.prank(o);
        uint256 kickId = draw.commit(game, kick, FRIEND, 1, 0, 0);
        assertEq(kickId, 2);
        assertEq(items(game).balanceOf(w, 7), 0, "ball burned at commit");
        _assertLedger(game, free - 64e6, 64e6, 0);
        assertSolvent(address(usdg));

        // Step 6: roll 150 -> row 1 -> 32 USDG.
        bytes32 word = _wordForRoll(kickId, 150);
        _reveal(kickId, word);
        assertEq(draw.rollFor(kickId, 0), 150);

        // Step 7: USDG rejects W: the whole settle reverts, reserved stays, the commit stays
        // open and the same word settles later with the same result.
        usdg.blockRecipient(w);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdg))
        );
        vm.prank(keeper);
        draw.settle(kickId);
        assertFalse(_isSettled(kickId), "still pending");
        _assertLedger(game, free - 64e6, 64e6, 0);
        assertEq(usdg.balanceOf(w), 0);
        assertSolvent(address(usdg));
        usdg.blockRecipient(address(0));

        vm.expectEmit(address(treasury));
        emit Treasury.Resolved(game, 64e6, 0, 0, w, 32e6);
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(kickId, game, FRIEND, w, _rows1(1), 32e6, 0);
        vm.prank(keeper);
        draw.settle(kickId);
        assertTrue(_isSettled(kickId));
        assertEq(usdg.balanceOf(w), 32e6, "prize lands in the wallet");
        assertEq(usdg.balanceOf(o), 0);
        _assertLedger(game, free - 32e6, 0, 0);
        assertSolvent(address(usdg));

        // Step 8: anyone pays the accrued fees at any cadence.
        vm.expectEmit(address(treasury));
        emit Treasury.FeesPaid(address(usdg), PARK_DEVELOPER, 210_000);
        vm.prank(keeper);
        treasury.payFees(address(usdg), PARK_DEVELOPER);
        assertEq(usdg.balanceOf(PARK_DEVELOPER), 210_000);
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), 0);
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.payFees(address(usdg), PARK_DEVELOPER);
        vm.expectEmit(address(treasury));
        emit Treasury.FeesPaid(address(usdg), PARK_OPERATOR, 70_000);
        treasury.payFees(address(usdg), PARK_OPERATOR);
        assertEq(usdg.balanceOf(PARK_OPERATOR), 70_000);
        _assertLedger(game, free - 32e6, 0, 0);
        assertEq(usdg.balanceOf(address(treasury)), free - 32e6, "only free remains");
        assertSolvent(address(usdg));
    }

    /// @dev Section 7.2 step 6 for every tier of the gen-3 Golden Boot table `[100 -> 64, 100
    /// -> 32, 200 -> 16, 400 -> 8, 800 -> 4, 4050 -> 2, 4350 saved]`: a word crafted so
    /// `rollFor` lands on the first roll of each row pays exactly that row's prize.
    function testFlow72KickGoldenBootLandsOnEveryPrizeTier() public {
        uint256 game = parkId;
        uint256 free = _parkPackWithGoldenBoot();
        uint8 kick = LaunchTerms.parkKickAction(7);
        uint16[7] memory firstRoll = [uint16(0), 100, 200, 400, 800, 1600, 5650];
        uint256[7] memory prize = [uint256(64e6), 32e6, 16e6, 8e6, 4e6, 2e6, 0];
        uint16[] memory bounds = _bounds(game, kick, 3);
        assertEq(bounds.length, 7, "seven rows");
        assertEq(bounds[5], 10_000 - GB_SAVED_GEN3, "saved row starts at 5650");

        uint256 snapshot = vm.snapshotState();
        for (uint8 tier; tier < 7; ++tier) {
            assertTrue(vm.revertToState(snapshot), "revert");
            vm.prank(o);
            uint256 kickId = draw.commit(game, kick, FRIEND, 1, 0, 0);
            _assertLedger(game, free - 64e6, 64e6, 0);
            _reveal(kickId, _wordForRoll(kickId, firstRoll[tier]));
            assertEq(draw.rollFor(kickId, 0), firstRoll[tier], "rollFor");

            vm.expectEmit(address(treasury));
            emit Treasury.Resolved(game, 64e6, 0, 0, w, prize[tier]);
            vm.expectEmit(address(draw));
            emit DrawModule.Settled(kickId, game, FRIEND, w, _rows1(tier), prize[tier], 0);
            vm.prank(keeper);
            draw.settle(kickId);
            assertEq(usdg.balanceOf(w), prize[tier], "prize");
            _assertLedger(game, free - prize[tier], 0, 0);
            assertSolvent(address(usdg));
        }
    }

    // -------------------------------------------------------- 7.3 Penalty Kings, custody

    /// @dev Section 7.3: Friend 777 (gen 5) held by FriendCustody; the executor commits with
    /// order ids, replays are refused, a reverted call leaves its id unused, every prize lands
    /// in the Friend's canonical wallet (the bound beneficiary is never read on chain), and a
    /// Friend that left custody is served by the owned path only.
    function testFlow73ParkCustodyPathCommitReplayLeftCustody() public {
        uint256 game = parkId;
        address privyWallet = makeAddr("privy");
        address newOwner = makeAddr("newOwner");
        mintFriend(address(custody), CUSTODIED, 5);
        custody.bind(CUSTODIED, privyWallet);
        address w777 = walletOf(CUSTODIED);
        giveUSDG(executor, 4e6);

        // Only the executor may present an order id; without one the executor is a stranger.
        vm.expectRevert(DrawModule.OnlyCustodyExecutor.selector);
        vm.prank(o);
        draw.commit(game, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, A1);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        vm.prank(executor);
        draw.commit(game, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, 0);
        assertFalse(registry.custodyActionUsed(A1), "a reverted call leaves the id unused");

        // Step 2: the executor buys a 2-pack for 777; gen 5 split (9100, 675, 225).
        vm.expectEmit(address(registry));
        emit GameRegistry.CustodyActionConsumed(A1, game, address(draw));
        vm.expectEmit(address(treasury));
        emit Treasury.Collected(game, executor, _legs(3_640_000, 0, 270_000, 90_000));
        vm.expectEmit(address(coordinator));
        emit RandomnessCoordinator.Requested(
            1, game, address(draw), bytes32(uint256(1)), 1, DICE_FEE
        );
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(
            1, game, CUSTODIED, w777, LaunchTerms.PARK_PACK, 2, 5, 0, 1, 0, A1
        );
        vm.prank(executor);
        uint256 packId = draw.commit(game, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, A1);
        assertTrue(registry.custodyActionUsed(A1));
        assertEq(usdg.balanceOf(executor), 0, "the executor paid");
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), 270_000);
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), 90_000);
        uint256 free = 5000e6 + 3_640_000;
        _assertLedger(game, free, 0, 0);
        assertSolvent(address(usdg));

        // Step 3: A1 is spent for every module, game and function.
        giveUSDG(executor, 4e6);
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        vm.prank(executor);
        draw.commit(game, LaunchTerms.PARK_PACK, CUSTODIED, 2, 0, A1);
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        vm.prank(executor);
        draw.redeem(game, CUSTODIED, 1, 1, A1);
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        vm.prank(executor);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, CUSTODIED, 1, 0, A1);

        // Pack settles to a Golden Boot and three Scuffed balls, minted to W777.
        uint8[] memory picked = new uint8[](4);
        picked[0] = 6;
        _reveal(packId, _wordForRows(packId, game, LaunchTerms.PARK_PACK, 0, picked));
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 7;
        amounts[0] = 3;
        amounts[1] = 1;
        vm.expectEmit(address(items(game)));
        emit IERC1155.TransferBatch(address(draw), address(0), w777, ids, amounts);
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(packId, game, CUSTODIED, w777, picked, 0, 0);
        draw.settle(packId);
        assertEq(items(game).balanceOf(w777, 7), 1);
        assertEq(items(game).balanceOf(w777, 1), 3);
        _assertLedger(game, free, 0, 0);
        assertSolvent(address(usdg));

        // Step 3, last sentence: a reverted custody call (InsufficientFree) leaves A2 unused.
        vm.prank(owner);
        treasury.withdrawFree(game, free);
        _assertLedger(game, 0, 0, 0);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        vm.prank(executor);
        draw.commit(game, LaunchTerms.parkKickAction(7), CUSTODIED, 1, 0, A2);
        assertFalse(registry.custodyActionUsed(A2), "A2 can be retried");
        assertEq(items(game).balanceOf(w777, 7), 1, "the ball was not burned");
        fundGame(game, 5000e6);
        free = 5000e6;
        assertSolvent(address(usdg));

        // Step 4: the executor kicks the Golden Boot with A2; gen 5 roll 50 -> 64 USDG to W777.
        vm.expectEmit(address(registry));
        emit GameRegistry.CustodyActionConsumed(A2, game, address(draw));
        vm.expectEmit(address(treasury));
        emit Treasury.Reserved(game, 64e6);
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(
            2, game, CUSTODIED, w777, LaunchTerms.parkKickAction(7), 1, 5, 64e6, 2, 0, A2
        );
        vm.prank(executor);
        uint256 kickId = draw.commit(game, LaunchTerms.parkKickAction(7), CUSTODIED, 1, 0, A2);
        _assertLedger(game, free - 64e6, 64e6, 0);
        _reveal(kickId, _wordForRoll(kickId, 50));
        vm.expectEmit(address(treasury));
        emit Treasury.Resolved(game, 64e6, 0, 0, w777, 64e6);
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(kickId, game, CUSTODIED, w777, _rows1(0), 64e6, 0);
        vm.prank(keeper);
        draw.settle(kickId);
        assertEq(usdg.balanceOf(w777), 64e6, "prize to the canonical wallet");
        assertEq(usdg.balanceOf(privyWallet), 0, "beneficiary is not read on chain");
        assertEq(usdg.balanceOf(executor), 4e6, "the executor is never paid");
        _assertLedger(game, free - 64e6, 0, 0);
        assertSolvent(address(usdg));

        // The executor cannot act for a Friend that is not custodied.
        vm.expectRevert(FriendAccess.NotCustodied.selector);
        vm.prank(executor);
        draw.commit(game, LaunchTerms.PARK_PACK, FRIEND, 2, 0, A3);
        assertFalse(registry.custodyActionUsed(A3));

        // Step 4, last sentence: 777 leaves custody; the executor is refused and the new
        // owner kicks a Scuffed ball through the owned path (gen 5 goal 3350; roll 0 -> 2 USDG).
        vm.prank(address(custody));
        generations.transfer(CUSTODIED, newOwner);
        vm.expectRevert(FriendAccess.NotCustodied.selector);
        vm.prank(executor);
        draw.commit(game, LaunchTerms.parkKickAction(1), CUSTODIED, 1, 0, A3);
        assertFalse(registry.custodyActionUsed(A3), "A3 stays unused");
        assertEq(items(game).balanceOf(w777, 1), 3);

        vm.expectEmit(address(draw));
        emit DrawModule.Committed(
            3, game, CUSTODIED, w777, LaunchTerms.parkKickAction(1), 1, 5, 2e6, 3, 0, 0
        );
        vm.prank(newOwner);
        uint256 ownedKick = draw.commit(game, LaunchTerms.parkKickAction(1), CUSTODIED, 1, 0, 0);
        _assertLedger(game, free - 64e6 - 2e6, 2e6, 0);
        _reveal(ownedKick, _wordForRoll(ownedKick, 0));
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(ownedKick, game, CUSTODIED, w777, _rows1(0), 2e6, 0);
        draw.settle(ownedKick);
        assertEq(usdg.balanceOf(w777), 66e6, "items and prizes follow the Friend");
        assertEq(usdg.balanceOf(newOwner), 0);
        _assertLedger(game, free - 66e6, 0, 0);
        assertSolvent(address(usdg));
    }

    // ------------------------------------------------------------------ 7.6 Retire a game

    /// @dev Section 7.6 steps 1..3 for both Draw games: retiring stops purchases only; kicks,
    /// egg plays, settlement, redemption and funding keep working; `withdrawFree` is bounded by
    /// `free` and paid to the funder; eggs (reserved) and tier tokens (owed) are never stranded.
    function testFlow76RetireDrawGamesStopsPurchasesOnly() public {
        // Positions before retirement: PK commit 1 (pack, settled), Breeds commits 2 (5 eggs)
        // and 3 (one play settled to Spotted).
        uint256 parkFree = _parkPackWithGoldenBoot();
        giveRF(o, 5e18);
        vm.startPrank(o);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 5, 0, 0);
        uint256 playId = draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        vm.stopPrank();
        assertEq(playId, 3);
        _reveal(playId, _wordForRoll(playId, 7100));
        draw.settle(playId);
        _assertLedger(breedsId, 9980e18, 24e18, 1e18);
        assertSolvent(address(rf));

        // Step 1.
        vm.expectEmit(address(registry));
        emit GameRegistry.GameRetired(parkId);
        vm.prank(owner);
        registry.retireGame(parkId);
        vm.expectEmit(address(registry));
        emit GameRegistry.GameRetired(breedsId);
        vm.prank(owner);
        registry.retireGame(breedsId);
        assertFalse(registry.isActive(parkId));
        assertFalse(registry.isActive(breedsId));
        vm.expectRevert(GameRegistry.WrongStatus.selector);
        vm.prank(owner);
        registry.retireGame(parkId);

        // Step 2: Currency actions revert GameNotActive; funds are never pulled.
        giveUSDG(o, 2e6);
        giveRF(o, 1e18);
        vm.expectRevert(DrawModule.GameNotActive.selector);
        vm.prank(o);
        draw.commit(parkId, LaunchTerms.PARK_PACK, FRIEND, 1, 0, 0);
        vm.expectRevert(DrawModule.GameNotActive.selector);
        vm.prank(o);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        assertEq(usdg.balanceOf(o), 2e6);
        assertEq(rf.balanceOf(o), 1e18);
        _assertLedger(parkId, parkFree, 0, 0);

        // Kicks keep working: Golden Boot, roll 150 -> 32 USDG.
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(
            4, parkId, FRIEND, w, LaunchTerms.parkKickAction(7), 1, 3, 64e6, 3, 0, 0
        );
        vm.prank(o);
        uint256 kickId = draw.commit(parkId, LaunchTerms.parkKickAction(7), FRIEND, 1, 0, 0);
        _assertLedger(parkId, parkFree - 64e6, 64e6, 0);
        _reveal(kickId, _wordForRoll(kickId, 150));
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(kickId, parkId, FRIEND, w, _rows1(1), 32e6, 0);
        draw.settle(kickId);
        assertEq(usdg.balanceOf(w), 32e6);
        parkFree -= 32e6;
        _assertLedger(parkId, parkFree, 0, 0);
        assertSolvent(address(usdg));

        // Egg plays keep working: roll 9_750 -> Prismatic (6 RF owed).
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(
            5, breedsId, FRIEND, w, LaunchTerms.BREEDS_PLAY, 1, 3, 6e18, 4, 0, 0
        );
        vm.prank(o);
        uint256 play2 = draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        _assertLedger(breedsId, 9980e18, 24e18, 1e18);
        _reveal(play2, _wordForRoll(play2, 9750));
        vm.expectEmit(address(treasury));
        emit Treasury.Resolved(breedsId, 6e18, 6e18, 0, w, 0);
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(play2, breedsId, FRIEND, w, _rows1(3), 0, 6e18);
        draw.settle(play2);
        _assertLedger(breedsId, 9980e18, 18e18, 7e18);
        assertSolvent(address(rf));

        // Redemption keeps working.
        vm.expectEmit(address(draw));
        emit DrawModule.Redeemed(breedsId, FRIEND, w, LaunchTerms.BREEDS_PRISMATIC, 1, 6e18, 0);
        vm.prank(o);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_PRISMATIC, 1, 0);
        assertEq(rf.balanceOf(w), 6e18);
        _assertLedger(breedsId, 9980e18, 18e18, 1e18);
        assertSolvent(address(rf));

        // Funding keeps working, from anyone.
        usdg.mint(keeper, 1e6);
        vm.startPrank(keeper);
        usdg.approve(address(treasury), 1e6);
        vm.expectEmit(address(treasury));
        emit Treasury.Funded(parkId, keeper, 1e6);
        treasury.fund(parkId, 1e6);
        vm.stopPrank();
        parkFree += 1e6;
        _assertLedger(parkId, parkFree, 0, 0);

        // Step 3: withdrawFree is owner-only, bounded by free and paid to the funder only.
        vm.expectRevert(Treasury.NotRegistryOwner.selector);
        vm.prank(o);
        treasury.withdrawFree(parkId, 1);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        vm.prank(owner);
        treasury.withdrawFree(parkId, parkFree + 1);
        vm.expectEmit(address(treasury));
        emit Treasury.FreeWithdrawn(parkId, funder, parkFree);
        vm.prank(owner);
        treasury.withdrawFree(parkId, parkFree);
        assertEq(usdg.balanceOf(funder), parkFree);
        assertEq(usdg.balanceOf(owner), 0);
        _assertLedger(parkId, 0, 0, 0);
        assertEq(usdg.balanceOf(address(treasury)), 280_000, "only the accrued fees remain");
        assertSolvent(address(usdg));

        // Kicks revert InsufficientFree until someone funds again; the ball is not burned.
        vm.expectRevert(Treasury.InsufficientFree.selector);
        vm.prank(o);
        draw.commit(parkId, LaunchTerms.parkKickAction(1), FRIEND, 1, 0, 0);
        assertEq(items(parkId).balanceOf(w, 1), 1);
        fundGame(parkId, 2e6);
        vm.prank(o);
        uint256 kick1 = draw.commit(parkId, LaunchTerms.parkKickAction(1), FRIEND, 1, 0, 0);
        _assertLedger(parkId, 0, 2e6, 0);
        _reveal(kick1, _wordForRoll(kick1, 9999));
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(kick1, parkId, FRIEND, w, _rows1(1), 0, 0);
        draw.settle(kick1);
        _assertLedger(parkId, 2e6, 0, 0);
        assertSolvent(address(usdg));

        // Eggs and tier tokens are unaffected by draining Breeds' free to zero: a play still
        // works from the egg's own reserve and the Spotted still redeems from owed.
        vm.prank(owner);
        treasury.withdrawFree(breedsId, 9980e18);
        _assertLedger(breedsId, 0, 18e18, 1e18);
        assertEq(rf.balanceOf(funder), 9980e18);
        vm.expectEmit(address(treasury));
        emit Treasury.Released(breedsId, 6e18);
        vm.expectEmit(address(treasury));
        emit Treasury.Reserved(breedsId, 6e18);
        vm.prank(o);
        uint256 play3 = draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        _assertLedger(breedsId, 0, 18e18, 1e18);
        _reveal(play3, _wordForRoll(play3, 0));
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(play3, breedsId, FRIEND, w, _rows1(0), 0, 5e17);
        draw.settle(play3);
        _assertLedger(breedsId, 55e17, 12e18, 15e17);
        vm.prank(o);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_SPOTTED, 1, 0);
        vm.prank(o);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_COMMON, 1, 0);
        assertEq(rf.balanceOf(w), 75e17);
        _assertLedger(breedsId, 55e17, 12e18, 0);
        assertEq(items(breedsId).balanceOf(w, LaunchTerms.BREEDS_EGG), 2, "two eggs kept");
        assertEq(rf.balanceOf(address(treasury)), 10_005e18 - 9980e18 - 75e17);
        assertSolvent(address(rf));
    }

    /// @dev Section 7.6 step 4 for Rare Royale: retiring blocks `openRound`, `enter` and
    /// `depositCredit` only; the open round closes, spends, settles and refunds as usual and
    /// credit withdrawal is unaffected once no live round uses the Friend.
    function testFlow76RetireRoyaleBlocksOpenEnterDepositOnly() public {
        uint256 game = royaleId;
        bytes32 secret = keccak256("royale secret");
        uint256[] memory fighters = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            fighters[i] = 2001 + i;
            mintFriend(o, fighters[i], 2);
        }
        mintFriend(o, 2006, 2);
        giveRF(o, 16e18);

        // Credit, two open rounds and five entries before retirement.
        vm.expectEmit(address(treasury));
        emit Treasury.CreditDeposited(game, 2001, o, 10e18);
        vm.prank(o);
        round.depositCredit(game, 2001, 10e18);
        vm.expectEmit(address(round));
        emit RoundModule.RoundOpened(
            1, game, keccak256(abi.encode(secret)), uint64(block.timestamp)
        );
        vm.prank(settler);
        uint256 roundId = round.openRound(game, keccak256(abi.encode(secret)));
        vm.prank(settler);
        uint256 emptyRound = round.openRound(game, keccak256(abi.encode(secret)));
        for (uint256 i; i < 5; ++i) {
            vm.expectEmit(address(treasury));
            emit Treasury.Collected(game, o, _legs(0, 1e18, 0, 0));
            vm.expectEmit(address(round));
            // Entered.seat is 1-based.
            // forge-lint: disable-next-line(unsafe-typecast)
            emit RoundModule.Entered(roundId, fighters[i], walletOf(fighters[i]), o, uint16(i + 1));
            vm.prank(o);
            round.enter(roundId, fighters[i]);
        }
        (uint256 free, uint256 reserved, uint256 owed, uint256 credit) = ledger(game);
        assertEq(free + owed, 0);
        assertEq(reserved, 5e18, "entries reserved whole");
        assertEq(credit, 10e18);
        assertSolvent(address(rf));

        vm.expectEmit(address(registry));
        emit GameRegistry.GameRetired(game);
        vm.prank(owner);
        registry.retireGame(game);

        // Blocked: new rounds, new entries, new deposits.
        vm.expectRevert(RoundModule.GameNotActive.selector);
        vm.prank(settler);
        round.openRound(game, keccak256(abi.encode(secret)));
        vm.expectRevert(RoundModule.GameNotActive.selector);
        vm.prank(o);
        round.enter(roundId, 2006);
        vm.expectRevert(RoundModule.GameNotActive.selector);
        vm.prank(o);
        round.depositCredit(game, 2001, 1e18);
        // Withdrawal waits for the live round, not for the game's status.
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        vm.prank(o);
        round.withdrawCredit(game, 2001, 1e18);
        assertEq(rf.balanceOf(o), 1e18, "nothing pulled");

        // Close, spend, settle as usual.
        vm.expectEmit(address(round));
        emit RoundModule.RoundClosed(roundId, 5, 4e18, 1);
        vm.prank(settler);
        round.closeRound(roundId);
        vm.expectEmit(address(treasury));
        emit Treasury.CreditSpent(game, 2001, 2e18, 1e18, 1e18);
        vm.expectEmit(address(round));
        emit RoundModule.Spent(roundId, 2001, 2002, 3, 2e18);
        vm.prank(settler);
        round.spend(roundId, 2001, 2002, 3);
        assertEq(treasury.creditOf(game, 2001), 8e18);
        assertSolvent(address(rf));

        bytes32 word = keccak256("royale word");
        uint64 sequence = sequenceOf(1);
        vm.expectEmit(address(coordinator));
        emit RandomnessCoordinator.Fulfilled(1, sequence, word);
        assertTrue(dice.reveal(sequence, word), "callback failed");

        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 2e18;
        amounts[1] = 1e18;
        amounts[2] = 5e17;
        amounts[3] = 25e16;
        amounts[4] = 25e16;
        vm.expectEmit(address(treasury));
        emit Treasury.ReservedRouted(game, 5e17, 5e17);
        for (uint256 i; i < 5; ++i) {
            vm.expectEmit(address(treasury));
            emit Treasury.Resolved(game, amounts[i], 0, 0, walletOf(fighters[i]), amounts[i]);
        }
        vm.expectEmit(address(round));
        emit RoundModule.RoundSettled(roundId, word, secret, fighters, amounts);
        vm.prank(settler);
        round.settleRound(roundId, secret, fighters, amounts);
        for (uint256 i; i < 5; ++i) {
            assertEq(rf.balanceOf(walletOf(fighters[i])), amounts[i], "payout");
        }
        (, reserved,, credit) = ledger(game);
        assertEq(reserved, 0, "pot fully paid");
        assertEq(credit, 8e18);
        assertEq(treasury.rewardsPending(), 15e17);
        assertSolvent(address(rf));

        // Credit withdrawal, the empty round's refund and rewards forwarding are unaffected.
        vm.expectEmit(address(treasury));
        emit Treasury.CreditWithdrawn(game, 2001, walletOf(2001), 8e18);
        vm.prank(o);
        round.withdrawCredit(game, 2001, 8e18);
        assertEq(rf.balanceOf(walletOf(2001)), 10e18, "credit returns to the wallet");
        vm.expectEmit(address(round));
        emit RoundModule.RoundRefunded(emptyRound, 0, false);
        vm.prank(settler);
        round.closeRound(emptyRound);
        vm.expectEmit(address(treasury));
        emit Treasury.RewardsForwarded(address(manager), 15e17);
        treasury.forwardRewards();
        (free, reserved, owed, credit) = ledger(game);
        assertEq(free + reserved + owed + credit, 0, "Royale ledger fully unwound");
        assertEq(rf.balanceOf(address(treasury)), 10_000e18, "only Breeds' stake remains");
        assertSolvent(address(rf));
    }
}
