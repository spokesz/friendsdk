// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Fixture } from "./Fixture.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { Treasury } from "../src/Treasury.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { MockFriendWallet } from "./doubles/ExternalDoubles.sol";

/// @dev Rare Royale end to end through the real registry, Treasury and coordinator: SPEC.md
/// section 7.4 (open, enter, close, spend, settle, withdraw credit, forward rewards), the short
/// round refund, abandonment from Open and from Closed, one unsettled round per Friend, the exact
/// pot check and retirement semantics (section 7.6 step 4).
contract RoyaleFlowsTest is Fixture {
    uint256 internal constant FRIEND = 1234;
    uint256 internal constant ENTRY = 1e18;
    uint256 internal constant BREEDS_STAKE = 10_000e18;
    uint8 internal constant SECOND_LIFE_I = 3;

    bytes32 internal constant SECRET = keccak256("royale secret");
    bytes32 internal constant WORD = keccak256("royale word");

    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    // friends[0] is Friend 1234 owned by alice; the rest are eleven more hardwired Friends.
    uint256[] internal friends;

    function setUp() public override {
        super.setUp();
        mintFriend(alice, FRIEND, 3);
        friends.push(FRIEND);
        for (uint256 i = 1; i < 12; ++i) {
            uint256 id = 2000 + i;
            // Generations 1..6 all play; only generation 0 and > 6 are refused.
            // forge-lint: disable-next-line(unsafe-typecast)
            mintFriend(makeAddr(string.concat("player", vm.toString(i))), id, uint8(i % 6 + 1));
            friends.push(id);
        }
    }

    // ----------------------------------------------------------------------- helpers

    function _secretHash() internal pure returns (bytes32) {
        return keccak256(abi.encode(SECRET));
    }

    function _open() internal returns (uint256 roundId) {
        vm.prank(settler);
        roundId = round.openRound(royaleId, _secretHash());
    }

    /// @dev The Friend's owner pays the entry from its own address.
    function _enter(uint256 roundId, uint256 friendId) internal {
        address holder = generations.ownerOf(friendId);
        giveRF(holder, ENTRY);
        vm.prank(holder);
        round.enter(roundId, friendId);
    }

    /// @dev Enters friends[from .. from + count).
    function _enterRange(uint256 roundId, uint256 from, uint256 count) internal {
        for (uint256 i = from; i < from + count; ++i) {
            _enter(roundId, friends[i]);
        }
    }

    /// @dev The canonical wallet pays the entry itself: the owner calls through execute. The
    /// wallet address is resolved before the prank so the prank reaches `execute`.
    function _enterViaWallet(uint256 roundId, uint256 friendId) internal {
        MockFriendWallet wallet = MockFriendWallet(payable(walletOf(friendId)));
        vm.prank(generations.ownerOf(friendId));
        wallet.execute(address(round), 0, abi.encodeCall(RoundModule.enter, (roundId, friendId)), 0);
    }

    function _close(uint256 roundId) internal returns (uint256 requestId) {
        vm.prank(settler);
        round.closeRound(roundId);
        (,,,, requestId) = round.rounds(roundId);
    }

    function _status(uint256 roundId) internal view returns (RoundModule.Status status) {
        (,,, status,) = round.rounds(roundId);
    }

    function _openedAt(uint256 roundId) internal view returns (uint64 openedAt) {
        (,, openedAt,,) = round.rounds(roundId);
    }

    /// @dev Ten payouts for twelve entries, summing to exactly 9.6e18; Friend 1234 leads.
    function _twelveEntryPayouts()
        internal
        view
        returns (uint256[] memory ids, uint256[] memory amounts)
    {
        ids = new uint256[](10);
        amounts = new uint256[](10);
        uint256[10] memory ladder =
            [uint256(3e18), 2e18, 1.5e18, 1e18, 0.6e18, 0.5e18, 0.4e18, 0.3e18, 0.2e18, 0.1e18];
        for (uint256 i; i < 10; ++i) {
            ids[i] = friends[i];
            amounts[i] = ladder[i];
        }
    }

    function _sum(uint256[] memory amounts) internal pure returns (uint256 total) {
        for (uint256 i; i < amounts.length; ++i) {
            total += amounts[i];
        }
    }

    function _royaleLedger()
        internal
        view
        returns (uint256 free, uint256 reserved, uint256 owed, uint256 credit)
    {
        return ledger(royaleId);
    }

    function _assertRoyaleLedger(uint256 free, uint256 reserved, uint256 owed, uint256 credit)
        internal
        view
    {
        (uint256 f, uint256 r, uint256 o, uint256 c) = _royaleLedger();
        assertEq(f, free, "royale free");
        assertEq(r, reserved, "royale reserved");
        assertEq(o, owed, "royale owed");
        assertEq(c, credit, "royale credit");
    }

    /// @dev RF the Treasury holds for Rare Royale: the Breeds stake is the only other RF ledger.
    function _royaleBalance() internal view returns (uint256) {
        return rf.balanceOf(address(treasury)) - BREEDS_STAKE;
    }

    // ------------------------------------------------------------- SPEC 7.4 steps 1-8, 11

    function testFullRoundFlowTwelveEntrants() public {
        uint256 roundId = _step1And2DepositAndOpen();
        _step3EnterTwelve(roundId);
        // 12 entries + 10 credit all sit in the Treasury: nothing burned or routed at entry.
        assertEq(_royaleBalance(), 22e18, "entries burn nothing");
        // No RF is minted after this point, so supply deltas are exactly the burns.
        uint256 supplyBefore = rf.totalSupply();
        uint256 requestId = _step4Close(roundId);
        _step5SpendSecondLife(roundId, requestId);
        assertEq(supplyBefore - rf.totalSupply(), 1e18, "half of the spend burned");
        (uint256[] memory ids, uint256[] memory amounts) = _step6Settle(roundId);
        _step11InvariantTrace(supplyBefore);
        _step7And8WithdrawAndForward();

        // Settlement is final: the settler cannot pay the list twice.
        vm.prank(settler);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        round.settleRound(roundId, SECRET, ids, amounts);
    }

    function _step1And2DepositAndOpen() internal returns (uint256 roundId) {
        // Step 1: prefund credit before the round.
        giveRF(alice, 10e18);
        vm.expectEmit(address(treasury));
        emit Treasury.CreditDeposited(royaleId, FRIEND, alice, 10e18);
        vm.prank(alice);
        round.depositCredit(royaleId, FRIEND, 10e18);
        assertEq(treasury.creditOf(royaleId, FRIEND), 10e18);
        _assertRoyaleLedger(0, 0, 0, 10e18);

        // Step 2: the settler opens the round with its secret hash.
        vm.expectEmit(true, true, false, true, address(round));
        emit RoundModule.RoundOpened(1, royaleId, _secretHash(), uint64(block.timestamp));
        roundId = _open();
        assertEq(roundId, 1);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Open));
    }

    /// @dev Step 3: twelve Friends enter; each entry is reserved whole, nothing routed yet.
    function _step3EnterTwelve(uint256 roundId) internal {
        giveRF(alice, ENTRY);
        vm.expectEmit(address(treasury));
        emit Treasury.Collected(royaleId, alice, ITreasury.Legs(0, ENTRY, 0, 0, 0, 0));
        vm.expectEmit(address(round));
        emit RoundModule.Entered(roundId, FRIEND, walletOf(FRIEND), alice, 1);
        vm.prank(alice);
        round.enter(roundId, FRIEND);
        assertEq(round.roundOf(royaleId, FRIEND), roundId);

        // The second entrant pays from its canonical wallet through execute.
        uint256 second = friends[1];
        giveRF(walletOf(second), ENTRY);
        vm.expectEmit(address(round));
        emit RoundModule.Entered(roundId, second, walletOf(second), walletOf(second), 2);
        _enterViaWallet(roundId, second);
        _enterRange(roundId, 2, 10);
        assertEq(round.entrants(roundId).length, 12);
        _assertRoyaleLedger(0, 12e18, 0, 10e18);
        assertEq(treasury.rewardsPending(), 0, "entries route nothing");
        assertEq(round.potOf(roundId), 9.6e18);
    }

    /// @dev Step 4: close requests one word bound to the round.
    function _step4Close(uint256 roundId) internal returns (uint256 requestId) {
        vm.expectEmit(true, false, false, true, address(round));
        emit RoundModule.RoundClosed(roundId, 12, 9.6e18, coordinator.requestCount() + 1);
        requestId = _close(roundId);
        assertTrue(requestId != 0);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Closed));
        bytes32 key = keccak256(abi.encode(address(round), royaleId, bytes32(roundId)));
        assertEq(coordinator.boundRequest(key), requestId);
        _assertRoyaleLedger(0, 12e18, 0, 10e18);
    }

    /// @dev Step 5: Dice delivers; the settler debits credit for a second life I (2 RF, 50/50).
    function _step5SpendSecondLife(uint256 roundId, uint256 requestId) internal {
        fulfill(requestId, WORD);
        vm.expectEmit(address(treasury));
        emit Treasury.CreditSpent(royaleId, FRIEND, 2e18, 1e18, 1e18);
        vm.expectEmit(address(round));
        emit RoundModule.Spent(roundId, FRIEND, friends[5], SECOND_LIFE_I, 2e18);
        vm.prank(settler);
        round.spend(roundId, FRIEND, friends[5], SECOND_LIFE_I);
        assertEq(treasury.creditOf(royaleId, FRIEND), 8e18);
        assertEq(treasury.rewardsPending(), 1e18);
        _assertRoyaleLedger(0, 12e18, 0, 8e18);

        // Credit stays locked while the round is live.
        vm.prank(alice);
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        round.withdrawCredit(royaleId, FRIEND, 8e18);
    }

    /// @dev Step 6: settle with a ten-entry payout list summing to the pot, events in order.
    function _step6Settle(uint256 roundId)
        internal
        returns (uint256[] memory ids, uint256[] memory amounts)
    {
        (ids, amounts) = _twelveEntryPayouts();
        assertEq(_sum(amounts), 9.6e18);
        vm.expectEmit(address(treasury));
        emit Treasury.ReservedRouted(royaleId, 1.2e18, 1.2e18);
        for (uint256 i; i < ids.length; ++i) {
            vm.expectEmit(address(treasury));
            emit Treasury.Resolved(royaleId, amounts[i], 0, 0, walletOf(ids[i]), amounts[i]);
        }
        vm.expectEmit(address(round));
        emit RoundModule.RoundSettled(roundId, WORD, SECRET, ids, amounts);
        vm.prank(settler);
        round.settleRound(roundId, SECRET, ids, amounts);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Settled));
        for (uint256 i; i < ids.length; ++i) {
            assertEq(rf.balanceOf(walletOf(ids[i])), amounts[i], "payout landed in the wallet");
        }
        assertEq(rf.balanceOf(walletOf(friends[10])), 0, "unlisted entrant receives nothing");
        assertEq(rf.balanceOf(walletOf(friends[11])), 0, "unlisted entrant receives nothing");
    }

    /// @dev Step 11: the invariant trace at the end of step 6, in exact balances.
    /// balance 12 + 10 - 1 - 1.2 - 9.6 = 10.2; free 0 + reserved 0 + owed 0 + credit 8 + fees 0
    /// + rewardsPending 2.2 = 10.2.
    function _step11InvariantTrace(uint256 supplyBefore) internal view {
        assertEq(_royaleBalance(), 10.2e18, "treasury RF for Royale");
        _assertRoyaleLedger(0, 0, 0, 8e18);
        assertEq(treasury.rewardsPending(), 2.2e18);
        assertEq(supplyBefore - rf.totalSupply(), 2.2e18, "spend burn plus settlement burn");
        (uint256 tFree, uint256 tReserved, uint256 tOwed, uint256 tCredit, uint256 tFees) =
            treasury.totals(address(rf));
        assertEq(tFree, BREEDS_STAKE);
        assertEq(tReserved, 0);
        assertEq(tOwed, 0);
        assertEq(tCredit, 8e18);
        assertEq(tFees, 0);
        assertEq(treasury.backed(address(rf)), rf.balanceOf(address(treasury)), "I2");
        assertSolvent(address(rf));
        (uint256 bFree, uint256 bReserved, uint256 bOwed, uint256 bCredit) = ledger(breedsId);
        assertEq(bFree + bReserved + bOwed + bCredit, BREEDS_STAKE, "Breeds untouched");
    }

    /// @dev Steps 7 and 8: credit returns to the canonical wallet; rewards reach the manager.
    function _step7And8WithdrawAndForward() internal {
        vm.expectEmit(address(treasury));
        emit Treasury.CreditWithdrawn(royaleId, FRIEND, walletOf(FRIEND), 8e18);
        vm.prank(alice);
        round.withdrawCredit(royaleId, FRIEND, 8e18);
        assertEq(rf.balanceOf(walletOf(FRIEND)), 3e18 + 8e18);
        assertEq(rf.balanceOf(alice), 0, "never to the caller");
        assertEq(treasury.creditOf(royaleId, FRIEND), 0);
        _assertRoyaleLedger(0, 0, 0, 0);
        assertEq(_royaleBalance(), 2.2e18);

        vm.expectEmit(address(treasury));
        emit Treasury.RewardsForwarded(address(manager), 2.2e18);
        vm.prank(stranger);
        treasury.forwardRewards();
        assertEq(manager.funded(address(rf)), 2.2e18);
        assertEq(treasury.rewardsPending(), 0);
        assertEq(_royaleBalance(), 0);
        assertEq(treasury.backed(address(rf)), rf.balanceOf(address(treasury)), "I2");
        assertSolvent(address(rf));
    }

    function testForwardRewardsWaitsWhileManagerRetired() public {
        uint256 roundId = _settledTwelveEntryRound();
        assertEq(treasury.rewardsPending(), 1.2e18);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Settled));

        manager.setRetired(true);
        vm.expectRevert(Treasury.ManagerUnavailable.selector);
        treasury.forwardRewards();
        assertEq(treasury.rewardsPending(), 1.2e18, "pending balance waits");
        assertEq(manager.funded(address(rf)), 0);
        assertSolvent(address(rf));

        manager.setRetired(false);
        treasury.forwardRewards();
        assertEq(manager.funded(address(rf)), 1.2e18);
        assertEq(treasury.rewardsPending(), 0);
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.forwardRewards();
    }

    /// @dev Opens, fills with twelve entrants, closes, fulfils and settles one round.
    function _settledTwelveEntryRound() internal returns (uint256 roundId) {
        roundId = _open();
        _enterRange(roundId, 0, 12);
        uint256 requestId = _close(roundId);
        fulfill(requestId, WORD);
        (uint256[] memory ids, uint256[] memory amounts) = _twelveEntryPayouts();
        vm.prank(settler);
        round.settleRound(roundId, SECRET, ids, amounts);
    }

    // ------------------------------------------------------------------ SPEC 7.4 step 9

    function testCloseWithThreeEntriesRefundsWhole() public {
        uint256 roundId = _open();
        _enterRange(roundId, 0, 3);
        _assertRoyaleLedger(0, 3e18, 0, 0);
        uint256 supplyBefore = rf.totalSupply();
        uint256 requestsBefore = coordinator.requestCount();

        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(address(treasury));
            emit Treasury.Resolved(royaleId, ENTRY, 0, 0, walletOf(friends[i]), ENTRY);
        }
        vm.expectEmit(address(round));
        emit RoundModule.RoundRefunded(roundId, 3, false);
        uint256 requestId = _close(roundId);

        assertEq(requestId, 0, "no word requested for a short round");
        assertEq(coordinator.requestCount(), requestsBefore);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Refunded));
        for (uint256 i; i < 3; ++i) {
            assertEq(rf.balanceOf(walletOf(friends[i])), ENTRY, "entry returned to the wallet");
        }
        assertEq(rf.totalSupply(), supplyBefore, "nothing burned");
        assertEq(treasury.rewardsPending(), 0, "nothing routed");
        _assertRoyaleLedger(0, 0, 0, 0);
        assertEq(_royaleBalance(), 0);
        assertSolvent(address(rf));

        // Refunded Friends are free to enter the next round.
        uint256 next = _open();
        _enter(next, friends[0]);
        assertEq(round.roundOf(royaleId, friends[0]), next);
    }

    // ----------------------------------------------------------------- SPEC 7.4 step 10

    function testAbandonFromOpenAfterOneDay() public {
        uint256 roundId = _open();
        _enterRange(roundId, 0, 7);
        uint64 openedAt = _openedAt(roundId);

        vm.warp(openedAt + 1 days - 1);
        vm.prank(stranger);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        round.abandonRound(roundId);
        _assertRoyaleLedger(0, 7e18, 0, 0);

        vm.warp(openedAt + 1 days);
        vm.expectEmit(address(round));
        emit RoundModule.RoundRefunded(roundId, 7, true);
        vm.prank(stranger);
        round.abandonRound(roundId);

        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Refunded));
        for (uint256 i; i < 7; ++i) {
            assertEq(rf.balanceOf(walletOf(friends[i])), ENTRY);
        }
        _assertRoyaleLedger(0, 0, 0, 0);
        assertEq(treasury.rewardsPending(), 0);
        assertSolvent(address(rf));

        // Nothing is left to close, settle or abandon.
        vm.prank(settler);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        round.closeRound(roundId);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        round.abandonRound(roundId);
    }

    function testAbandonFromClosedAfterOneDayKeepsSpentCredit() public {
        giveRF(alice, 4e18);
        vm.prank(alice);
        round.depositCredit(royaleId, FRIEND, 4e18);

        uint256 roundId = _open();
        _enterRange(roundId, 0, 6);
        uint256 requestId = _close(roundId);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Closed));
        fulfill(requestId, WORD);

        // The settler sells a shield mid-round, then never reveals.
        vm.prank(settler);
        round.spend(roundId, FRIEND, friends[1], 1);
        assertEq(treasury.creditOf(royaleId, FRIEND), 3e18);
        uint256 supplyAfterSpend = rf.totalSupply();

        uint64 openedAt = _openedAt(roundId);
        vm.warp(openedAt + 1 days - 1);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        round.abandonRound(roundId);

        vm.warp(openedAt + 1 days);
        vm.expectEmit(address(round));
        emit RoundModule.RoundRefunded(roundId, 6, true);
        vm.prank(stranger);
        round.abandonRound(roundId);

        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Refunded));
        for (uint256 i; i < 6; ++i) {
            assertEq(rf.balanceOf(walletOf(friends[i])), ENTRY, "entry returned whole");
        }
        assertEq(treasury.creditOf(royaleId, FRIEND), 3e18, "spent credit stays spent");
        assertEq(treasury.rewardsPending(), 0.5e18, "spend rewards stay accrued");
        assertEq(rf.totalSupply(), supplyAfterSpend, "abandonment burns nothing");
        _assertRoyaleLedger(0, 0, 0, 3e18);
        assertEq(_royaleBalance(), 3.5e18);
        assertSolvent(address(rf));

        // The requested word is fulfilled but never read: settlement is refused.
        (bool fulfilled,) = coordinator.word(requestId);
        assertTrue(fulfilled);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = FRIEND;
        amounts[0] = round.potOf(roundId);
        vm.prank(settler);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        round.settleRound(roundId, SECRET, ids, amounts);

        // Credit is usable again once the round is no longer live.
        vm.prank(alice);
        round.withdrawCredit(royaleId, FRIEND, 3e18);
        assertEq(rf.balanceOf(walletOf(FRIEND)), ENTRY + 3e18);
        _assertRoyaleLedger(0, 0, 0, 0);
    }

    // ------------------------------------------------- one unsettled round per Friend

    function testOneUnsettledRoundPerFriend() public {
        uint256 first = _open();
        _enterRange(first, 0, 6);
        uint256 second = _open();

        // Double entry and overlapping entry are both RoundInProgress while Open...
        giveRF(alice, 2e18);
        vm.startPrank(alice);
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        round.enter(first, FRIEND);
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        round.enter(second, FRIEND);
        vm.stopPrank();

        // ...and while Closed.
        uint256 requestId = _close(first);
        vm.prank(alice);
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        round.enter(second, FRIEND);

        // A Friend not in the first round enters the second freely.
        _enter(second, friends[6]);

        fulfill(requestId, WORD);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = FRIEND;
        ids[1] = friends[1];
        amounts[0] = 3e18;
        amounts[1] = 1.8e18;
        assertEq(_sum(amounts), round.potOf(first));
        vm.prank(settler);
        round.settleRound(first, SECRET, ids, amounts);

        // Settled: the Friend may enter the next round and roundOf moves with it.
        vm.prank(alice);
        round.enter(second, FRIEND);
        assertEq(round.roundOf(royaleId, FRIEND), second);
        assertEq(round.entrants(second).length, 2);
        _assertRoyaleLedger(0, 2e18, 0, 0);
        assertSolvent(address(rf));
    }

    // -------------------------------------------------------------- PotMismatch at ±1 wei

    function testPotMismatchAtOneWei() public {
        uint256 roundId = _open();
        _enterRange(roundId, 0, 12);
        uint256 requestId = _close(roundId);
        fulfill(requestId, WORD);
        (uint256[] memory ids, uint256[] memory amounts) = _twelveEntryPayouts();
        assertEq(_sum(amounts), round.potOf(roundId));

        amounts[9] += 1;
        vm.prank(settler);
        vm.expectRevert(RoundModule.PotMismatch.selector);
        round.settleRound(roundId, SECRET, ids, amounts);

        amounts[9] -= 2;
        vm.prank(settler);
        vm.expectRevert(RoundModule.PotMismatch.selector);
        round.settleRound(roundId, SECRET, ids, amounts);
        _assertRoyaleLedger(0, 12e18, 0, 0);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Closed));

        amounts[9] += 1;
        vm.prank(settler);
        round.settleRound(roundId, SECRET, ids, amounts);
        _assertRoyaleLedger(0, 0, 0, 0);
        assertSolvent(address(rf));
    }

    // ------------------------------------------------------------ SPEC 7.6 step 4: retire

    function testRetireBlocksEntriesWhileRoundsStillFinish() public {
        giveRF(alice, 2e18);
        vm.prank(alice);
        round.depositCredit(royaleId, FRIEND, 2e18);

        // Three live rounds: one to settle, one to refund on close, one to abandon.
        uint256 toSettle = _open();
        _enterRange(toSettle, 0, 5);
        uint256 toRefund = _open();
        _enterRange(toRefund, 5, 3);
        uint256 toAbandon = _open();
        _enterRange(toAbandon, 8, 2);
        _assertRoyaleLedger(0, 10e18, 0, 2e18);

        vm.prank(owner);
        registry.retireGame(royaleId);
        assertFalse(registry.isActive(royaleId));

        // New positions are refused.
        _expectEnterFails(toSettle, friends[10], RoundModule.GameNotActive.selector);
        _expectEnterFails(toAbandon, friends[11], RoundModule.GameNotActive.selector);
        vm.prank(settler);
        vm.expectRevert(RoundModule.GameNotActive.selector);
        round.openRound(royaleId, _secretHash());
        giveRF(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(RoundModule.GameNotActive.selector);
        round.depositCredit(royaleId, FRIEND, 1e18);

        // Close still requests a word and the settler still spends and settles.
        uint256 requestId = _close(toSettle);
        assertTrue(requestId != 0);
        fulfill(requestId, WORD);
        vm.prank(settler);
        round.spend(toSettle, FRIEND, friends[1], 1);
        assertEq(treasury.creditOf(royaleId, FRIEND), 1e18);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = friends[2];
        amounts[0] = 4e18;
        vm.prank(settler);
        round.settleRound(toSettle, SECRET, ids, amounts);
        assertEq(rf.balanceOf(walletOf(friends[2])), 4e18);
        assertEq(uint8(_status(toSettle)), uint8(RoundModule.Status.Settled));

        // A short round still refunds on close.
        _close(toRefund);
        assertEq(uint8(_status(toRefund)), uint8(RoundModule.Status.Refunded));
        for (uint256 i = 5; i < 8; ++i) {
            assertEq(rf.balanceOf(walletOf(friends[i])), ENTRY);
        }

        // Abandonment still works after the clock.
        vm.warp(_openedAt(toAbandon) + 1 days);
        vm.prank(stranger);
        round.abandonRound(toAbandon);
        assertEq(uint8(_status(toAbandon)), uint8(RoundModule.Status.Refunded));
        assertEq(rf.balanceOf(walletOf(friends[8])), ENTRY);
        assertEq(rf.balanceOf(walletOf(friends[9])), ENTRY);

        // Credit withdrawal is unaffected by retirement.
        vm.prank(alice);
        round.withdrawCredit(royaleId, FRIEND, 1e18);
        assertEq(rf.balanceOf(walletOf(FRIEND)), 1e18);
        _assertRoyaleLedger(0, 0, 0, 0);
        assertEq(treasury.rewardsPending(), 0.5e18 + 0.5e18);
        assertEq(_royaleBalance(), 1e18);
        assertSolvent(address(rf));
    }

    function _expectEnterFails(uint256 roundId, uint256 friendId, bytes4 selector) internal {
        address holder = generations.ownerOf(friendId);
        giveRF(holder, ENTRY);
        vm.prank(holder);
        vm.expectRevert(selector);
        round.enter(roundId, friendId);
    }

    // ------------------------------------------------------------------- settler gating

    function testOnlySettlerDrivesRounds() public {
        uint256 roundId = _open();
        _enterRange(roundId, 0, 5);
        giveRF(alice, 2e18);
        vm.prank(alice);
        round.depositCredit(royaleId, FRIEND, 2e18);

        vm.startPrank(stranger);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.openRound(royaleId, _secretHash());
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.closeRound(roundId);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.spend(roundId, FRIEND, friends[1], 1);
        vm.stopPrank();
        assertEq(treasury.creditOf(royaleId, FRIEND), 2e18, "credit untouched by a stranger");

        uint256 requestId = _close(roundId);
        fulfill(requestId, WORD);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = FRIEND;
        amounts[0] = 4e18;
        vm.prank(stranger);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.settleRound(roundId, SECRET, ids, amounts);

        // The wrong secret and a non-entrant are refused before any money moves.
        vm.startPrank(settler);
        vm.expectRevert(RoundModule.BadSecret.selector);
        round.settleRound(roundId, keccak256("wrong"), ids, amounts);
        ids[0] = friends[11];
        vm.expectRevert(RoundModule.NotEntrant.selector);
        round.settleRound(roundId, SECRET, ids, amounts);
        vm.expectRevert(RoundModule.NotEntrant.selector);
        round.spend(roundId, friends[11], FRIEND, 1);
        vm.stopPrank();
        _assertRoyaleLedger(0, 5e18, 0, 2e18);

        // Owner rotation of the settler unblocks a round that still has its secret.
        address nextSettler = makeAddr("nextSettler");
        vm.prank(owner);
        registry.setSettler(royaleId, nextSettler);
        ids[0] = FRIEND;
        vm.prank(settler);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.settleRound(roundId, SECRET, ids, amounts);
        vm.prank(nextSettler);
        round.settleRound(roundId, SECRET, ids, amounts);
        assertEq(rf.balanceOf(walletOf(FRIEND)), 4e18);
        _assertRoyaleLedger(0, 0, 0, 2e18);
        assertSolvent(address(rf));
    }
}
