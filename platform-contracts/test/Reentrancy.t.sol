// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { stdStorage, StdStorage } from "forge-std/Test.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    IERC1155Receiver
} from "lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";
import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { Fixture } from "./Fixture.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import { GameItems } from "../src/GameItems.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { Treasury } from "../src/Treasury.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { MockGenerations } from "./doubles/ExternalDoubles.sol";

/// @dev One armed re-entrant call: fired from whichever hook the subclass exposes, recorded, and
/// either swallowed (so the outer call continues) or bubbled (so the outer call reverts).
abstract contract Reentrant {
    address public target;
    bytes public payload;
    bool public swallow;
    bool public armed;
    uint256 public attempts;
    bool public innerOk;
    bytes public innerReturn;

    function arm(address target_, bytes calldata payload_, bool swallow_) external {
        target = target_;
        payload = payload_;
        swallow = swallow_;
        armed = true;
    }

    /// @dev A reverted outer call rolls `armed` back to true; tests disarm before honest calls.
    function disarm() external {
        armed = false;
    }

    /// @dev Act as this contract: forwards `data` and bubbles any revert unchanged.
    function exec(address target_, bytes calldata data) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target_.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function approve(IERC20 token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function _attack() internal {
        if (!armed) return;
        armed = false;
        ++attempts;
        (innerOk, innerReturn) = target.call(payload);
        if (!innerOk && !swallow) {
            bytes memory reason = innerReturn;
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

/// @dev A Friend's owner that is also its canonical wallet, so every mint lands in its hook.
contract EvilReceiver is Reentrant, IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        _attack();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external returns (bytes4) {
        _attack();
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

/// @dev Stands in for Generations on RF's transfer side effect only: every RF movement into or
/// out of the Treasury reaches `syncPreview`, which is where this double re-enters.
contract ReentrantGenerations is Reentrant {
    function syncPreview(address, uint256) external {
        _attack();
    }
}

/// @dev docs/SPEC.md section 9 (Reentrancy.t.sol): every module entry point that moves money or
/// items is nonReentrant, mints run last, and the Treasury's own guard covers its transfers, so a
/// re-entrant call from an ERC-1155 receiver hook or from RF's `syncPreview` side effect either
/// reverts with the guard error or is an ordinary call that leaves every ledger consistent.
contract ReentrancyTest is Fixture {
    using stdStorage for StdStorage;

    uint256 internal constant FRIEND = 1234;
    uint256 internal constant ALICE_FRIEND = 4321;
    uint256 internal constant CREDIT_FRIEND = 4322;
    uint256 internal constant ENTRANT_BASE = 2000;
    bytes32 internal constant SECRET = keccak256("secret");

    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");
    EvilReceiver internal evil;
    ReentrantGenerations internal evilGen;
    bytes internal guardError =
        abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

    function setUp() public override {
        super.setUp();
        evil = new EvilReceiver();
        mintFriend(address(evil), FRIEND, 3);
        // The malicious owner is also the Friend's canonical wallet, so mints land in its hook.
        stdstore.target(address(generations)).sig("tokenBoundAccount(uint256)").with_key(FRIEND)
            .checked_write(address(evil));
        assertEq(walletOf(FRIEND), address(evil));
        rf.mint(address(evil), 100e18);
        usdg.mint(address(evil), 100e6);
        evil.approve(IERC20(address(rf)), address(treasury));
        evil.approve(IERC20(address(usdg)), address(treasury));
        mintFriend(alice, ALICE_FRIEND, 3);
        mintFriend(alice, CREDIT_FRIEND, 3);
        for (uint256 i = 1; i <= 5; ++i) {
            mintFriend(alice, ENTRANT_BASE + i, 2);
        }
        evilGen = new ReentrantGenerations();
        rf.mint(address(evilGen), 10e18);
        evilGen.approve(IERC20(address(rf)), address(treasury));
    }

    // --------------------------------------------------------------------------- helpers

    /// @dev Route RF's transfer side effect to the re-entrant double for the rest of the test.
    function _hookRF() internal {
        rf.setGenerations(MockGenerations(address(evilGen)));
    }

    function _buy(uint8 eggs) internal view returns (bytes memory) {
        return abi.encodeCall(draw.commit, (breedsId, LaunchTerms.BREEDS_BUY, FRIEND, eggs, 0, 0));
    }

    function _play() internal view returns (bytes memory) {
        return abi.encodeCall(draw.commit, (breedsId, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0));
    }

    function _eggs(address holder) internal view returns (uint256) {
        return items(breedsId).balanceOf(holder, LaunchTerms.BREEDS_EGG);
    }

    function _tierOf(address holder) internal view returns (uint16 tier) {
        for (uint16 id = 2; id <= 5; ++id) {
            if (items(breedsId).balanceOf(holder, id) != 0) tier = id;
        }
    }

    /// @dev I1 and I2 for one currency with no donations in this suite.
    function _assertConserved(address currency) internal view {
        assertSolvent(currency);
        assertEq(
            IERC20(currency).balanceOf(address(treasury)),
            treasury.backed(currency),
            "balance drifted from the ledgers"
        );
    }

    function _assertInnerGuarded(Reentrant attacker, uint256 attempts) internal view {
        assertEq(attacker.attempts(), attempts, "hook never fired");
        assertFalse(attacker.innerOk(), "re-entrant call succeeded");
        assertEq(attacker.innerReturn(), guardError, "inner call failed for another reason");
    }

    // ------------------------------------------------ ERC-1155 receiver hook, DrawModule

    /// @dev Buying eggs mints inline; the hook re-enters `commit` and the whole purchase reverts
    /// with the guard error: no payment, no reservation, no egg.
    function testCommitReentryFromMintHookRevertsWholePurchase() public {
        uint256 before = rf.balanceOf(address(evil));
        evil.arm(address(draw), _buy(1), false);
        vm.expectRevert(guardError);
        evil.exec(address(draw), _buy(1));
        assertEq(draw.commitCount(), 0);
        assertEq(_eggs(address(evil)), 0);
        assertEq(rf.balanceOf(address(evil)), before);
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, 10_000e18);
        assertEq(reserved, 0);
        _assertConserved(address(rf));
    }

    /// @dev Swallowing the inner failure lets the purchase complete exactly once.
    function testCommitReentryFromMintHookIsRefusedAndPurchaseCompletesOnce() public {
        evil.arm(address(draw), _buy(1), true);
        evil.exec(address(draw), _buy(1));
        _assertInnerGuarded(evil, 1);
        assertEq(draw.commitCount(), 1);
        assertEq(_eggs(address(evil)), 1);
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, 10_001e18 - 6e18);
        assertEq(reserved, 6e18);
        _assertConserved(address(rf));
    }

    /// @dev A settlement mint re-entering `settle`, `commit` or `redeem` reverts whole; the
    /// commit stays pending with its reservation and settles once the hook behaves.
    function testSettleReentryFromMintHookRevertsAndStaysRetryable() public {
        evil.exec(address(draw), _buy(1));
        uint256 playId = abi.decode(evil.exec(address(draw), _play()), (uint256));
        (,,,,,,, uint256 requestId) = draw.commits(playId);
        fulfill(requestId, keccak256("word"));
        bytes[] memory inner = new bytes[](3);
        inner[0] = abi.encodeCall(draw.settle, (playId));
        inner[1] = _play();
        inner[2] = abi.encodeCall(
            draw.redeem, (breedsId, FRIEND, LaunchTerms.BREEDS_COMMON, 1, bytes32(0))
        );
        for (uint256 i; i < inner.length; ++i) {
            evil.arm(address(draw), inner[i], false);
            vm.prank(stranger);
            vm.expectRevert(guardError);
            draw.settle(playId);
            (,,,,, bool settled,,) = draw.commits(playId);
            assertFalse(settled, "commit settled despite the revert");
            (, uint256 reserved, uint256 owed,) = ledger(breedsId);
            assertEq(reserved, 6e18, "reservation moved");
            assertEq(owed, 0);
            assertEq(_tierOf(address(evil)), 0, "tier minted despite the revert");
        }
        evil.arm(address(draw), abi.encodeCall(draw.settle, (playId)), true);
        vm.prank(stranger);
        draw.settle(playId);
        _assertInnerGuarded(evil, 1);
        (,,,,, bool done,,) = draw.commits(playId);
        assertTrue(done);
        uint16 tier = _tierOf(address(evil));
        assertTrue(tier != 0);
        (, uint256 reservedAfter, uint256 owedAfter,) = ledger(breedsId);
        assertEq(reservedAfter, 0);
        assertEq(owedAfter, LaunchTerms.breedsClasses()[tier - 1].value);
        _assertConserved(address(rf));
    }

    /// @dev The hook cannot reach the item collection or the Treasury directly either.
    function testMintHookCannotUseItemOrLedgerPrimitives() public {
        GameItems eggs = items(breedsId);
        bytes[] memory inner = new bytes[](4);
        bytes[] memory expected = new bytes[](4);
        uint256[] memory one = new uint256[](1);
        one[0] = LaunchTerms.BREEDS_EGG;
        uint256[] memory hundred = new uint256[](1);
        hundred[0] = 100;
        inner[0] = abi.encodeCall(eggs.mintBatch, (address(evil), one, hundred));
        expected[0] = abi.encodeWithSelector(GameItems.NotBoundModule.selector);
        inner[1] = abi.encodeCall(eggs.burn, (address(evil), LaunchTerms.BREEDS_EGG, 1));
        expected[1] = abi.encodeWithSelector(GameItems.NotBoundModule.selector);
        inner[2] = abi.encodeCall(treasury.release, (breedsId, 6e18));
        expected[2] = abi.encodeWithSelector(Treasury.NotBoundModule.selector);
        inner[3] = abi.encodeCall(
            treasury.collect, (breedsId, address(evil), ITreasury.Legs(1, 0, 0, 0, 0, 0))
        );
        expected[3] = abi.encodeWithSelector(Treasury.NotCommittingModule.selector);
        for (uint256 i; i < inner.length; ++i) {
            address target = i < 2 ? address(eggs) : address(treasury);
            evil.arm(target, inner[i], true);
            evil.exec(address(draw), _buy(1));
            assertEq(evil.attempts(), i + 1);
            assertFalse(evil.innerOk());
            assertEq(evil.innerReturn(), expected[i]);
        }
        assertEq(_eggs(address(evil)), 4);
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(reserved, 24e18);
        assertEq(free, 10_004e18 - 24e18);
        _assertConserved(address(rf));
    }

    /// @dev `enter` and `withdrawCredit` live on RoundModule, which mints nothing, so a Draw mint
    /// hook calling them is a fresh entry, not a re-entry: RoundModule is not on the stack and
    /// every Treasury leg of the outer commit completed before the mint. The calls behave exactly
    /// as sequential calls would and every ledger stays consistent. Genuine re-entry of both is
    /// exercised below through RF's transfer side effect, where the guard trips.
    function testCrossModuleCallsFromMintHookAreOrdinaryAndHarmless() public {
        vm.prank(settler);
        uint256 roundId = round.openRound(royaleId, keccak256(abi.encode(SECRET)));
        evil.exec(address(round), abi.encodeCall(round.depositCredit, (royaleId, FRIEND, 2e18)));
        assertEq(treasury.creditOf(royaleId, FRIEND), 2e18);

        uint256 before = rf.balanceOf(address(evil));
        evil.arm(
            address(round), abi.encodeCall(round.withdrawCredit, (royaleId, FRIEND, 1e18)), true
        );
        evil.exec(address(draw), _buy(1));
        assertEq(evil.attempts(), 1);
        assertTrue(evil.innerOk(), "sequential withdrawCredit refused");
        assertEq(treasury.creditOf(royaleId, FRIEND), 1e18);
        // Paid 1 RF for the egg, received 1 RF of credit back.
        assertEq(rf.balanceOf(address(evil)), before);

        evil.arm(address(round), abi.encodeCall(round.enter, (roundId, FRIEND)), true);
        evil.exec(address(draw), _buy(1));
        assertEq(evil.attempts(), 2);
        assertTrue(evil.innerOk(), "sequential enter refused");
        assertEq(round.roundOf(royaleId, FRIEND), roundId);
        assertEq(round.entrants(roundId).length, 1);
        (, uint256 royaleReserved,, uint256 royaleCredit) = ledger(royaleId);
        assertEq(royaleReserved, 1e18);
        assertEq(royaleCredit, 1e18);
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(_eggs(address(evil)), 2);
        assertEq(reserved, 12e18);
        assertEq(free, 10_002e18 - 12e18);
        _assertConserved(address(rf));
        // While the round is live the Friend's credit is locked, from a hook or otherwise.
        evil.arm(
            address(round), abi.encodeCall(round.withdrawCredit, (royaleId, FRIEND, 1e18)), true
        );
        evil.exec(address(draw), _buy(1));
        assertFalse(evil.innerOk());
        assertEq(evil.innerReturn(), abi.encodeWithSelector(RoundModule.RoundInProgress.selector));
    }

    // ------------------------------------------------ RF syncPreview side effect, Treasury

    /// @dev `fund` is nonReentrant: a transfer hook re-entering it reverts the outer deposit.
    function testFundReentryViaSyncPreviewReverts() public {
        _hookRF();
        giveRF(alice, 1e18);
        bytes memory inner = abi.encodeCall(treasury.fund, (breedsId, 1e18));
        evilGen.arm(address(treasury), inner, false);
        vm.prank(alice);
        vm.expectRevert(guardError);
        treasury.fund(breedsId, 1e18);
        (uint256 free,,,) = ledger(breedsId);
        assertEq(free, 10_000e18);
        assertEq(rf.balanceOf(alice), 1e18);
        evilGen.arm(address(treasury), inner, true);
        vm.prank(alice);
        treasury.fund(breedsId, 1e18);
        _assertInnerGuarded(evilGen, 1);
        (free,,,) = ledger(breedsId);
        assertEq(free, 10_001e18);
        _assertConserved(address(rf));
    }

    /// @dev The payment inside `commit` re-entering `commit` reverts the whole purchase.
    function testCommitReentryViaSyncPreviewReverts() public {
        _hookRF();
        giveRF(alice, 1e18);
        bytes memory inner =
            abi.encodeCall(draw.commit, (breedsId, LaunchTerms.BREEDS_BUY, ALICE_FRIEND, 1, 0, 0));
        evilGen.arm(address(draw), inner, false);
        vm.prank(alice);
        vm.expectRevert(guardError);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, ALICE_FRIEND, 1, 0, 0);
        assertEq(draw.commitCount(), 0);
        assertEq(_eggs(walletOf(ALICE_FRIEND)), 0);
        assertEq(rf.balanceOf(alice), 1e18);
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, 10_000e18);
        assertEq(reserved, 0);
        _assertConserved(address(rf));
    }

    /// @dev `collect` itself carries no guard, so a hook funding the game mid-collect is an
    /// ordinary deposit: both additions land and the balance still equals the ledgers.
    function testFundDuringCollectIsHarmless() public {
        _hookRF();
        giveRF(alice, 1e18);
        evilGen.arm(address(treasury), abi.encodeCall(treasury.fund, (breedsId, 1e18)), true);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, ALICE_FRIEND, 1, 0, 0);
        assertEq(evilGen.attempts(), 1);
        assertTrue(evilGen.innerOk(), "sequential fund refused");
        (uint256 free, uint256 reserved,,) = ledger(breedsId);
        assertEq(free, 10_002e18 - 6e18);
        assertEq(reserved, 6e18);
        assertEq(_eggs(walletOf(ALICE_FRIEND)), 1);
        _assertConserved(address(rf));
        // The ledger primitives still refuse a non-module from inside the hook.
        giveRF(alice, 1e18);
        evilGen.arm(address(treasury), abi.encodeCall(treasury.reserve, (breedsId, 1e18)), true);
        vm.prank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, ALICE_FRIEND, 1, 0, 0);
        assertFalse(evilGen.innerOk());
        assertEq(evilGen.innerReturn(), abi.encodeWithSelector(Treasury.NotBoundModule.selector));
        _assertConserved(address(rf));
    }

    /// @dev `redeem` pays through the nonReentrant `payOwed`: re-entering `redeem` trips the
    /// module guard and re-entering `fund` trips the Treasury guard; the token and its owed value
    /// stay put until an honest redeem.
    function testRedeemReentryViaSyncPreviewReverts() public {
        giveRF(alice, 1e18);
        vm.startPrank(alice);
        draw.commit(breedsId, LaunchTerms.BREEDS_BUY, ALICE_FRIEND, 1, 0, 0);
        uint256 playId = draw.commit(breedsId, LaunchTerms.BREEDS_PLAY, ALICE_FRIEND, 1, 0, 0);
        vm.stopPrank();
        (,,,,,,, uint256 requestId) = draw.commits(playId);
        fulfill(requestId, keccak256("word"));
        draw.settle(playId);
        uint16 tier = _tierOf(walletOf(ALICE_FRIEND));
        uint256 value = LaunchTerms.breedsClasses()[tier - 1].value;
        _hookRF();
        bytes memory again =
            abi.encodeCall(draw.redeem, (breedsId, ALICE_FRIEND, tier, 1, bytes32(0)));
        evilGen.arm(address(draw), again, false);
        vm.prank(alice);
        vm.expectRevert(guardError);
        draw.redeem(breedsId, ALICE_FRIEND, tier, 1, 0);
        evilGen.arm(address(treasury), abi.encodeCall(treasury.fund, (breedsId, 1e18)), false);
        vm.prank(alice);
        vm.expectRevert(guardError);
        draw.redeem(breedsId, ALICE_FRIEND, tier, 1, 0);
        (,, uint256 owed,) = ledger(breedsId);
        assertEq(owed, value);
        assertEq(items(breedsId).balanceOf(walletOf(ALICE_FRIEND), tier), 1);
        evilGen.disarm();
        vm.prank(alice);
        draw.redeem(breedsId, ALICE_FRIEND, tier, 1, 0);
        assertEq(rf.balanceOf(walletOf(ALICE_FRIEND)), value);
        (,, owed,) = ledger(breedsId);
        assertEq(owed, 0);
        _assertConserved(address(rf));
    }

    /// @dev Genuine re-entry of RoundModule: the entry payment and the credit refund both move RF,
    /// and from inside either transfer `enter`, `withdrawCredit`, `closeRound` and `fund` are all
    /// refused by a guard.
    function testRoundReentryViaSyncPreviewReverts() public {
        vm.prank(settler);
        uint256 roundId = round.openRound(royaleId, keccak256(abi.encode(SECRET)));
        giveRF(alice, 3e18);
        vm.prank(alice);
        round.depositCredit(royaleId, CREDIT_FRIEND, 2e18);
        _hookRF();
        bytes[] memory inner = new bytes[](3);
        inner[0] = abi.encodeCall(round.enter, (roundId, ALICE_FRIEND));
        inner[1] = abi.encodeCall(round.withdrawCredit, (royaleId, CREDIT_FRIEND, 1e18));
        inner[2] = abi.encodeCall(round.closeRound, (roundId));
        for (uint256 i; i < inner.length; ++i) {
            evilGen.arm(address(round), inner[i], false);
            vm.prank(alice);
            vm.expectRevert(guardError);
            round.enter(roundId, ALICE_FRIEND);
            evilGen.arm(address(round), inner[i], false);
            vm.prank(alice);
            vm.expectRevert(guardError);
            round.withdrawCredit(royaleId, CREDIT_FRIEND, 1e18);
        }
        evilGen.arm(address(treasury), abi.encodeCall(treasury.fund, (breedsId, 1e18)), false);
        vm.prank(alice);
        vm.expectRevert(guardError);
        round.withdrawCredit(royaleId, CREDIT_FRIEND, 1e18);
        assertEq(round.entrants(roundId).length, 0);
        assertEq(treasury.creditOf(royaleId, CREDIT_FRIEND), 2e18);
        assertEq(rf.balanceOf(alice), 1e18);
        // Swallowed, the outer calls complete exactly once.
        evilGen.arm(address(round), inner[0], true);
        vm.prank(alice);
        round.enter(roundId, ALICE_FRIEND);
        _assertInnerGuarded(evilGen, 1);
        evilGen.arm(address(round), inner[1], true);
        vm.prank(alice);
        round.withdrawCredit(royaleId, CREDIT_FRIEND, 1e18);
        _assertInnerGuarded(evilGen, 2);
        assertEq(round.entrants(roundId).length, 1);
        assertEq(treasury.creditOf(royaleId, CREDIT_FRIEND), 1e18);
        assertEq(rf.balanceOf(walletOf(CREDIT_FRIEND)), 1e18);
        (, uint256 reserved,, uint256 credit) = ledger(royaleId);
        assertEq(reserved, 1e18);
        assertEq(credit, 1e18);
        _assertConserved(address(rf));
    }

    /// @dev Settlement burns and pays RF; a hook re-entering `settleRound` or `abandonRound`
    /// reverts the whole settlement, which stays retryable with the same list.
    function testSettleRoundReentryViaSyncPreviewReverts() public {
        vm.prank(settler);
        uint256 roundId = round.openRound(royaleId, keccak256(abi.encode(SECRET)));
        for (uint256 i = 1; i <= 5; ++i) {
            giveRF(alice, 1e18);
            vm.prank(alice);
            round.enter(roundId, ENTRANT_BASE + i);
        }
        vm.prank(settler);
        round.closeRound(roundId);
        (,,,, uint256 requestId) = round.rounds(roundId);
        fulfill(requestId, keccak256("royale"));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = ENTRANT_BASE + 1;
        amounts[0] = round.potOf(roundId);
        _hookRF();
        bytes[] memory inner = new bytes[](2);
        inner[0] = abi.encodeCall(round.settleRound, (roundId, SECRET, ids, amounts));
        inner[1] = abi.encodeCall(round.abandonRound, (roundId));
        for (uint256 i; i < inner.length; ++i) {
            evilGen.arm(address(round), inner[i], false);
            vm.prank(settler);
            vm.expectRevert(guardError);
            round.settleRound(roundId, SECRET, ids, amounts);
            (,,, RoundModule.Status status,) = round.rounds(roundId);
            assertEq(uint8(status), uint8(RoundModule.Status.Closed));
            (, uint256 reserved,,) = ledger(royaleId);
            assertEq(reserved, 5e18, "pot moved");
        }
        evilGen.arm(address(round), inner[0], true);
        vm.prank(settler);
        round.settleRound(roundId, SECRET, ids, amounts);
        _assertInnerGuarded(evilGen, 1);
        (, uint256 reservedAfter,,) = ledger(royaleId);
        assertEq(reservedAfter, 0);
        assertEq(rf.balanceOf(walletOf(ENTRANT_BASE + 1)), 4e18);
        assertEq(treasury.rewardsPending(), 0.5e18);
        _assertConserved(address(rf));
    }
}
