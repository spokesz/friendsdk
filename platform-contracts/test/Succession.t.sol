// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Fixture } from "./Fixture.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { IGameRegistry } from "../src/interfaces/IGameRegistry.sol";
import { GameItems } from "../src/GameItems.sol";
import { Treasury } from "../src/Treasury.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { MockDice } from "./doubles/ExternalDoubles.sol";

/// @dev docs/SPEC.md section 7.5 end to end: Rare Breeds hands its committing role to a second
/// DrawModule instance (`v2`) while the original (`v1`, the fixture's `draw`) drains. Nothing is
/// migrated because nothing lives in the module: eggs, tiers and reservations stay where they are
/// and both modules keep serving them (INV_SUCCESSION_PRESERVES_INVENTORY).
contract SuccessionTest is Fixture {
    /// @dev Every Treasury column the game and its currency hold, plus the wallet's inventory.
    struct Snapshot {
        uint256 free;
        uint256 reserved;
        uint256 owed;
        uint256 credit;
        uint256 totalFree;
        uint256 totalReserved;
        uint256 totalOwed;
        uint256 totalCredit;
        uint256 totalFees;
        uint256 rewardsPending;
        uint256 balance;
        uint256 eggs;
        uint256 tiers;
    }

    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");
    uint256 internal constant FRIEND = 1234;
    uint256 internal constant EGG_RESERVE = 6e18;

    DrawModule internal v2;

    function setUp() public override {
        super.setUp();
        mintFriend(alice, FRIEND, 3);
        giveRF(alice, 100e18);
        v2 = new DrawModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
    }

    // ----------------------------------------------------------------------- helpers

    /// @dev Step 2 of 7.5: the owner replays the exact Rare Breeds terms on another module.
    function _replayBreedsTerms(DrawModule module) internal {
        vm.startPrank(owner);
        module.defineClasses(breedsId, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        module.defineAction(breedsId, a, s, t);
        (a, s, t) = LaunchTerms.breedsPlayAction();
        module.defineAction(breedsId, a, s, t);
        vm.stopPrank();
    }

    /// @dev Steps 1 to 3 of 7.5: allowlist v2, replay the terms, hand the game over.
    function _succeed() internal {
        vm.prank(owner);
        registry.allowModule(address(v2));
        _replayBreedsTerms(v2);
        vm.prank(owner);
        registry.succeedModule(breedsId, address(v2));
    }

    function _buyEggs(uint8 quantity) internal returns (uint256 commitId) {
        vm.prank(alice);
        commitId = draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, quantity, 0, 0);
    }

    /// @dev Plays one egg on `module`; the play is pending on a fresh coordinator request.
    function _play(DrawModule module, bytes32 context)
        internal
        returns (uint256 commitId, uint256 requestId)
    {
        vm.prank(alice);
        commitId = module.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, context, 0);
        (,,,,, bool settled,, uint256 request) = module.commits(commitId);
        assertFalse(settled, "play settled without a word");
        assertTrue(request != 0, "play bound no request");
        requestId = request;
    }

    /// @dev The tier a settled play minted, reproduced from the public roll (section 3.2).
    function _tierOf(DrawModule module, uint256 commitId) internal view returns (uint16) {
        uint16 roll = module.rollFor(commitId, 0);
        if (roll < 6000) return LaunchTerms.BREEDS_COMMON;
        if (roll < 8500) return LaunchTerms.BREEDS_SPOTTED;
        if (roll < 9750) return LaunchTerms.BREEDS_MUTANT;
        return LaunchTerms.BREEDS_PRISMATIC;
    }

    function _valueOf(uint16 tier) internal pure returns (uint256) {
        return LaunchTerms.breedsClasses()[tier - 1].value;
    }

    function _tierBalance(uint16 tier) internal view returns (uint256) {
        return items(breedsId).balanceOf(walletOf(FRIEND), tier);
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        (s.free, s.reserved, s.owed, s.credit) = ledger(breedsId);
        (s.totalFree, s.totalReserved, s.totalOwed, s.totalCredit, s.totalFees) =
            treasury.totals(address(rf));
        s.rewardsPending = treasury.rewardsPending();
        s.balance = rf.balanceOf(address(treasury));
        s.eggs = items(breedsId).balanceOf(walletOf(FRIEND), LaunchTerms.BREEDS_EGG);
        for (uint16 tier = 2; tier <= 5; ++tier) {
            s.tiers += _tierBalance(tier);
        }
    }

    function _assertSame(Snapshot memory a, Snapshot memory b) internal pure {
        assertEq(a.free, b.free, "free changed");
        assertEq(a.reserved, b.reserved, "reserved changed");
        assertEq(a.owed, b.owed, "owed changed");
        assertEq(a.credit, b.credit, "credit changed");
        assertEq(a.totalFree, b.totalFree, "total free changed");
        assertEq(a.totalReserved, b.totalReserved, "total reserved changed");
        assertEq(a.totalOwed, b.totalOwed, "total owed changed");
        assertEq(a.totalCredit, b.totalCredit, "total credit changed");
        assertEq(a.totalFees, b.totalFees, "total fees changed");
        assertEq(a.rewardsPending, b.rewardsPending, "rewards changed");
        assertEq(a.balance, b.balance, "treasury balance changed");
        assertEq(a.eggs, b.eggs, "eggs changed");
        assertEq(a.tiers, b.tiers, "tiers changed");
    }

    function _binding(address module) internal view returns (IGameRegistry.Binding) {
        return registry.bindingOf(breedsId, module);
    }

    /// @dev Redeems one tier token through `module` and checks the burn and the wallet payout.
    function _redeemOn(DrawModule module, uint16 tier) internal {
        uint256 tiersBefore = _tierBalance(tier);
        uint256 walletBefore = rf.balanceOf(walletOf(FRIEND));
        vm.prank(alice);
        module.redeem(breedsId, FRIEND, tier, 1, 0);
        assertEq(_tierBalance(tier), tiersBefore - 1, "tier not burned");
        assertEq(rf.balanceOf(walletOf(FRIEND)), walletBefore + _valueOf(tier), "value unpaid");
    }

    /// @dev The coordinator attributes the request to `module` and binds it to that module's
    /// own commit id.
    function _assertRequestOwner(uint256 requestId, address module, uint256 commitId)
        internal
        view
    {
        (address requester,,,,,,) = coordinator.requests(requestId);
        assertEq(requester, module, "request attributed to another module");
        bytes32 key = keccak256(abi.encode(module, breedsId, bytes32(commitId)));
        assertEq(coordinator.boundRequest(key), requestId, "binding key mismatch");
    }

    /// @dev After a retry the request keeps its module, game and action and only its sequence
    /// and attempt move on.
    function _assertRebound(uint256 requestId, uint256 commitId, uint64 stale) internal view {
        uint64 fresh = sequenceOf(requestId);
        assertTrue(fresh != stale, "retry kept the stale sequence");
        (address module, uint256 gameId, bytes32 actionKey,, uint32 attempt,,) =
            coordinator.requests(requestId);
        assertEq(module, address(draw), "request rebound to another module");
        assertEq(gameId, breedsId);
        assertEq(actionKey, bytes32(commitId));
        assertEq(attempt, 1);
        assertEq(coordinator.requestOfSequence(stale), 0);
        assertEq(coordinator.requestOfSequence(fresh), requestId);
    }

    // ------------------------------------------------------- 7.5 steps 1-3: handover

    /// @dev INV_SUCCESSION_PRESERVES_INVENTORY: with eggs held, a tier owed and a play pending on
    /// v1, succession flips the bindings and the committing module and changes nothing else.
    function testSuccessionPreservesLedgersAndInventory() public {
        _buyEggs(5);
        (uint256 settledId, uint256 settledRequest) = _play(draw, keccak256("first"));
        fulfill(settledRequest, keccak256("word-1"));
        draw.settle(settledId);
        _play(draw, keccak256("second"));
        Snapshot memory before = _snapshot();
        assertEq(before.eggs, 3);
        assertEq(before.tiers, 1);
        assertEq(before.reserved, 4 * EGG_RESERVE);
        bytes32 recorded = registry.game(breedsId).termsHash;

        vm.prank(owner);
        registry.allowModule(address(v2));
        _replayBreedsTerms(v2);
        assertEq(v2.runningHash(breedsId), recorded, "replayed terms hash differently");
        assertEq(v2.termsHash(breedsId), 0, "v2 sealed before succession");

        vm.expectEmit(address(registry));
        emit GameRegistry.ModuleSucceeded(breedsId, address(draw), address(v2));
        vm.prank(owner);
        registry.succeedModule(breedsId, address(v2));

        _assertSame(before, _snapshot());
        assertSolvent(address(rf));
        assertEq(registry.currentModule(breedsId), address(v2));
        assertEq(uint8(_binding(address(draw))), uint8(IGameRegistry.Binding.Draining));
        assertEq(uint8(_binding(address(v2))), uint8(IGameRegistry.Binding.Active));
        assertTrue(registry.isBound(breedsId, address(draw)));
        assertTrue(registry.isBound(breedsId, address(v2)));
        assertFalse(registry.canCommit(breedsId, address(draw)));
        assertTrue(registry.canCommit(breedsId, address(v2)));
        assertTrue(registry.isActive(breedsId));
        assertEq(registry.game(breedsId).termsHash, recorded, "termsHash rewritten");
        assertEq(v2.termsHash(breedsId), recorded, "v2 not sealed by succession");
        assertEq(draw.termsHash(breedsId), recorded, "v1 terms changed");
        // The other games are untouched.
        assertEq(registry.currentModule(parkId), address(draw));
        assertEq(registry.currentModule(royaleId), address(round));
        assertFalse(registry.isBound(parkId, address(v2)));
    }

    /// @dev Step 2: an allowlisted module with replayed terms still cannot act until bound.
    function testUnboundV2CannotActBeforeSuccession() public {
        _buyEggs(2);
        vm.prank(owner);
        registry.allowModule(address(v2));
        _replayBreedsTerms(v2);
        assertFalse(registry.isBound(breedsId, address(v2)));

        vm.prank(alice);
        vm.expectRevert(DrawModule.NotCurrentModule.selector);
        v2.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        vm.prank(alice);
        vm.expectRevert(GameItems.NotBoundModule.selector);
        v2.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_COMMON, 1, 0);
        vm.prank(address(v2));
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.reserve(breedsId, 1);
        vm.prank(address(v2));
        vm.expectRevert(Treasury.NotCommittingModule.selector);
        treasury.collect(breedsId, alice, ITreasury.Legs(1, 0, 0, 0, 0, 0));
        GameItems collection = items(breedsId);
        address wallet = walletOf(FRIEND);
        vm.prank(address(v2));
        vm.expectRevert(GameItems.NotBoundModule.selector);
        collection.burn(wallet, LaunchTerms.BREEDS_EGG, 1);
        vm.prank(address(v2));
        vm.expectRevert(RandomnessCoordinator.NotBoundModule.selector);
        coordinator.request(breedsId, bytes32(uint256(1)));
    }

    // --------------------------------------------- 7.5 step 4: v1 drains its own commits

    /// @dev A play committed on v1 before succession settles on v1 afterwards: the Treasury and
    /// the collection accept the Draining module exactly as they did the Active one.
    function testPendingV1CommitSettlesAfterSuccession() public {
        _buyEggs(5);
        (uint256 commitId, uint256 requestId) = _play(draw, keccak256("parents"));
        (uint256 freeBefore, uint256 reservedBefore,,) = ledger(breedsId);
        assertEq(reservedBefore, 5 * EGG_RESERVE);
        _succeed();

        fulfill(requestId, keccak256("word"));
        vm.prank(stranger);
        draw.settle(commitId);

        (,,,,, bool settled,,) = draw.commits(commitId);
        assertTrue(settled);
        uint16 tier = _tierOf(draw, commitId);
        assertEq(_tierBalance(tier), 1, "v1 did not mint the tier after succession");
        (uint256 free, uint256 reserved, uint256 owed,) = ledger(breedsId);
        assertEq(reserved, 4 * EGG_RESERVE);
        assertEq(owed, _valueOf(tier));
        assertEq(free, freeBefore + EGG_RESERVE - _valueOf(tier));
        assertEq(free + reserved + owed, 10_005e18);
        assertSolvent(address(rf));
        // The commit lives on v1 only; v2 knows nothing about it.
        (uint256 v2Game,,,,,,,) = v2.commits(commitId);
        assertEq(v2Game, 0);
        vm.expectRevert(DrawModule.UnknownCommit.selector);
        v2.settle(commitId);
        vm.expectRevert(DrawModule.AlreadySettled.selector);
        draw.settle(commitId);
    }

    /// @dev Step 4, liveness: a v1 request Dice never reveals is still retried by anyone after
    /// succession, because `retry` is keyed by request id, and v1 then settles from the new word.
    function testCoordinatorRetriesStuckV1RequestAfterSuccession() public {
        _buyEggs(1);
        (uint256 commitId, uint256 requestId) = _play(draw, keccak256("stuck"));
        uint64 stale = sequenceOf(requestId);
        _succeed();
        Snapshot memory before = _snapshot();
        uint256 budgetBefore = coordinator.budget(breedsId);
        uint256 coordinatorBalance = address(coordinator).balance;

        dice.setRefundDelayBlocks(2);
        vm.roll(block.number + 1);
        vm.expectRevert(MockDice.RefundNotAvailable.selector);
        coordinator.retry(requestId);
        vm.roll(block.number + 1);
        vm.prank(stranger);
        coordinator.retry(requestId);

        _assertRebound(requestId, commitId, stale);
        // INV_RETRY_LEDGER_NEUTRAL: the stable fee came back, nothing else moved.
        assertEq(coordinator.budget(breedsId), budgetBefore);
        assertEq(address(coordinator).balance, coordinatorBalance);
        _assertSame(before, _snapshot());

        // The stale sequence is gone at Dice; the fresh one delivers and v1 settles.
        vm.expectRevert(MockDice.NoSuchRequest.selector);
        dice.reveal(stale, keccak256("late"));
        fulfill(requestId, keccak256("fresh word"));
        draw.settle(commitId);
        (,,,,, bool settled,,) = draw.commits(commitId);
        assertTrue(settled);
        (, uint256 reserved, uint256 owed,) = ledger(breedsId);
        assertEq(reserved, 0);
        assertEq(owed, _valueOf(_tierOf(draw, commitId)));
        assertSolvent(address(rf));
    }

    // ------------------------------------------- 7.5 steps 5-6: v2 serves v1's inventory

    /// @dev Step 5: the predecessor can no longer open positions of any kind.
    function testV1CommitRevertsNotCurrentModule() public {
        _buyEggs(2);
        _succeed();
        vm.prank(alice);
        vm.expectRevert(DrawModule.NotCurrentModule.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        vm.prank(alice);
        vm.expectRevert(DrawModule.NotCurrentModule.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, keccak256("ctx"), 0);
        // Even the Treasury refuses v1 a new collect, independent of the module's own guard.
        vm.prank(address(draw));
        vm.expectRevert(Treasury.NotCommittingModule.selector);
        treasury.collect(breedsId, alice, ITreasury.Legs(1e18, 0, 0, 0, 0, 0));
        // Penalty Kings still commits on v1: succession is per game.
        giveUSDG(alice, 2e6);
        vm.prank(alice);
        draw.commit(parkId, LaunchTerms.PARK_PACK, FRIEND, 1, 0, 0);
        assertEq(items(breedsId).balanceOf(walletOf(FRIEND), LaunchTerms.BREEDS_EGG), 2);
    }

    /// @dev Steps 5 and 6: v2 burns eggs v1 minted (their reserve was never in the module),
    /// settles against the same tables, and both modules redeem tiers the other minted.
    function testV2PlaysV1EggsAndRedeemsV1Tiers() public {
        _buyEggs(5);
        (uint256 v1Commit, uint256 v1Request) = _play(draw, keccak256("v1 play"));
        fulfill(v1Request, keccak256("word-v1"));
        draw.settle(v1Commit);
        uint16 v1Tier = _tierOf(draw, v1Commit);
        assertEq(_tierBalance(v1Tier), 1);
        _succeed();
        (uint256 freeBefore, uint256 reservedBefore,,) = ledger(breedsId);
        assertEq(reservedBefore, 4 * EGG_RESERVE);

        // v2 plays a v1-minted egg: burn, release and reserve are all accepted from v2.
        (uint256 v2Commit, uint256 v2Request) = _play(v2, keccak256("v2 play"));
        assertEq(items(breedsId).balanceOf(walletOf(FRIEND), LaunchTerms.BREEDS_EGG), 3);
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, freeBefore, "play changed free");
        assertEq(reserved, reservedBefore, "egg reserve swapped for play reserve");
        _assertRequestOwner(v2Request, address(v2), v2Commit);
        assertTrue(v2Request != v1Request);
        // v1 and v2 number commits independently; the coordinator binds them per module.
        assertEq(v2Commit, 1);

        fulfill(v2Request, keccak256("word-v2"));
        vm.prank(stranger);
        v2.settle(v2Commit);
        uint16 v2Tier = _tierOf(v2, v2Commit);
        uint256 owed;
        (free, reserved, owed,) = ledger(breedsId);
        assertEq(reserved, 3 * EGG_RESERVE);
        assertEq(owed, _valueOf(v1Tier) + _valueOf(v2Tier));
        assertEq(free, freeBefore + EGG_RESERVE - _valueOf(v2Tier));
        assertEq(free + reserved + owed, 10_005e18);
        assertSolvent(address(rf));

        // v2 redeems the tier v1 minted, then the draining v1 redeems the tier v2 minted.
        _redeemOn(v2, v1Tier);
        (,, owed,) = ledger(breedsId);
        assertEq(owed, _valueOf(v2Tier));
        _redeemOn(draw, v2Tier);
        (,, owed,) = ledger(breedsId);
        assertEq(owed, 0);
        assertSolvent(address(rf));

        // New eggs are bought on v2 and carry the same 6 RF reserve.
        vm.prank(alice);
        v2.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 2, 0, 0);
        assertEq(items(breedsId).balanceOf(walletOf(FRIEND), LaunchTerms.BREEDS_EGG), 5);
        (, reserved,,) = ledger(breedsId);
        assertEq(reserved, 5 * EGG_RESERVE);
    }

    // ------------------------------------------------------------------- refusals

    /// @dev Section 3.5: the successor's hash must match byte for byte; one bps moved between
    /// two rows of the play table is refused and leaves v2 unbound and unsealed.
    function testTermsMismatchWhenV2TermsDifferByOneBps() public {
        _buyEggs(1);
        vm.prank(owner);
        registry.allowModule(address(v2));
        vm.startPrank(owner);
        v2.defineClasses(breedsId, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        v2.defineAction(breedsId, a, s, t);
        (a, s, t) = LaunchTerms.breedsPlayAction();
        t[0][0].weightBps += 1;
        t[0][1].weightBps -= 1;
        v2.defineAction(breedsId, a, s, t);
        vm.stopPrank();
        assertTrue(v2.runningHash(breedsId) != registry.game(breedsId).termsHash);

        Snapshot memory before = _snapshot();
        vm.prank(owner);
        vm.expectRevert(GameRegistry.TermsMismatch.selector);
        registry.succeedModule(breedsId, address(v2));

        assertEq(registry.currentModule(breedsId), address(draw));
        assertEq(uint8(_binding(address(draw))), uint8(IGameRegistry.Binding.Active));
        assertEq(uint8(_binding(address(v2))), uint8(IGameRegistry.Binding.None));
        assertFalse(v2.isSealed(breedsId), "a failed succession sealed v2");
        _assertSame(before, _snapshot());
        // v1 keeps committing.
        _buyEggs(1);
        assertEq(items(breedsId).balanceOf(walletOf(FRIEND), LaunchTerms.BREEDS_EGG), 2);
    }

    /// @dev A module whose terms were never replayed has no hash to match either.
    function testTermsMismatchWhenV2HasNoTerms() public {
        vm.startPrank(owner);
        registry.allowModule(address(v2));
        vm.expectRevert(DrawModule.NoTerms.selector);
        registry.succeedModule(breedsId, address(v2));
        vm.stopPrank();
        assertEq(registry.currentModule(breedsId), address(draw));
    }

    /// @dev A Round module can never take over a Draw game, whether it is the fixture's
    /// RoundModule or a fresh instance, and an unlisted module is refused the same way.
    function testLineageMismatchForRoundSuccessor() public {
        RoundModule roundV2 = new RoundModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        vm.startPrank(owner);
        registry.allowModule(address(roundV2));
        vm.expectRevert(GameRegistry.LineageMismatch.selector);
        registry.succeedModule(breedsId, address(round));
        vm.expectRevert(GameRegistry.LineageMismatch.selector);
        registry.succeedModule(breedsId, address(roundV2));
        // Not allowlisted yet: lineage zero never equals the game's lineage.
        vm.expectRevert(GameRegistry.LineageMismatch.selector);
        registry.succeedModule(breedsId, address(v2));
        // And the Draw v2 cannot take over the Round game.
        registry.allowModule(address(v2));
        vm.expectRevert(GameRegistry.LineageMismatch.selector);
        registry.succeedModule(royaleId, address(v2));
        vm.stopPrank();
        assertEq(registry.currentModule(breedsId), address(draw));
        assertEq(registry.currentModule(royaleId), address(round));
        assertFalse(registry.isBound(breedsId, address(round)));
        assertFalse(registry.isBound(breedsId, address(roundV2)));
    }

    /// @dev Both bound modules are refused as successors: the Active one and the Draining one.
    function testAlreadyBoundOnReSuccession() public {
        _succeed();
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.AlreadyBound.selector);
        registry.succeedModule(breedsId, address(v2));
        vm.expectRevert(GameRegistry.AlreadyBound.selector);
        registry.succeedModule(breedsId, address(draw));
        vm.stopPrank();
        assertEq(registry.currentModule(breedsId), address(v2));
        assertEq(uint8(_binding(address(draw))), uint8(IGameRegistry.Binding.Draining));
        assertEq(uint8(_binding(address(v2))), uint8(IGameRegistry.Binding.Active));

        // A third instance with the same terms succeeds v2; v1 and v2 both drain.
        DrawModule v3 = new DrawModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        vm.prank(owner);
        registry.allowModule(address(v3));
        _replayBreedsTerms(v3);
        vm.prank(owner);
        registry.succeedModule(breedsId, address(v3));
        assertEq(registry.currentModule(breedsId), address(v3));
        assertEq(uint8(_binding(address(draw))), uint8(IGameRegistry.Binding.Draining));
        assertEq(uint8(_binding(address(v2))), uint8(IGameRegistry.Binding.Draining));
        assertEq(uint8(_binding(address(v3))), uint8(IGameRegistry.Binding.Active));
    }

    // --------------------------------------------------------- succession when Retired

    /// @dev A Retired game may still be succeeded: the successor settles nothing new by
    /// purchase, but egg plays, pending v1 settlements and redemptions all continue on it.
    function testSuccessionOfRetiredGame() public {
        _buyEggs(3);
        (uint256 v1Commit, uint256 v1Request) = _play(draw, keccak256("before retire"));
        vm.prank(owner);
        registry.retireGame(breedsId);
        Snapshot memory before = _snapshot();

        _succeed();
        _assertSame(before, _snapshot());
        assertFalse(registry.isActive(breedsId));
        assertEq(registry.currentModule(breedsId), address(v2));
        assertFalse(registry.canCommit(breedsId, address(v2)), "retired game commits");
        assertEq(uint8(_binding(address(draw))), uint8(IGameRegistry.Binding.Draining));

        // Purchases stay closed on the successor; v1 is refused before that for not being current.
        vm.prank(alice);
        vm.expectRevert(DrawModule.GameNotActive.selector);
        v2.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        vm.prank(alice);
        vm.expectRevert(DrawModule.NotCurrentModule.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);

        // The v1 play settles on v1.
        fulfill(v1Request, keccak256("word-v1"));
        draw.settle(v1Commit);
        uint16 v1Tier = _tierOf(draw, v1Commit);
        assertEq(_tierBalance(v1Tier), 1);

        // An egg already held plays on v2 even though the game is retired.
        (uint256 v2Commit, uint256 v2Request) = _play(v2, keccak256("after retire"));
        fulfill(v2Request, keccak256("word-v2"));
        v2.settle(v2Commit);
        uint16 v2Tier = _tierOf(v2, v2Commit);
        (uint256 free, uint256 reserved, uint256 owed,) = ledger(breedsId);
        assertEq(reserved, EGG_RESERVE, "one egg still held");
        assertEq(owed, _valueOf(v1Tier) + _valueOf(v2Tier));
        assertEq(free + reserved + owed, 10_003e18);

        // Redemption works on both modules forever.
        vm.prank(alice);
        v2.redeem(breedsId, FRIEND, v1Tier, 1, 0);
        vm.prank(alice);
        draw.redeem(breedsId, FRIEND, v2Tier, 1, 0);
        (,, owed,) = ledger(breedsId);
        assertEq(owed, 0);
        assertSolvent(address(rf));
    }
}
