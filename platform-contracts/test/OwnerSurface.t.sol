// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Fixture } from "./Fixture.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { GameItems } from "../src/GameItems.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { Treasury } from "../src/Treasury.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { FriendAccess } from "../src/libraries/FriendAccess.sol";

/// @dev docs/SPEC.md section 10.1 against the integrated hub: every owner power rejects a
/// non-owner; the owner cannot alter sealed terms, move reserved/owed/credit/fees/rewardsPending,
/// mint, burn or settle, and cannot block settlement, redemption, refund, retry or credit
/// withdrawal; renouncing reverts and ownership moves in two steps across every owner surface.
contract OwnerSurfaceTest is Fixture {
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal nextOwner = makeAddr("nextOwner");
    address internal newSettler = makeAddr("newSettler");
    uint256 internal constant FRIEND = 1234;
    // Royale entrants, gen 2, owned by alice.
    uint256 internal constant ENTRANT_BASE = 2000;
    bytes32 internal constant SECRET = keccak256("secret");

    function setUp() public override {
        super.setUp();
        mintFriend(alice, FRIEND, 3);
        for (uint256 i = 1; i <= 7; ++i) {
            mintFriend(alice, ENTRANT_BASE + i, 2);
        }
    }

    // --------------------------------------------------------------------------- helpers

    /// @dev `caller` sends `data` to `target` and the call must fail with exactly `expected`.
    function _rejects(address caller, address target, bytes memory data, bytes memory expected)
        internal
    {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, "call succeeded");
        assertEq(ret, expected, "call failed for another reason");
    }

    function _unauthorized(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account);
    }

    function _selector(bytes4 s) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(s);
    }

    /// @dev Breeds: alice buys `eggs` eggs and plays one; returns the pending play commit.
    function _buyAndPlay(uint8 eggs) internal returns (uint256 playId, uint256 requestId) {
        giveRF(alice, uint256(eggs) * 1e18);
        vm.startPrank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, eggs, 0, 0);
        playId = draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, keccak256("ctx"), 0);
        vm.stopPrank();
        (,,,,,,, requestId) = draw.commits(playId);
    }

    /// @dev Settles a pending Breeds play and returns the tier class minted.
    function _settlePlay(uint256 playId, uint256 requestId, bytes32 word)
        internal
        returns (uint16 tier)
    {
        fulfill(requestId, word);
        draw.settle(playId);
        for (uint16 id = 2; id <= 5; ++id) {
            if (items(breedsId).balanceOf(walletOf(FRIEND), id) != 0) tier = id;
        }
        assertTrue(tier != 0, "no tier minted");
    }

    /// @dev Opens a Royale round and enters `n` of alice's entrants.
    function _openAndEnter(uint256 n, address settler_) internal returns (uint256 roundId) {
        vm.prank(settler_);
        roundId = round.openRound(royaleId, keccak256(abi.encode(SECRET)));
        for (uint256 i = 1; i <= n; ++i) {
            giveRF(alice, 1e18);
            vm.prank(alice);
            round.enter(roundId, ENTRANT_BASE + i);
        }
    }

    /// @dev A DrawModule v2 with Rare Breeds' exact terms replayed, bound by succession.
    function _succeedBreeds(address owner_) internal returns (DrawModule v2) {
        v2 = new DrawModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        vm.startPrank(owner_);
        registry.allowModule(address(v2));
        v2.defineClasses(breedsId, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        v2.defineAction(breedsId, a, s, t);
        (a, s, t) = LaunchTerms.breedsPlayAction();
        v2.defineAction(breedsId, a, s, t);
        registry.succeedModule(breedsId, address(v2));
        vm.stopPrank();
        assertEq(registry.currentModule(breedsId), address(v2));
    }

    function _assertConserved(address currency) internal view {
        assertSolvent(currency);
        assertEq(
            IERC20(currency).balanceOf(address(treasury)),
            treasury.backed(currency),
            "balance drifted from the ledgers"
        );
    }

    // ------------------------------------------------------- non-owner rejection, 10.1

    function testRegistryOwnerFunctionsRejectStranger() public {
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(registry.allowModule, (address(this)));
        calls[1] = abi.encodeCall(
            registry.createGame,
            (address(draw), address(rf), funder, address(0), address(0), address(0), 1, "u")
        );
        calls[2] = abi.encodeCall(registry.activateGame, (breedsId));
        calls[3] = abi.encodeCall(registry.retireGame, (breedsId));
        calls[4] = abi.encodeCall(registry.succeedModule, (breedsId, address(round)));
        calls[5] = abi.encodeCall(registry.setSettler, (royaleId, stranger));
        calls[6] = abi.encodeCall(registry.setItemsURI, (breedsId, "v"));
        calls[7] = abi.encodeCall(registry.setCustodyExecutor, (stranger));
        calls[8] = abi.encodeCall(registry.transferOwnership, (stranger));
        calls[9] = abi.encodeCall(registry.renounceOwnership, ());
        for (uint256 i; i < calls.length; ++i) {
            _rejects(stranger, address(registry), calls[i], _unauthorized(stranger));
            // The funder, settler and executor are roles, not owners.
            _rejects(funder, address(registry), calls[i], _unauthorized(funder));
            _rejects(settler, address(registry), calls[i], _unauthorized(settler));
            _rejects(executor, address(registry), calls[i], _unauthorized(executor));
        }
        assertEq(registry.owner(), owner);
        assertEq(registry.custodyExecutor(), executor);
        assertTrue(registry.isActive(breedsId));
    }

    function testTreasuryWithdrawFreeRejectsEveryoneButTheRegistryOwner() public {
        bytes memory data = abi.encodeCall(treasury.withdrawFree, (breedsId, 1e18));
        bytes memory expected = _selector(Treasury.NotRegistryOwner.selector);
        _rejects(stranger, address(treasury), data, expected);
        _rejects(funder, address(treasury), data, expected);
        _rejects(address(draw), address(treasury), data, expected);
        _rejects(address(registry), address(treasury), data, expected);
        (uint256 free,,,) = ledger(breedsId);
        assertEq(free, 10_000e18);
    }

    function testCoordinatorOwnerFunctionsRejectStranger() public {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(coordinator.setMaxFee, (1));
        calls[1] = abi.encodeCall(coordinator.setBudget, (breedsId, 0));
        calls[2] = abi.encodeCall(coordinator.withdraw, (stranger, 1 ether));
        bytes memory expected = _selector(RandomnessCoordinator.NotRegistryOwner.selector);
        for (uint256 i; i < calls.length; ++i) {
            _rejects(stranger, address(coordinator), calls[i], expected);
            _rejects(address(draw), address(coordinator), calls[i], expected);
        }
        assertEq(coordinator.maxFee(), DICE_FEE);
        assertEq(coordinator.budget(breedsId), 1 ether);
        assertEq(address(coordinator).balance, 10 ether);
    }

    function testModuleTermsFunctionsRejectStranger() public {
        vm.prank(owner);
        uint256 draft = registry.createGame(
            address(draw), address(rf), funder, address(0), address(0), address(0), 5, "d/{id}"
        );
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        _rejects(
            stranger,
            address(draw),
            abi.encodeCall(draw.defineClasses, (draft, LaunchTerms.breedsClasses())),
            _selector(DrawModule.NotRegistryOwner.selector)
        );
        _rejects(
            stranger,
            address(draw),
            abi.encodeCall(draw.defineAction, (draft, a, s, t)),
            _selector(DrawModule.NotRegistryOwner.selector)
        );
        vm.prank(owner);
        uint256 roundDraft = registry.createGame(
            address(round), address(rf), funder, address(0), address(0), settler, 0, ""
        );
        _rejects(
            stranger,
            address(round),
            abi.encodeCall(
                round.defineTerms, (roundDraft, royaleTerms(), LaunchTerms.royaleKindPrices())
            ),
            _selector(RoundModule.NotRegistryOwner.selector)
        );
        assertEq(draw.actionCount(draft), 0);
        (uint128 entryPrice,,,,,,,) = round.terms(roundDraft);
        assertEq(entryPrice, 0);
    }

    // --------------------------------------------------------- sealed terms are frozen

    function testOwnerCannotAlterSealedTerms() public {
        bytes32 breedsHash = draw.termsHash(breedsId);
        bytes32 parkHash = draw.termsHash(parkId);
        bytes32 royaleHash = round.termsHash(royaleId);
        assertTrue(breedsHash != 0 && parkHash != 0 && royaleHash != 0);
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsPlayAction();
        // A tempting edit: Prismatic at 100%.
        t[0] = new DrawTables.Row[](1);
        t[0][0] = DrawTables.Row(10_000, LaunchTerms.BREEDS_PRISMATIC, 0);
        vm.startPrank(owner);
        vm.expectRevert(DrawModule.Sealed.selector);
        draw.defineClasses(breedsId, LaunchTerms.breedsClasses());
        vm.expectRevert(DrawModule.Sealed.selector);
        draw.defineAction(breedsId, a, s, t);
        vm.expectRevert(DrawModule.Sealed.selector);
        draw.defineAction(parkId, a, s, t);
        vm.expectRevert(RoundModule.Sealed.selector);
        round.defineTerms(royaleId, royaleTerms(), LaunchTerms.royaleKindPrices());
        // Nor can the owner seal, re-seal or re-activate through any other door.
        vm.expectRevert(DrawModule.OnlyRegistry.selector);
        draw.seal(breedsId);
        vm.expectRevert(RoundModule.OnlyRegistry.selector);
        round.seal(royaleId);
        vm.expectRevert(GameRegistry.WrongStatus.selector);
        registry.activateGame(breedsId);
        vm.stopPrank();
        assertEq(draw.termsHash(breedsId), breedsHash);
        assertEq(draw.termsHash(parkId), parkHash);
        assertEq(round.termsHash(royaleId), royaleHash);
        assertEq(registry.game(breedsId).termsHash, breedsHash);
        assertEq(draw.actionCount(breedsId), 2);
        assertEq(draw.rows(breedsId, LaunchTerms.BREEDS_PLAY, 0).length, 4);
    }

    /// @dev Succession cannot smuggle different terms in: the successor must hash identically.
    function testOwnerCannotSucceedWithDifferentTerms() public {
        DrawModule v2 = new DrawModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        DrawTables.Class[] memory classes = LaunchTerms.breedsClasses();
        classes[4] = DrawTables.Class(60e18, 0);
        vm.startPrank(owner);
        registry.allowModule(address(v2));
        v2.defineClasses(breedsId, classes);
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        v2.defineAction(breedsId, a, s, t);
        vm.expectRevert(GameRegistry.TermsMismatch.selector);
        registry.succeedModule(breedsId, address(v2));
        vm.stopPrank();
        assertEq(registry.currentModule(breedsId), address(draw));
        assertFalse(registry.isBound(breedsId, address(v2)));
    }

    // ----------------------------------------- the owner has no ledger or item primitive

    function testOwnerCannotCallLedgerPrimitives() public {
        ITreasury.Legs memory legs = ITreasury.Legs(1e18, 0, 0, 0, 0, 0);
        vm.startPrank(owner);
        vm.expectRevert(Treasury.NotCommittingModule.selector);
        treasury.collect(breedsId, alice, legs);
        vm.expectRevert(Treasury.NotCommittingModule.selector);
        treasury.creditDeposit(royaleId, FRIEND, alice, 1e18);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.reserve(breedsId, 1e18);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.release(breedsId, 1e18);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.resolve(breedsId, 1e18, 0, 0, owner, 1e18);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.routeReserved(breedsId, 1e18, 0);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.payOwed(breedsId, owner, 1e18);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.creditWithdraw(royaleId, FRIEND, owner, 1e18);
        vm.expectRevert(Treasury.NotBoundModule.selector);
        treasury.creditSpend(royaleId, FRIEND, 1e18, 1e18, 0);
        // Fees and rewards have fixed destinations; the owner is neither.
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.payFees(address(rf), owner);
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.forwardRewards();
        vm.expectRevert(RandomnessCoordinator.NotBoundModule.selector);
        coordinator.request(breedsId, bytes32(uint256(1)));
        vm.expectRevert(RandomnessCoordinator.UnauthorizedRandomness.selector);
        coordinator._entropyCallback(1, provider, bytes32(0));
        vm.expectRevert(GameRegistry.NotBoundModule.selector);
        registry.consumeCustodyAction(keccak256("order"), breedsId);
        vm.stopPrank();
        (uint256 free, uint256 reserved, uint256 owed, uint256 credit) = ledger(breedsId);
        assertEq(free, 10_000e18);
        assertEq(reserved + owed + credit, 0);
    }

    function testOwnerCannotMintBurnOrMoveItems() public {
        giveRF(alice, 1e18);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        GameItems eggs = items(breedsId);
        address wallet = walletOf(FRIEND);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = LaunchTerms.BREEDS_EGG;
        amounts[0] = 1;
        vm.startPrank(owner);
        vm.expectRevert(GameItems.NotBoundModule.selector);
        eggs.mintBatch(owner, ids, amounts);
        vm.expectRevert(GameItems.NotBoundModule.selector);
        eggs.burn(wallet, LaunchTerms.BREEDS_EGG, 1);
        vm.expectRevert(GameItems.OnlyRegistry.selector);
        eggs.setURI("owner/{id}");
        vm.expectRevert();
        eggs.safeTransferFrom(wallet, owner, LaunchTerms.BREEDS_EGG, 1, "");
        // Metadata is the one items power, and it never touches balances.
        registry.setItemsURI(breedsId, "v2/{id}");
        vm.stopPrank();
        assertEq(eggs.uri(1), "v2/{id}");
        assertEq(eggs.balanceOf(wallet, LaunchTerms.BREEDS_EGG), 1);
        assertEq(eggs.balanceOf(owner, LaunchTerms.BREEDS_EGG), 0);
    }

    function testOwnerCannotSettleRedeemOrPlayForOthers() public {
        (uint256 playId,) = _buyAndPlay(2);
        uint256 roundId = _openAndEnter(5, settler);
        vm.prank(settler);
        round.closeRound(roundId);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = ENTRANT_BASE + 1;
        amounts[0] = round.potOf(roundId);
        giveRF(owner, 10e18);
        vm.startPrank(owner);
        // No word, no settlement: the owner has no way to supply or replace one.
        vm.expectRevert(DrawModule.RandomnessPending.selector);
        draw.settle(playId);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_COMMON, 1, 0);
        vm.expectRevert(DrawModule.OnlyCustodyExecutor.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, keccak256("order"));
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.settleRound(roundId, SECRET, ids, amounts);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.spend(roundId, ENTRANT_BASE + 1, ENTRANT_BASE + 2, 1);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.closeRound(roundId);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        round.abandonRound(roundId);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        round.withdrawCredit(royaleId, FRIEND, 1);
        vm.stopPrank();
        (,,,,, bool settled,,) = draw.commits(playId);
        assertFalse(settled);
        (,,, RoundModule.Status status,) = round.rounds(roundId);
        assertEq(uint8(status), uint8(RoundModule.Status.Closed));
    }

    // ------------------------------------- withdrawFree reaches free only, funder only

    /// @dev Builds reserved, owed, credit, fees and rewardsPending across the three games, then
    /// the owner drains `free` to zero everywhere and every other column is untouched.
    function testWithdrawFreeIsBoundedByFreeAndNeverTouchesObligations() public {
        (uint256 playId, uint256 requestId) = _buyAndPlay(5);
        _settlePlay(playId, requestId, keccak256("word"));
        giveRF(alice, 10e18);
        vm.prank(alice);
        round.depositCredit(royaleId, FRIEND, 10e18);
        giveUSDG(alice, 4e6);
        vm.prank(alice);
        draw.commit(parkId, LaunchTerms.PARK_PACK, FRIEND, 2, 0, 0);
        uint256 roundId = _openAndEnter(5, settler);
        vm.prank(settler);
        round.closeRound(roundId);
        (,,,, uint256 roundRequest) = round.rounds(roundId);
        fulfill(roundRequest, keccak256("royale"));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = ENTRANT_BASE + 1;
        amounts[0] = round.potOf(roundId);
        vm.prank(settler);
        round.settleRound(roundId, SECRET, ids, amounts);

        (, uint256 reservedB, uint256 owedB,) = ledger(breedsId);
        (,,, uint256 creditR) = ledger(royaleId);
        uint256 devFees = treasury.feesOwed(address(usdg), PARK_DEVELOPER);
        uint256 opFees = treasury.feesOwed(address(usdg), PARK_OPERATOR);
        uint256 rewards = treasury.rewardsPending();
        assertTrue(reservedB != 0 && owedB != 0 && creditR != 0 && devFees != 0 && rewards != 0);

        uint256[3] memory games = [breedsId, parkId, royaleId];
        for (uint256 i; i < games.length; ++i) {
            (uint256 free,,,) = ledger(games[i]);
            address currency = registry.currencyOf(games[i]);
            uint256 funderBefore = IERC20(currency).balanceOf(funder);
            vm.startPrank(owner);
            vm.expectRevert(Treasury.InsufficientFree.selector);
            treasury.withdrawFree(games[i], free + 1);
            vm.expectRevert(Treasury.ZeroAmount.selector);
            treasury.withdrawFree(games[i], 0);
            if (free != 0) treasury.withdrawFree(games[i], free);
            vm.stopPrank();
            (uint256 freeAfter,,,) = ledger(games[i]);
            assertEq(freeAfter, 0, "free not drained");
            assertEq(IERC20(currency).balanceOf(funder) - funderBefore, free, "paid elsewhere");
            assertEq(IERC20(currency).balanceOf(owner), 0, "owner received stake");
        }
        (, uint256 reservedAfter, uint256 owedAfter,) = ledger(breedsId);
        (,,, uint256 creditAfter) = ledger(royaleId);
        assertEq(reservedAfter, reservedB);
        assertEq(owedAfter, owedB);
        assertEq(creditAfter, creditR);
        assertEq(treasury.feesOwed(address(usdg), PARK_DEVELOPER), devFees);
        assertEq(treasury.feesOwed(address(usdg), PARK_OPERATOR), opFees);
        assertEq(treasury.rewardsPending(), rewards);
        _assertConserved(address(rf));
        _assertConserved(address(usdg));
    }

    // ------------------------------- no owner power blocks settle, redeem, retry, refund

    /// @dev Retire, drain free, rotate the executor, succeed the module and hand over ownership:
    /// the pending play still settles, tier tokens still redeem, on both the Draining and the
    /// Active module.
    function testOwnerPowersCannotBlockDrawSettlementOrRedemption() public {
        (uint256 playId, uint256 requestId) = _buyAndPlay(5);
        vm.prank(alice);
        uint256 secondPlay =
            draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, keccak256("ctx2"), 0);
        (,,,,,,, uint256 secondRequest) = draw.commits(secondPlay);
        uint16 tier = _settlePlay(secondPlay, secondRequest, keccak256("second"));
        (uint256 free, uint256 reserved, uint256 owed,) = ledger(breedsId);

        vm.startPrank(owner);
        registry.retireGame(breedsId);
        treasury.withdrawFree(breedsId, free);
        registry.setCustodyExecutor(address(0));
        registry.setItemsURI(breedsId, "retired/{id}");
        vm.stopPrank();
        DrawModule v2 = _succeedBreeds(owner);
        vm.prank(owner);
        registry.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        registry.acceptOwnership();

        (uint256 freeAfter, uint256 reservedAfter, uint256 owedAfter,) = ledger(breedsId);
        assertEq(freeAfter, 0);
        assertEq(reservedAfter, reserved);
        assertEq(owedAfter, owed);

        // The predecessor settles its own pending play.
        fulfill(requestId, keccak256("word"));
        draw.settle(playId);
        (,,,,, bool settled,,) = draw.commits(playId);
        assertTrue(settled);
        (, reservedAfter, owedAfter,) = ledger(breedsId);
        assertEq(reservedAfter, reserved - 6e18, "play reserve not resolved");
        assertGt(owedAfter, owed, "no tier value owed");

        // Redemption through the Draining module and through the successor.
        uint256 value = LaunchTerms.breedsClasses()[tier - 1].value;
        uint256 walletBefore = rf.balanceOf(walletOf(FRIEND));
        vm.prank(alice);
        draw.redeem(breedsId, FRIEND, tier, 1, 0);
        assertEq(rf.balanceOf(walletOf(FRIEND)) - walletBefore, value);
        uint16 newTier;
        for (uint16 id = 2; id <= 5; ++id) {
            if (items(breedsId).balanceOf(walletOf(FRIEND), id) != 0) newTier = id;
        }
        assertTrue(newTier != 0);
        walletBefore = rf.balanceOf(walletOf(FRIEND));
        vm.prank(alice);
        v2.redeem(breedsId, FRIEND, newTier, 1, 0);
        assertEq(
            rf.balanceOf(walletOf(FRIEND)) - walletBefore,
            LaunchTerms.breedsClasses()[newTier - 1].value
        );
        // Eggs bought on v1 still play on v2 while retired: their reserve was never withdrawable.
        vm.prank(alice);
        uint256 v2Play = v2.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        (,,,,, settled,,) = v2.commits(v2Play);
        assertFalse(settled);
        _assertConserved(address(rf));
    }

    /// @dev A stuck request survives retire, succession and a drained bankroll; anyone retries.
    function testOwnerPowersCannotBlockRetry() public {
        (uint256 playId, uint256 requestId) = _buyAndPlay(1);
        (uint256 free,,,) = ledger(breedsId);
        vm.startPrank(owner);
        registry.retireGame(breedsId);
        treasury.withdrawFree(breedsId, free);
        vm.stopPrank();
        _succeedBreeds(owner);
        uint64 stale = sequenceOf(requestId);
        vm.roll(block.number + 6);
        vm.prank(stranger);
        coordinator.retry(requestId);
        uint64 fresh = sequenceOf(requestId);
        assertTrue(fresh != stale);
        assertEq(coordinator.budget(breedsId), 1 ether - DICE_FEE, "fee reclaimed and respent");
        fulfill(requestId, keccak256("late"));
        draw.settle(playId);
        (,,,,, bool settled,,) = draw.commits(playId);
        assertTrue(settled);
    }

    /// @dev Section 2.8: the fee cap and the game budget are the explicit bounds on every request,
    /// retries included; they are platform ETH controls, not settlement controls, and a stuck
    /// request stays retryable once the budget is restored.
    function testRetryIsBoundedByBudgetAndCapAsSpecified() public {
        (, uint256 requestId) = _buyAndPlay(1);
        vm.roll(block.number + 6);
        // The reclaimed fee is credited before the new request is charged, so only a dearer
        // quote can exhaust a zeroed budget.
        dice.setFee(DICE_FEE + 1);
        vm.startPrank(owner);
        coordinator.setMaxFee(DICE_FEE + 1);
        coordinator.setBudget(breedsId, 0);
        vm.stopPrank();
        vm.expectRevert(RandomnessCoordinator.BudgetExceeded.selector);
        coordinator.retry(requestId);
        vm.startPrank(owner);
        coordinator.setBudget(breedsId, 1 ether);
        coordinator.setMaxFee(DICE_FEE);
        vm.stopPrank();
        vm.expectRevert(RandomnessCoordinator.FeeAboveCap.selector);
        coordinator.retry(requestId);
        vm.prank(owner);
        coordinator.setMaxFee(DICE_FEE + 1);
        coordinator.retry(requestId);
        (,,,,, RandomnessCoordinator.State state,) = coordinator.requests(requestId);
        assertEq(uint8(state), uint8(RandomnessCoordinator.State.Requested));
    }

    /// @dev Retire, rotate the settler, hand over ownership: the closed round settles under the
    /// new settler, a short round refunds, an abandoned round refunds, credit withdraws, fees pay
    /// and rewards forward.
    function testOwnerPowersCannotBlockRoundSettlementRefundsOrCredit() public {
        giveRF(alice, 10e18);
        vm.prank(alice);
        round.depositCredit(royaleId, FRIEND, 10e18);
        uint256 closed = _openAndEnter(5, settler);
        vm.prank(settler);
        round.closeRound(closed);
        (,,,, uint256 roundRequest) = round.rounds(closed);
        vm.prank(settler);
        uint256 shortRound = round.openRound(royaleId, keccak256(abi.encode(SECRET)));
        giveRF(alice, 1e18);
        vm.prank(alice);
        round.enter(shortRound, ENTRANT_BASE + 6);
        // Opens and entries stop at retirement (7.6), so the round that will be abandoned exists
        // before the owner acts.
        vm.prank(settler);
        uint256 stuck = round.openRound(royaleId, keccak256(abi.encode(SECRET)));
        giveRF(alice, 1e18);
        vm.prank(alice);
        round.enter(stuck, ENTRANT_BASE + 7);
        giveUSDG(alice, 2e6);
        vm.prank(alice);
        draw.commit(parkId, LaunchTerms.PARK_PACK, FRIEND, 1, 0, 0);

        vm.startPrank(owner);
        registry.retireGame(royaleId);
        registry.retireGame(parkId);
        registry.setSettler(royaleId, newSettler);
        (uint256 parkFree,,,) = ledger(parkId);
        treasury.withdrawFree(parkId, parkFree);
        registry.transferOwnership(nextOwner);
        vm.stopPrank();
        vm.prank(nextOwner);
        registry.acceptOwnership();

        // Settlement by the new settler with the committed secret.
        fulfill(roundRequest, keccak256("royale"));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = ENTRANT_BASE + 1;
        amounts[0] = round.potOf(closed);
        vm.prank(settler);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        round.settleRound(closed, SECRET, ids, amounts);
        vm.prank(newSettler);
        round.settleRound(closed, SECRET, ids, amounts);
        assertEq(rf.balanceOf(walletOf(ENTRANT_BASE + 1)), 4e18);
        // Short round refunds whole; a never-finished round is abandonable by anyone.
        vm.prank(newSettler);
        round.closeRound(shortRound);
        assertEq(rf.balanceOf(walletOf(ENTRANT_BASE + 6)), 1e18);
        vm.prank(newSettler);
        vm.expectRevert(RoundModule.GameNotActive.selector);
        round.openRound(royaleId, keccak256(abi.encode(SECRET)));
        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        round.abandonRound(stuck);
        assertEq(rf.balanceOf(walletOf(ENTRANT_BASE + 7)), 1e18);
        // Credit returns to the wallet; fees and rewards reach their fixed destinations.
        vm.prank(alice);
        round.withdrawCredit(royaleId, FRIEND, 10e18);
        assertEq(rf.balanceOf(walletOf(FRIEND)), 10e18);
        vm.prank(stranger);
        treasury.payFees(address(usdg), PARK_DEVELOPER);
        assertGt(usdg.balanceOf(PARK_DEVELOPER), 0);
        uint256 rewards = treasury.rewardsPending();
        vm.prank(stranger);
        treasury.forwardRewards();
        assertEq(manager.funded(address(rf)), rewards);
        (, uint256 reserved,, uint256 credit) = ledger(royaleId);
        assertEq(reserved + credit, 0);
        _assertConserved(address(rf));
        _assertConserved(address(usdg));
    }

    // ------------------------------------------------------------------- ownership

    function testRenounceOwnershipReverts() public {
        vm.prank(owner);
        vm.expectRevert(GameRegistry.OwnershipRequired.selector);
        registry.renounceOwnership();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger));
        registry.renounceOwnership();
        assertEq(registry.owner(), owner);
    }

    /// @dev The Treasury, coordinator and modules read `registry.owner()` live, so one two-step
    /// transfer moves every owner surface at once and leaves the previous owner with nothing.
    function testTwoStepTransferMovesEveryOwnerSurface() public {
        vm.prank(owner);
        registry.transferOwnership(nextOwner);
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), nextOwner);
        // Until acceptance the old owner is still in charge and may cancel.
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger));
        registry.acceptOwnership();
        vm.prank(owner);
        registry.transferOwnership(address(0));
        assertEq(registry.pendingOwner(), address(0));
        vm.prank(nextOwner);
        vm.expectRevert(_unauthorized(nextOwner));
        registry.acceptOwnership();
        vm.prank(owner);
        registry.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), nextOwner);
        assertEq(registry.pendingOwner(), address(0));

        vm.prank(nextOwner);
        uint256 draft = registry.createGame(
            address(draw), address(rf), funder, address(0), address(0), address(0), 5, "n/{id}"
        );
        _rejects(
            owner,
            address(registry),
            abi.encodeCall(registry.retireGame, (breedsId)),
            _unauthorized(owner)
        );
        _rejects(
            owner,
            address(treasury),
            abi.encodeCall(treasury.withdrawFree, (breedsId, 1e18)),
            _selector(Treasury.NotRegistryOwner.selector)
        );
        _rejects(
            owner,
            address(coordinator),
            abi.encodeCall(coordinator.setBudget, (breedsId, 0)),
            _selector(RandomnessCoordinator.NotRegistryOwner.selector)
        );
        _rejects(
            owner,
            address(draw),
            abi.encodeCall(draw.defineClasses, (draft, LaunchTerms.breedsClasses())),
            _selector(DrawModule.NotRegistryOwner.selector)
        );
        _rejects(
            owner,
            address(round),
            abi.encodeCall(
                round.defineTerms, (draft, royaleTerms(), LaunchTerms.royaleKindPrices())
            ),
            _selector(RoundModule.NotRegistryOwner.selector)
        );
        vm.startPrank(nextOwner);
        draw.defineClasses(draft, LaunchTerms.breedsClasses());
        treasury.withdrawFree(breedsId, 1e18);
        coordinator.setBudget(draft, 1 ether);
        vm.stopPrank();
        assertEq(rf.balanceOf(funder), 1e18);
        assertEq(coordinator.budget(draft), 1 ether);
    }
}
