// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Fixture } from "./Fixture.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { Treasury } from "../src/Treasury.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { FriendAccess } from "../src/libraries/FriendAccess.sol";
import { Rolls } from "../src/libraries/Rolls.sol";
import { MockFriendWallet } from "./doubles/ExternalDoubles.sol";

/// @dev Rare Breeds through the integrated hub (docs/SPEC.md sections 3.2, 4.2, 7.1 and the
/// `RareBreeds.t.sol` row of section 9): exact table boundaries, expected value, egg and play
/// reservations, settlement accounting, redemption, context, the purchase backing rule, Friend
/// transfer and the quantity bound.
contract RareBreedsTest is Fixture {
    uint256 internal constant FRIEND = 1234;
    uint8 internal constant GEN = 3;
    uint256 internal constant EGG_RESERVE = 6e18;
    uint256 internal constant STAKE = 10_000e18;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        mintFriend(alice, FRIEND, GEN);
    }

    // ----------------------------------------------------------------------- helpers

    /// @dev A word whose roll for draw `index` of `commitId` equals `target` (about 10k tries).
    /// Runs in its own call frame and hashes in scratch memory so the search never grows memory.
    function wordFor(uint256 commitId, uint256 index, uint16 target)
        external
        view
        returns (bytes32 word)
    {
        address module = address(draw);
        uint256 chainId = block.chainid;
        uint256 limit = type(uint256).max - (type(uint256).max % Rolls.RANGE);
        for (uint256 nonce;; ++nonce) {
            uint256 value;
            assembly ("memory-safe") {
                mstore(0, nonce)
                word := keccak256(0, 32)
                let p := mload(0x40)
                mstore(p, word)
                mstore(add(p, 32), module)
                mstore(add(p, 64), chainId)
                mstore(add(p, 96), commitId)
                mstore(add(p, 128), index)
                value := keccak256(p, 160)
            }
            if (value < limit && value % Rolls.RANGE == target) break;
        }
        assertEq(Rolls.roll(word, module, chainId, commitId, index), target, "search");
    }

    function _wordFor(uint256 commitId, uint16 target) internal view returns (bytes32) {
        return this.wordFor(commitId, 0, target);
    }

    /// @dev Call `target` through the Friend's canonical wallet as its owner. The wallet is
    /// resolved before the prank so the prank reaches `execute` itself.
    function _viaWallet(address friendOwner, uint256 friendId, address target, bytes memory data)
        internal
        returns (bytes memory)
    {
        MockFriendWallet wallet = MockFriendWallet(payable(walletOf(friendId)));
        vm.prank(friendOwner);
        return wallet.execute(target, 0, data, 0);
    }

    function _buyEggs(address buyer, uint8 quantity) internal returns (uint256 commitId) {
        giveRF(buyer, uint256(quantity) * 1e18);
        vm.prank(buyer);
        commitId = draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, quantity, 0, 0);
    }

    function _play(address player, uint8 quantity, bytes32 context)
        internal
        returns (uint256 commitId, uint256 requestId)
    {
        vm.prank(player);
        commitId = draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, quantity, context, 0);
        (,,,,,,, requestId) = draw.commits(commitId);
    }

    /// @dev Tier class (2..5) the sealed play table maps `roll` to, read from the stored rows.
    function _classForRoll(uint16 roll) internal view returns (uint16) {
        DrawTables.Row[] memory table = draw.rows(breedsId, LaunchTerms.BREEDS_PLAY, 0);
        uint256 cumulative;
        for (uint256 i; i < table.length; ++i) {
            cumulative += table[i].weightBps;
            if (roll < cumulative) return table[i].classId;
        }
        revert("roll outside table");
    }

    function _classValue(uint16 classId) internal view returns (uint256) {
        return draw.classes(breedsId)[classId - 1].value;
    }

    function _eggs(uint256 friendId) internal view returns (uint256) {
        return items(breedsId).balanceOf(walletOf(friendId), LaunchTerms.BREEDS_EGG);
    }

    function _tier(uint256 friendId, uint16 classId) internal view returns (uint256) {
        return items(breedsId).balanceOf(walletOf(friendId), classId);
    }

    /// @dev Plays one egg with a forced roll, settles and returns the minted class.
    function _playAndSettle(uint16 roll) internal returns (uint16 classId) {
        uint256[6] memory before;
        for (uint16 id = 2; id <= 5; ++id) {
            before[id] = _tier(FRIEND, id);
        }
        (uint256 commitId, uint256 requestId) = _play(alice, 1, bytes32(uint256(roll)));
        fulfill(requestId, _wordFor(commitId, roll));
        draw.settle(commitId);
        assertEq(draw.rollFor(commitId, 0), roll, "rollFor reproduces the forced roll");
        classId = _classForRoll(roll);
        assertEq(_tier(FRIEND, classId), before[classId] + 1, "tier minted");
    }

    // -------------------------------------------------------------- table boundaries

    /// @dev Rolls 0, 5999, 6000, 8499, 8500, 9749, 9750, 9999 land on exactly the classes the
    /// section 3.2 table states: Common, Spotted, Mutant, Prismatic at the cumulative edges.
    function testTableBoundariesMintExactClasses() public {
        uint16[8] memory rolls = [uint16(0), 5999, 6000, 8499, 8500, 9749, 9750, 9999];
        uint16[8] memory expected = [
            LaunchTerms.BREEDS_COMMON,
            LaunchTerms.BREEDS_COMMON,
            LaunchTerms.BREEDS_SPOTTED,
            LaunchTerms.BREEDS_SPOTTED,
            LaunchTerms.BREEDS_MUTANT,
            LaunchTerms.BREEDS_MUTANT,
            LaunchTerms.BREEDS_PRISMATIC,
            LaunchTerms.BREEDS_PRISMATIC
        ];
        _buyEggs(alice, 8);
        uint256 owedTotal;
        for (uint256 i; i < rolls.length; ++i) {
            uint16 classId = _playAndSettle(rolls[i]);
            assertEq(classId, expected[i], "boundary class");
            owedTotal += _classValue(classId);
        }
        assertEq(_eggs(FRIEND), 0, "every egg played");
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_COMMON), 2);
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_SPOTTED), 2);
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_MUTANT), 2);
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_PRISMATIC), 2);
        // 2 × (0.5 + 1 + 1.5 + 6) RF.
        assertEq(owedTotal, 18e18, "sum of boundary values");
        (uint256 free, uint256 reserved, uint256 owed,) = ledger(breedsId);
        assertEq(reserved, 0, "no egg or play left reserved");
        assertEq(owed, 18e18, "owed equals minted tier values");
        assertEq(free, STAKE + 8e18 - 18e18, "stake plus purchases minus owed");
        assertSolvent(address(rf));
    }

    /// @dev The play table and the stored classes give an expected owed value of 0.8875 RF per
    /// egg: 0.6 × 0.5 + 0.25 × 1 + 0.125 × 1.5 + 0.025 × 6.
    function testExpectedValueIsExactlyPointEightEightSevenFive() public view {
        DrawTables.Row[] memory table = draw.rows(breedsId, LaunchTerms.BREEDS_PLAY, 0);
        DrawTables.Class[] memory classes = draw.classes(breedsId);
        assertEq(table.length, 4, "four tiers");
        assertEq(classes.length, 5, "egg plus four tiers");
        uint256 weighted;
        uint256 weights;
        for (uint256 i; i < table.length; ++i) {
            assertEq(table[i].value, 0, "tiers pay through owed, never inline");
            assertTrue(table[i].classId != 0, "every row mints");
            weights += table[i].weightBps;
            weighted += uint256(table[i].weightBps) * classes[table[i].classId - 1].value;
        }
        assertEq(weights, DrawTables.BPS, "weights cover the range");
        assertEq(weighted / DrawTables.BPS, 0.8875e18, "expected value");
        assertEq(weighted % DrawTables.BPS, 0, "exact");
        assertEq(draw.maxPayable(breedsId, LaunchTerms.BREEDS_PLAY, 0), 6e18, "Prismatic");
        assertEq(draw.maxPayable(breedsId, LaunchTerms.BREEDS_BUY, 0), 6e18, "egg reserve");
    }

    // -------------------------------------------------------------------- reservations

    /// @dev Buying N eggs collects N RF into free and reserves 6N RF behind the held eggs; the
    /// inline settlement keeps the whole reservation (`resolve(6N, 0, 6N, W, 0)`).
    function testEveryEggReservesSixRF() public {
        uint256 commitId = _buyEggs(alice, 5);
        (,,,,, bool settled, uint128 reservedTotal, uint256 requestId) = draw.commits(commitId);
        assertTrue(settled, "one-row table settles inline");
        assertEq(requestId, 0, "no word requested");
        assertEq(reservedTotal, 5 * EGG_RESERVE);
        assertEq(_eggs(FRIEND), 5);
        (uint256 free, uint256 reserved, uint256 owed,) = ledger(breedsId);
        assertEq(free, STAKE + 5e18 - 30e18);
        assertEq(reserved, 30e18);
        assertEq(owed, 0);
        assertEq(rf.balanceOf(alice), 0, "the owner paid from its own address");
        assertEq(rf.balanceOf(address(treasury)), STAKE + 5e18);
        assertSolvent(address(rf));

        // A second purchase stacks: three more eggs reserve 18 RF more.
        _buyEggs(alice, 3);
        (free, reserved,,) = ledger(breedsId);
        assertEq(reserved, 48e18);
        assertEq(free, STAKE + 8e18 - 48e18);
        assertEq(_eggs(FRIEND), 8);
    }

    /// @dev Playing an egg burns it, releases its 6 RF and re-reserves 6 RF for the pending
    /// play, so the ledger does not move until settlement and the play holds exactly 6 RF.
    function testPendingPlayHoldsExactlySixRF() public {
        _buyEggs(alice, 2);
        (uint256 freeBefore, uint256 reservedBefore,,) = ledger(breedsId);
        (uint256 commitId, uint256 requestId) = _play(alice, 1, keccak256("parents"));
        assertTrue(requestId != 0, "four rows need a word");
        (,,,, uint8 generation, bool settled, uint128 reservedTotal,) = draw.commits(commitId);
        assertFalse(settled);
        assertEq(generation, GEN, "generation snapshotted");
        assertEq(reservedTotal, EGG_RESERVE, "the play holds 6 RF");
        assertEq(_eggs(FRIEND), 1, "one egg burned");
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, freeBefore, "release and reserve net to zero");
        assertEq(reserved, reservedBefore, "egg reserve swapped for play reserve");
        vm.expectRevert(DrawModule.RandomnessPending.selector);
        draw.settle(commitId);
        vm.expectRevert(DrawModule.RandomnessPending.selector);
        draw.rollFor(commitId, 0);
        assertSolvent(address(rf));
    }

    /// @dev A play works when free is zero: the burned egg's release precedes the reserve.
    function testPlayWorksWithZeroFreeStake() public {
        _buyEggs(alice, 1);
        (uint256 free,,,) = ledger(breedsId);
        vm.prank(owner);
        treasury.withdrawFree(breedsId, free);
        (free,,,) = ledger(breedsId);
        assertEq(free, 0);
        (uint256 commitId,) = _play(alice, 1, 0);
        (,,,,,, uint128 reservedTotal,) = draw.commits(commitId);
        assertEq(reservedTotal, EGG_RESERVE);
        (, uint256 reserved,,) = ledger(breedsId);
        assertEq(reserved, EGG_RESERVE);
    }

    /// @dev Settlement moves the 6 RF reservation into owed (the tier's value) and free (the
    /// rest); the tier token mints to the Friend wallet and the module holds nothing.
    function testSettlementMovesReserveToOwedAndFree() public {
        _buyEggs(alice, 1);
        (uint256 freeBefore,,,) = ledger(breedsId);
        (uint256 commitId, uint256 requestId) = _play(alice, 1, 0);
        // Roll 7100 is the section 7.1 example: Spotted, 1 RF.
        fulfill(requestId, _wordFor(commitId, 7100));
        uint256 balanceBefore = rf.balanceOf(address(treasury));
        draw.settle(commitId);
        (,,,,, bool settled,,) = draw.commits(commitId);
        assertTrue(settled);
        (uint256 free, uint256 reserved, uint256 owed,) = ledger(breedsId);
        assertEq(owed, 1e18, "Spotted value owed");
        assertEq(reserved, 0, "play reservation resolved");
        assertEq(free, freeBefore + EGG_RESERVE - 1e18, "remainder returns to free");
        assertEq(rf.balanceOf(address(treasury)), balanceBefore, "nothing paid at settlement");
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_SPOTTED), 1);
        assertEq(rf.balanceOf(address(draw)), 0, "module holds no funds");
        vm.expectRevert(DrawModule.AlreadySettled.selector);
        draw.settle(commitId);
        assertSolvent(address(rf));
    }

    /// @dev Ten eggs played at once reserve 60 RF and settle every unit in order.
    function testPlayTenEggsAtOnce() public {
        _buyEggs(alice, 10);
        (uint256 commitId, uint256 requestId) = _play(alice, 10, 0);
        (,,,,,, uint128 reservedTotal,) = draw.commits(commitId);
        assertEq(reservedTotal, 60e18);
        assertEq(_eggs(FRIEND), 0);
        fulfill(requestId, keccak256("ten"));
        draw.settle(commitId);
        uint256 expectedOwed;
        uint256 minted;
        for (uint256 i; i < 10; ++i) {
            expectedOwed += _classValue(_classForRoll(draw.rollFor(commitId, i)));
        }
        for (uint16 id = 2; id <= 5; ++id) {
            minted += _tier(FRIEND, id);
        }
        assertEq(minted, 10, "one tier per egg");
        (uint256 free, uint256 reserved, uint256 owed,) = ledger(breedsId);
        assertEq(owed, expectedOwed, "owed is the sum of the rolled values");
        assertEq(reserved, 0);
        assertEq(free, STAKE + 10e18 - expectedOwed);
        assertSolvent(address(rf));
    }

    // ---------------------------------------------------------------------- redemption

    /// @dev Redemption pays the fixed value from owed, years later, after retirement and from
    /// either the owner or the wallet; the payout always lands in the wallet.
    function testRedeemPaysExactlyAfterYears() public {
        _buyEggs(alice, 2);
        _playAndSettle(9999); // Prismatic, 6 RF
        _playAndSettle(0); // Common, 0.5 RF
        (,, uint256 owed,) = ledger(breedsId);
        assertEq(owed, 6.5e18);

        vm.warp(block.timestamp + 3 * 365 days);
        vm.roll(block.number + 7_000_000);
        vm.prank(owner);
        registry.retireGame(breedsId);

        address wallet = walletOf(FRIEND);
        vm.prank(alice);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_PRISMATIC, 1, 0);
        assertEq(rf.balanceOf(wallet), 6e18, "Prismatic pays 6 RF to the wallet");
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_PRISMATIC), 0, "token burned");

        // Through the canonical wallet as well.
        _viaWallet(
            alice,
            FRIEND,
            address(draw),
            abi.encodeCall(
                DrawModule.redeem, (breedsId, FRIEND, LaunchTerms.BREEDS_COMMON, 1, bytes32(0))
            )
        );
        assertEq(rf.balanceOf(wallet), 6.5e18, "Common pays 0.5 RF");
        (,, owed,) = ledger(breedsId);
        assertEq(owed, 0, "owed fully paid");
        assertSolvent(address(rf));

        // Nothing left to redeem; eggs are not redeemable.
        vm.prank(alice);
        vm.expectRevert(DrawModule.NotRedeemable.selector);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_EGG, 1, 0);
        vm.prank(alice);
        vm.expectRevert(DrawModule.ZeroQuantity.selector);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_COMMON, 0, 0);
    }

    /// @dev The owner can never reach owed: `withdrawFree` is bounded by free, so redemptions
    /// remain payable after every free unit has been withdrawn.
    function testOwedSurvivesFullFreeWithdrawal() public {
        _buyEggs(alice, 1);
        _playAndSettle(9999);
        (uint256 free,, uint256 owed,) = ledger(breedsId);
        vm.prank(owner);
        treasury.withdrawFree(breedsId, free);
        vm.prank(owner);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        treasury.withdrawFree(breedsId, 1);
        vm.prank(alice);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_PRISMATIC, 1, 0);
        assertEq(rf.balanceOf(walletOf(FRIEND)), owed);
        assertSolvent(address(rf));
    }

    // ------------------------------------------------------------------------- context

    /// @dev The caller-supplied context is emitted verbatim in `Committed` with the predicted
    /// commit and request ids, the wallet and the 6 RF reservation; the module never stores it.
    function testContextIsEmittedInCommitted() public {
        _buyEggs(alice, 1);
        bytes32 context = keccak256(abi.encode(uint256(42), uint256(77)));
        uint256 commitId = draw.commitCount() + 1;
        uint256 requestId = coordinator.requestCount() + 1;
        vm.expectEmit(true, true, true, true, address(draw));
        emit DrawModule.Committed(
            commitId,
            breedsId,
            FRIEND,
            walletOf(FRIEND),
            LaunchTerms.BREEDS_PLAY,
            1,
            GEN,
            EGG_RESERVE,
            requestId,
            context,
            bytes32(0)
        );
        (uint256 actual, uint256 actualRequest) = _play(alice, 1, context);
        assertEq(actual, commitId);
        assertEq(actualRequest, requestId);
    }

    /// @dev An egg purchase emits `Committed` with `requestId == 0` and then `Settled` inline.
    function testEggPurchaseEmitsInlineSettlement() public {
        giveRF(alice, 2e18);
        uint256 commitId = draw.commitCount() + 1;
        uint8[] memory rowsOut = new uint8[](2);
        vm.expectEmit(true, true, true, true, address(draw));
        emit DrawModule.Committed(
            commitId,
            breedsId,
            FRIEND,
            walletOf(FRIEND),
            LaunchTerms.BREEDS_BUY,
            2,
            GEN,
            2 * EGG_RESERVE,
            0,
            bytes32(0),
            bytes32(0)
        );
        vm.expectEmit(true, true, true, true, address(draw));
        emit DrawModule.Settled(commitId, breedsId, FRIEND, walletOf(FRIEND), rowsOut, 0, 0);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 2, 0, 0);
    }

    // ------------------------------------------------------------- purchase backing rule

    /// @dev Sets the game's free stake to exactly `target` through the owner's withdrawal.
    function _setFree(uint256 target) internal {
        (uint256 free,,,) = ledger(breedsId);
        if (free > target) {
            vm.prank(owner);
            treasury.withdrawFree(breedsId, free - target);
        } else if (free < target) {
            fundGame(breedsId, target - free);
        }
        (free,,,) = ledger(breedsId);
        assertEq(free, target, "free set");
    }

    /// @dev Buying N eggs needs `free_before + N >= 6N`: with free exactly 5N the purchase
    /// succeeds and leaves free at zero; one wei less reverts `InsufficientFree` whole, with
    /// no RF pulled and no egg minted.
    function testPurchaseNeedsFreeBeforePlusNAtLeastSixN() public {
        uint8 n = 10;
        uint256 need = uint256(n) * EGG_RESERVE;
        uint256 price = uint256(n) * 1e18;
        giveRF(alice, 2 * price);

        // One wei short: the whole purchase reverts.
        _setFree(need - price - 1);
        uint256 balanceBefore = rf.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, n, 0, 0);
        assertEq(rf.balanceOf(alice), balanceBefore, "no RF pulled on revert");
        assertEq(_eggs(FRIEND), 0, "no egg minted on revert");
        assertEq(draw.commitCount(), 0, "no commit recorded");
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, need - price - 1);
        assertEq(reserved, 0);

        // Exactly enough: free_before + N == 6N.
        _setFree(need - price);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, n, 0, 0);
        (free, reserved,,) = ledger(breedsId);
        assertEq(free, 0, "the purchase consumed every free unit");
        assertEq(reserved, need);
        assertEq(_eggs(FRIEND), n);
        assertSolvent(address(rf));

        // Nothing free now: even a single egg needs 5 RF of prior stake.
        vm.prank(alice);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        fundGame(breedsId, 5e18);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        assertEq(_eggs(FRIEND), n + 1);
    }

    /// @dev The boundary holds for every quantity the action allows.
    function testPurchaseBoundaryForEveryQuantity(uint8 n) public {
        n = uint8(bound(n, 1, 10));
        uint256 shortfall = uint256(n) * (EGG_RESERVE - 1e18);
        giveRF(alice, 2 * uint256(n) * 1e18);
        _setFree(shortfall - 1);
        vm.prank(alice);
        vm.expectRevert(Treasury.InsufficientFree.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, n, 0, 0);
        _setFree(shortfall);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, n, 0, 0);
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, 0);
        assertEq(reserved, uint256(n) * EGG_RESERVE);
        assertEq(_eggs(FRIEND), n);
    }

    /// @dev Retiring the game stops egg purchases only; plays and redemptions continue.
    function testRetireStopsPurchasesOnly() public {
        _buyEggs(alice, 2);
        _playAndSettle(9999);
        vm.prank(owner);
        registry.retireGame(breedsId);
        giveRF(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(DrawModule.GameNotActive.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        (uint256 commitId, uint256 requestId) = _play(alice, 1, 0);
        fulfill(requestId, _wordFor(commitId, 0));
        draw.settle(commitId);
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_COMMON), 1);
        vm.prank(alice);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_PRISMATIC, 1, 0);
        assertEq(rf.balanceOf(walletOf(FRIEND)), 6e18);
    }

    // ------------------------------------------------------------------- NFT transfer

    /// @dev Transferring the Friend changes the owner only: eggs, the pending play and tier
    /// tokens all sit in the fixed canonical wallet, so the new owner plays the eggs, receives
    /// the pending result and redeems the tiers while the old owner is locked out.
    function testTransferCarriesEggsPendingPlaysAndTiers() public {
        _buyEggs(alice, 4);
        _playAndSettle(9999); // Prismatic held in the wallet
        (uint256 pendingId, uint256 pendingRequest) = _play(alice, 1, keccak256("pending"));
        assertEq(_eggs(FRIEND), 2);
        address wallet = walletOf(FRIEND);

        vm.prank(alice);
        generations.transfer(FRIEND, bob);
        assertEq(generations.ownerOf(FRIEND), bob);
        assertEq(walletOf(FRIEND), wallet, "the wallet is a function of the token id");

        // The old owner can no longer act for the Friend.
        vm.prank(alice);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
        vm.prank(alice);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_PRISMATIC, 1, 0);

        // The pending play settles into the same wallet, now controlled by the new owner.
        fulfill(pendingRequest, _wordFor(pendingId, 6000));
        draw.settle(pendingId);
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_SPOTTED), 1, "pending result followed");

        // The new owner plays the carried eggs and redeems the carried tiers.
        vm.prank(bob);
        uint256 commitId =
            draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 2, keccak256("bob"), 0);
        assertEq(_eggs(FRIEND), 0, "eggs carried and played");
        (,,,,,,, uint256 requestId) = draw.commits(commitId);
        fulfill(requestId, keccak256("bob word"));
        draw.settle(commitId);
        vm.prank(bob);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_PRISMATIC, 1, 0);
        assertEq(rf.balanceOf(wallet), 6e18, "paid into the wallet, not to bob");
        assertEq(rf.balanceOf(bob), 0);
        vm.prank(bob);
        draw.redeem(breedsId, FRIEND, LaunchTerms.BREEDS_SPOTTED, 1, 0);
        assertEq(rf.balanceOf(wallet), 7e18);

        // Bob also buys new eggs; the purchase is paid from bob's address.
        giveRF(bob, 1e18);
        vm.prank(bob);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        assertEq(_eggs(FRIEND), 1);
        assertSolvent(address(rf));
    }

    /// @dev A promotion after commit changes nothing already committed; the snapshot stays.
    function testGenerationSnapshotSurvivesPromotion() public {
        _buyEggs(alice, 1);
        (uint256 commitId, uint256 requestId) = _play(alice, 1, 0);
        generations.promote(FRIEND);
        assertEq(generations.generation(FRIEND), GEN - 1);
        (,,,, uint8 generation,,,) = draw.commits(commitId);
        assertEq(generation, GEN, "snapshot unchanged");
        fulfill(requestId, _wordFor(commitId, 8500));
        draw.settle(commitId);
        assertEq(_tier(FRIEND, LaunchTerms.BREEDS_MUTANT), 1);
    }

    // --------------------------------------------------------------- quantity bounds

    /// @dev `maxUnits` (10 for both actions) bounds `quantity`; zero is refused too.
    function testMaxUnitsBoundsQuantity() public {
        giveRF(alice, 11e18);
        vm.prank(alice);
        vm.expectRevert(DrawModule.InvalidQuantity.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 11, 0, 0);
        vm.prank(alice);
        vm.expectRevert(DrawModule.InvalidQuantity.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(DrawModule.InvalidQuantity.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, type(uint8).max, 0, 0);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 10, 0, 0);
        assertEq(_eggs(FRIEND), 10);
        giveRF(alice, 1e18);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        assertEq(_eggs(FRIEND), 11);

        // Plays are bounded the same way, before any egg is burned.
        vm.prank(alice);
        vm.expectRevert(DrawModule.InvalidQuantity.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 11, 0, 0);
        vm.prank(alice);
        vm.expectRevert(DrawModule.InvalidQuantity.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 0, 0, 0);
        assertEq(_eggs(FRIEND), 11, "no egg burned by a refused play");
        (DrawTables.Input input,,,,, uint8 maxUnits,) =
            draw.actions(breedsId, LaunchTerms.BREEDS_PLAY);
        assertEq(uint8(input), uint8(DrawTables.Input.BurnClass));
        assertEq(maxUnits, 10);
        (,,,,, maxUnits,) = draw.actions(breedsId, LaunchTerms.BREEDS_BUY);
        assertEq(maxUnits, 10);
    }

    /// @dev Playing more eggs than the wallet holds reverts in the burn, before any reserve.
    function testPlayNeedsTheEggs() public {
        _buyEggs(alice, 1);
        vm.prank(alice);
        vm.expectRevert();
        draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 2, 0, 0);
        (, uint256 reserved,,) = ledger(breedsId);
        assertEq(reserved, EGG_RESERVE, "only the held egg is reserved");
        assertEq(_eggs(FRIEND), 1);
    }

    /// @dev Strangers and third parties with an allowance can never be charged for a Friend.
    function testOnlyControllerCommits() public {
        giveRF(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        assertEq(rf.balanceOf(bob), 1e18);
        vm.prank(alice);
        vm.expectRevert(DrawModule.UnknownAction.selector);
        draw.commit(breedsId, 3, FRIEND, 1, 0, 0);
    }
}
