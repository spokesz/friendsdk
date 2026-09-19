// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ChanceGame, IDiceEntropy } from "../src/ChanceGame.sol";
import { Consumable } from "../src/Consumable.sol";

// These fixtures model only the existing contracts' external calls. No Rare Friends
// protocol implementation is bundled or deployed by this package.
contract MockRF is ERC20 {
    constructor() ERC20("Mock RF", "RF") { }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract MockGenerations {
    address public immutable token;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint8) public generation;
    mapping(uint256 => address) public tokenBoundAccount;

    constructor(address token_) {
        token = token_;
    }

    function mint(address owner, uint256 id, uint8 generation_) external {
        ownerOf[id] = owner;
        generation[id] = generation_;
        tokenBoundAccount[id] = address(new MockFriendWallet(this, id));
    }

    function transfer(uint256 id, address recipient) external {
        assert(msg.sender == ownerOf[id]);
        ownerOf[id] = recipient;
    }
}

contract MockFriendWallet {
    MockGenerations private immutable _generations;
    uint256 private immutable _friendId;

    error NotOwner();

    constructor(MockGenerations generations_, uint256 friendId_) {
        _generations = generations_;
        _friendId = friendId_;
    }

    function owner() external view returns (address) {
        return _generations.ownerOf(_friendId);
    }

    function token() external view returns (uint256, address, uint256) {
        return (block.chainid, address(_generations), _friendId);
    }

    function execute(address target, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result)
    {
        if (msg.sender != _generations.ownerOf(_friendId)) revert NotOwner();
        assert(operation == 0);
        bool success;
        (success, result) = target.call{ value: value }(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    receive() external payable { }
}

contract MockDice is IDiceEntropy {
    uint128 public constant FEE = 0.000_05 ether;
    uint64 public constant REFUND_DELAY_BLOCKS = 6;
    address public immutable provider;
    uint64 public sequenceNumber;
    uint128 public fee = FEE;
    mapping(uint64 => DiceRequest) private _requests;
    bool public failRequests;

    error RequestFailed();
    // Dice's own names, so a game-side revert reads as it would against deployed code.
    error Unauthorized();
    error RefundNotAvailable();
    error NoSuchRequest();

    constructor(address provider_) {
        provider = provider_;
    }

    function setFailRequests(bool value) external {
        failRequests = value;
    }

    function setFee(uint128 value) external {
        fee = value;
    }

    /// @dev Dice's failed-callback state: the word is already public and stays requestable.
    function setCallbackFailed(uint64 sequence) external {
        _requests[sequence].callbackStatus = 3;
    }

    function getFeeV2(address provider_, uint32 gasLimit) external view returns (uint128) {
        assert(provider_ == provider && gasLimit == 200_000);
        return fee;
    }

    function getRefundDelayBlocks() external pure returns (uint64) {
        return REFUND_DELAY_BLOCKS;
    }

    function getRequestV2(address provider_, uint64 sequence)
        external
        view
        returns (DiceRequest memory)
    {
        assert(provider_ == provider);
        return _requests[sequence];
    }

    function requestV2(address provider_, bytes32, uint32 gasLimit)
        external
        payable
        returns (uint64 sequence)
    {
        if (failRequests) revert RequestFailed();
        assert(provider_ == provider && gasLimit == 200_000 && msg.value == fee);
        sequence = ++sequenceNumber;
        _requests[sequence] = DiceRequest({
            provider: provider,
            sequenceNumber: sequence,
            numHashes: 0,
            commitment: bytes32(0),
            blockNumber: uint64(block.number),
            requester: msg.sender,
            useBlockhash: false,
            callbackStatus: 1,
            gasLimit10k: 20,
            feePaid: uint128(msg.value)
        });
    }

    /// @dev Only the requester reclaims, only after the delay. Clearing zeroes the stored
    /// sequence number and leaves the remaining fields, exactly as Dice does.
    function refundRequest(address provider_, uint64 sequence) external {
        assert(provider_ == provider);
        DiceRequest storage stored = _requests[sequence];
        if (sequence == 0 || stored.sequenceNumber != sequence) revert NoSuchRequest();
        if (msg.sender != stored.requester) revert Unauthorized();
        if (block.number < stored.blockNumber + REFUND_DELAY_BLOCKS) revert RefundNotAvailable();
        uint128 feePaid = stored.feePaid;
        stored.sequenceNumber = 0;
        (bool sent,) = msg.sender.call{ value: feePaid }("");
        assert(sent);
    }

    function fulfill(uint64 sequence, bytes32 word) external returns (uint256 gasUsed) {
        DiceRequest storage stored = _requests[sequence];
        address consumer = stored.requester;
        if (consumer == address(0) || stored.callbackStatus != 1) revert NoSuchRequest();
        uint256 beforeGas = gasleft();
        ChanceGame(payable(consumer))._entropyCallback(sequence, provider, word);
        gasUsed = beforeGas - gasleft();
        stored.sequenceNumber = 0;
    }
}

contract ChanceGameTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant PROVIDER = address(0xD1CE);
    uint256 private constant ALICE_FRIEND = 1;
    uint256 private constant BOB_FRIEND = 2;
    uint256 private constant TEMPORARY_FRIEND = 3;

    MockRF private rf;
    MockGenerations private generations;
    MockDice private dice;
    ChanceGame private game;

    function setUp() public {
        rf = new MockRF();
        generations = new MockGenerations(address(rf));
        dice = new MockDice(PROVIDER);
        generations.mint(ALICE, ALICE_FRIEND, 1);
        generations.mint(BOB, BOB_FRIEND, 2);
        generations.mint(ALICE, TEMPORARY_FRIEND, 0);
        game = _deploy(_table());
        rf.mint(address(this), 1000 ether);
        rf.mint(ALICE, 100 ether);
        rf.mint(_account(ALICE_FRIEND), 100 ether);
        rf.mint(_account(BOB_FRIEND), 100 ether);
        rf.approve(address(game), type(uint256).max);
        _execute(
            ALICE,
            ALICE_FRIEND,
            address(rf),
            abi.encodeCall(rf.approve, (address(game), type(uint256).max))
        );
        _execute(
            BOB,
            BOB_FRIEND,
            address(rf),
            abi.encodeCall(rf.approve, (address(game), type(uint256).max))
        );
        vm.deal(address(this), 10 ether);
    }

    function testPublishedFishingTableAndBoundaries() public view {
        uint256 expectedValue;
        uint256 lower;
        for (uint256 id = 1; id <= game.outcomeCount(); ++id) {
            (uint16 chance, uint256 reward, string memory metadataURI) = game.outcomes(id);
            assertEq(game.outcomeForRoll(lower), id);
            assertEq(game.outcomeForRoll(lower + chance - 1), id);
            assertEq(game.uri(id), metadataURI);
            lower += chance;
            expectedValue += reward * chance;
        }
        assertEq(lower, 10_000);
        assertEq(expectedValue / 10_000, 0.9 ether);
        assertEq(game.price(), 1 ether);
        assertEq(game.maxPrize(), 10 ether);
        assertEq(game.consumable().decimals(), 0);
        assertEq(game.consumable().game(), address(game));
        assertEq(game.team(), address(this));
        assertLe(address(game).code.length, 24_576);
    }

    function testInvalidTermsAndMismatchedRFRejected() public {
        ChanceGame.Outcome[] memory table = _table();
        table[0].chanceBps = 1499;
        vm.expectRevert(ChanceGame.InvalidConfiguration.selector);
        _deploy(table);
        table = _table();
        table[0].chanceBps = 0;
        vm.expectRevert(ChanceGame.InvalidConfiguration.selector);
        _deploy(table);
        table = _table();
        for (uint256 i; i < table.length; ++i) {
            table[i].reward = 0;
        }
        vm.expectRevert(ChanceGame.InvalidConfiguration.selector);
        _deploy(table);
        MockRF otherToken = new MockRF();
        vm.expectRevert(ChanceGame.InvalidConfiguration.selector);
        new ChanceGame(
            address(otherToken),
            address(generations),
            address(dice),
            PROVIDER,
            "Bait",
            "BAIT",
            1 ether,
            _table()
        );
        vm.expectRevert(ChanceGame.InvalidOutcome.selector);
        game.outcomeForRoll(10_000);
        vm.expectRevert(ChanceGame.InvalidOutcome.selector);
        game.uri(0);
    }

    function testOnlyCanonicalWalletCanPayAndReceivePurchasedBait() public {
        game.fund(20 ether);
        vm.prank(ALICE);
        rf.approve(address(game), 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.NotFriendWallet.selector);
        game.buy(ALICE_FRIEND, 1);
        vm.prank(BOB);
        vm.expectRevert(ChanceGame.NotFriendController.selector);
        game.buy(ALICE_FRIEND, 1);
        uint256 ownerBalance = rf.balanceOf(ALICE);
        uint256 walletBalance = rf.balanceOf(_account(ALICE_FRIEND));
        _buy(ALICE, ALICE_FRIEND, 1);
        assertEq(rf.balanceOf(ALICE), ownerBalance);
        assertEq(rf.balanceOf(_account(ALICE_FRIEND)), walletBalance - 1 ether);
        assertEq(game.consumable().balanceOf(_account(ALICE_FRIEND)), 1);
        assertEq(game.consumable().balanceOf(ALICE), 0);
    }

    function testTemporaryAndUnrelatedFriendsCannotEnter() public {
        game.fund(20 ether);
        vm.prank(_account(TEMPORARY_FRIEND));
        vm.expectRevert(ChanceGame.InvalidFriend.selector);
        game.buy(TEMPORARY_FRIEND, 1);
        vm.prank(_account(BOB_FRIEND));
        vm.expectRevert(ChanceGame.NotFriendController.selector);
        game.buy(ALICE_FRIEND, 1);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.InvalidFriend.selector);
        game.play(TEMPORARY_FRIEND, 1);
    }

    function testZeroAndUnderfundedStakeBlockNewSalesUntilTopup() public {
        assertFalse(game.canBuy(1));
        _expectBuyFailure(ALICE_FRIEND, 1);
        game.fund(9 ether);
        _expectBuyFailure(ALICE_FRIEND, 1);
        game.fund(1 ether);
        assertTrue(game.canBuy(1));
        _buy(ALICE, ALICE_FRIEND, 1);
        assertEq(game.reservedPlays(), 10 ether);
        assertEq(game.freeStake(), 1 ether);
        _expectBuyFailure(BOB_FRIEND, 1);
        game.fund(9 ether);
        _buy(BOB, BOB_FRIEND, 1);
        _assertBacking();
    }

    function testBulkPurchaseReservesEntireQuantityOrRevertsAtomically() public {
        game.fund(18 ether);
        uint256 balanceBefore = rf.balanceOf(_account(ALICE_FRIEND));
        _expectBuyFailure(ALICE_FRIEND, 3);
        assertEq(rf.balanceOf(_account(ALICE_FRIEND)), balanceBefore);
        assertEq(game.consumable().totalSupply(), 0);
        assertEq(game.reservedPlays(), 0);
        _buy(ALICE, ALICE_FRIEND, 2);
        assertEq(game.freeStake(), 0);
        assertEq(game.reservedPlays(), 20 ether);
        _assertBacking();
    }

    function testPrepaidBatchRemainsPlayableAndBackedWithNoFreeStake() public {
        game.fund(18 ether);
        _buy(ALICE, ALICE_FRIEND, 2);
        vm.prank(ALICE);
        (uint256 first, uint256 batchId) = game.play(ALICE_FRIEND, 2);
        assertEq(first, batchId);
        (, uint256 secondBatch,) = game.plays(first + 1);
        assertEq(secondBatch, batchId);
        assertEq(game.reservedPlays(), 20 ether);
        assertEq(game.pendingPlays(), 2);
        _expectBuyFailure(BOB_FRIEND, 1);
        uint256 word;
        while (_outcome(word, batchId, first) != 8 || _outcome(word, batchId, first + 1) != 1) {
            ++word;
        }
        _fulfill(batchId, word);
        game.settle(first);
        assertEq(game.rewardLiability(), 10 ether);
        assertEq(game.freeStake(), 0);
        _assertBacking();
        game.settle(first + 1);
        assertEq(game.reservedPlays(), 0);
        assertEq(game.freeStake(), 10 ether);
        _assertBacking();
        vm.expectRevert(ChanceGame.InvalidPlay.selector);
        game.settle(first);
    }

    function testPerpetualRedemptionPaysExactlyAfterDecades() public {
        game.fund(10 ether);
        _buy(ALICE, ALICE_FRIEND, 1);
        vm.prank(ALICE);
        (uint256 playId, uint256 batchId) = game.play(ALICE_FRIEND, 1);
        _fulfill(batchId, _wordForOutcome(batchId, playId, 8));
        game.settle(playId);
        game.withdrawSurplus(address(this), 1 ether);
        vm.warp(block.timestamp + 100 * 365 days);
        assertEq(game.rewardLiability(), 10 ether);
        uint256 balanceBefore = rf.balanceOf(_account(ALICE_FRIEND));
        vm.prank(ALICE);
        game.redeem(ALICE_FRIEND, 8, 1);
        assertEq(rf.balanceOf(_account(ALICE_FRIEND)), balanceBefore + 10 ether);
        assertEq(game.rewardLiability(), 0);
        assertEq(rf.balanceOf(address(game)), 0);
        assertFalse(game.canBuy(1));
        vm.prank(ALICE);
        vm.expectRevert();
        game.redeem(ALICE_FRIEND, 8, 1);
    }

    function testNFTTransferCarriesBaitPendingPlaysAndRewards() public {
        game.fund(20 ether);
        _buy(ALICE, ALICE_FRIEND, 2);
        vm.prank(ALICE);
        (uint256 playId, uint256 batchId) = game.play(ALICE_FRIEND, 1);
        address wallet = _account(ALICE_FRIEND);
        vm.prank(ALICE);
        generations.transfer(ALICE_FRIEND, BOB);
        assertEq(_account(ALICE_FRIEND), wallet);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.NotFriendController.selector);
        game.play(ALICE_FRIEND, 1);
        vm.prank(BOB);
        game.play(ALICE_FRIEND, 1);
        _fulfill(batchId, _wordForOutcome(batchId, playId, 8));
        game.settle(playId);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.NotFriendController.selector);
        game.redeem(ALICE_FRIEND, 8, 1);
        _execute(
            BOB, ALICE_FRIEND, address(game), abi.encodeCall(game.redeem, (ALICE_FRIEND, 8, 1))
        );
        game.fund(10 ether);
        _buy(BOB, ALICE_FRIEND, 1);
        _assertBacking();
    }

    function testConsumableAndRewardInventoryCannotBeExtractedOrForged() public {
        game.fund(20 ether);
        _buy(ALICE, ALICE_FRIEND, 2);
        Consumable bait = game.consumable();
        address wallet = _account(ALICE_FRIEND);
        vm.expectRevert(Consumable.OnlyGame.selector);
        bait.mint(wallet, 1);
        vm.expectRevert(Consumable.OnlyGame.selector);
        bait.controllerBurn(wallet, 1);
        vm.prank(wallet);
        vm.expectRevert(Consumable.FriendBoundInventory.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        bait.transfer(ALICE, 1);
        vm.prank(wallet);
        bait.approve(BOB, 1);
        vm.prank(BOB);
        vm.expectRevert(Consumable.FriendBoundInventory.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        bait.transferFrom(wallet, BOB, 1);
        _execute(ALICE, ALICE_FRIEND, address(game), abi.encodeCall(game.play, (ALICE_FRIEND, 1)));
        _fulfill(1, _wordForOutcome(1, 1, 2));
        game.settle(1);
        vm.prank(wallet);
        vm.expectRevert(ChanceGame.FriendBoundInventory.selector);
        game.safeTransferFrom(wallet, ALICE, 2, 1, "");
        vm.prank(wallet);
        game.setApprovalForAll(BOB, true);
        vm.prank(BOB);
        vm.expectRevert(ChanceGame.FriendBoundInventory.selector);
        game.safeTransferFrom(wallet, BOB, 2, 1, "");
        _assertBacking();
    }

    function testOnlyDeployerCanWithdrawAndAllCommitmentsRemainReserved() public {
        game.fund(100 ether);
        _buy(ALICE, ALICE_FRIEND, 3);
        vm.prank(BOB);
        vm.expectRevert(ChanceGame.OnlyTeam.selector);
        game.withdrawSurplus(BOB, 1 ether);
        vm.expectRevert(ChanceGame.InsufficientStake.selector);
        game.withdrawSurplus(address(this), 74 ether);
        game.withdrawSurplus(address(this), 73 ether);
        vm.prank(ALICE);
        (uint256 playId, uint256 batchId) = game.play(ALICE_FRIEND, 1);
        _fulfill(batchId, _wordForOutcome(batchId, playId, 8));
        game.settle(playId);
        assertEq(game.reservedPlays(), 20 ether);
        assertEq(game.rewardLiability(), 10 ether);
        vm.expectRevert(ChanceGame.InsufficientStake.selector);
        game.withdrawSurplus(address(this), 1);
        vm.prank(ALICE);
        game.play(ALICE_FRIEND, 2);
        _assertBacking();
    }

    function testPendingRandomnessCannotBeReplacedOrSettledEarly() public {
        game.fund(10 ether);
        _buy(ALICE, ALICE_FRIEND, 1);
        vm.prank(ALICE);
        (uint256 playId, uint256 batchId) = game.play(ALICE_FRIEND, 1);
        vm.expectRevert(ChanceGame.RandomnessPending.selector);
        game.settle(playId);
        game.requestRandomness{ value: dice.FEE() }(batchId);
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(MockDice.RefundNotAvailable.selector);
        game.retryRandomness{ value: 0.000_05 ether }(batchId);
        vm.expectRevert(ChanceGame.RandomnessPending.selector);
        game.settle(playId);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(ChanceGame.RandomnessAlreadyRequested.selector);
        game.requestRandomness{ value: 0.000_05 ether }(batchId);
        assertEq(game.reservedPlays(), 10 ether);
        _assertBacking();
    }

    function testRetryNeedsFriendControllerAndDiceDelayThenBindsOneNewRequest() public {
        game.fund(10 ether);
        _buy(ALICE, ALICE_FRIEND, 1);
        vm.prank(ALICE);
        (uint256 playId, uint256 batchId) = game.play(ALICE_FRIEND, 1);
        uint128 fee = dice.FEE();
        uint64 stale = game.requestRandomness{ value: fee }(batchId);

        vm.deal(BOB, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(ChanceGame.NotFriendController.selector);
        game.retryRandomness{ value: fee }(batchId);
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(MockDice.RefundNotAvailable.selector);
        game.retryRandomness{ value: fee }(batchId);

        uint256 ownerETH = ALICE.balance;
        vm.roll(block.number + 6);
        vm.prank(ALICE);
        uint64 retried = game.retryRandomness{ value: fee }(batchId);
        assertNotEq(retried, stale);
        assertEq(ALICE.balance, ownerETH);
        _assertOnlyTheRequestChanged(batchId, retried);
        vm.expectRevert(ChanceGame.InvalidRandomness.selector);
        dice.fulfill(stale, bytes32(0));

        // The canonical wallet is the second controller the game accepts.
        vm.roll(block.number + 6);
        uint64 second = _retryAsWallet(batchId);
        assertNotEq(second, retried);
        _assertOnlyTheRequestChanged(batchId, second);

        dice.fulfill(second, bytes32(_wordForOutcome(batchId, playId, 8)));
        game.settle(playId);
        (,, uint256 outcomeId) = game.plays(playId);
        assertEq(outcomeId, 8);
        assertEq(game.pendingPlays(), 0);
        assertEq(address(game).balance, 0);
        _assertBacking();
    }

    function testRetryPaysFullFeeAndReturnsReclaimedFee() public {
        game.fund(10 ether);
        _buy(ALICE, ALICE_FRIEND, 1);
        vm.prank(ALICE);
        (, uint256 batchId) = game.play(ALICE_FRIEND, 1);
        uint128 paid = dice.FEE();
        game.requestRandomness{ value: paid }(batchId);
        vm.deal(ALICE, 1 ether);

        // A raised fee is paid in full now; the old fee comes back in the same call.
        dice.setFee(paid * 2);
        vm.roll(block.number + 6);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.IncorrectOracleFee.selector);
        game.retryRandomness{ value: paid }(batchId);
        uint256 ownerETH = ALICE.balance;
        vm.prank(ALICE);
        game.retryRandomness{ value: paid * 2 }(batchId);
        assertEq(ALICE.balance, ownerETH - paid * 2 + paid);
        assertEq(address(game).balance, 0);

        // A lowered fee costs less than what Dice returns; neither rests in the game.
        dice.setFee(paid / 2);
        vm.roll(block.number + 6);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.IncorrectOracleFee.selector);
        game.retryRandomness{ value: paid * 2 }(batchId);
        ownerETH = ALICE.balance;
        vm.prank(ALICE);
        game.retryRandomness{ value: paid / 2 }(batchId);
        assertEq(ALICE.balance, ownerETH - paid / 2 + paid * 2);
        assertEq(address(game).balance, 0);
    }

    function testRetryRefusesUnrequestedFulfilledSettledAndRevealedBatches() public {
        game.fund(30 ether);
        _buy(ALICE, ALICE_FRIEND, 3);
        vm.startPrank(ALICE);
        (, uint256 unrequested) = game.play(ALICE_FRIEND, 1);
        (uint256 deliveredPlay, uint256 delivered) = game.play(ALICE_FRIEND, 1);
        (, uint256 revealed) = game.play(ALICE_FRIEND, 1);
        vm.stopPrank();
        vm.deal(ALICE, 1 ether);
        uint128 fee = dice.FEE();
        uint256 ownerETH = ALICE.balance;

        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.InvalidBatch.selector);
        game.retryRandomness{ value: fee }(99);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.RetryUnavailable.selector);
        game.retryRandomness{ value: fee }(unrequested);

        _fulfill(delivered, _wordForOutcome(delivered, deliveredPlay, 8));
        vm.roll(block.number + 6);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.RetryUnavailable.selector);
        game.retryRandomness{ value: fee }(delivered);
        game.settle(deliveredPlay);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.RetryUnavailable.selector);
        game.retryRandomness{ value: fee }(delivered);

        // Dice status 3 means the word is already public; reclaiming it would be a reroll.
        uint64 sequence = game.requestRandomness{ value: fee }(revealed);
        dice.setCallbackFailed(sequence);
        vm.roll(block.number + 6);
        vm.prank(ALICE);
        vm.expectRevert(ChanceGame.RetryUnavailable.selector);
        game.retryRandomness{ value: fee }(revealed);

        assertEq(ALICE.balance, ownerETH);
        assertEq(address(game).balance, 0);
        assertEq(address(dice).balance, 2 * fee);
        _assertBacking();
    }

    function testGameAcceptsEtherOnlyFromDice() public {
        vm.deal(BOB, 1 ether);
        vm.prank(BOB);
        (bool sent,) = address(game).call{ value: 1 wei }("");
        assertFalse(sent);
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (sent,) = address(game).call{ value: 1 wei }("");
        assertFalse(sent);
        assertEq(address(game).balance, 0);
    }

    function testSponsorRequestsOnlyCommittedBatchesAndExactFee() public {
        vm.expectRevert(ChanceGame.InvalidBatch.selector);
        game.requestRandomness{ value: 0.000_05 ether }(0);
        vm.expectRevert(ChanceGame.InvalidBatch.selector);
        game.requestRandomness{ value: 0.000_05 ether }(1);
        game.fund(20 ether);
        _buy(ALICE, ALICE_FRIEND, 2);
        vm.prank(ALICE);
        game.play(ALICE_FRIEND, 2);
        vm.expectRevert(ChanceGame.InvalidBatch.selector);
        game.requestRandomness{ value: 0.000_05 ether }(2);
        vm.expectRevert(ChanceGame.IncorrectOracleFee.selector);
        game.requestRandomness{ value: 0.000_04 ether }(1);
        vm.expectRevert(ChanceGame.IncorrectOracleFee.selector);
        game.requestRandomness{ value: 0.000_06 ether }(1);
        dice.setFailRequests(true);
        vm.expectRevert(MockDice.RequestFailed.selector);
        game.requestRandomness{ value: 0.000_05 ether }(1);
        (uint64 sequence, bool requested, bool fulfilled,) = game.randomness(1);
        assertEq(sequence, 0);
        assertFalse(requested);
        assertFalse(fulfilled);
        dice.setFailRequests(false);
        vm.deal(BOB, 1 ether);
        vm.prank(BOB);
        sequence = game.requestRandomness{ value: 0.000_05 ether }(1);
        assertEq(sequence, 1);
        assertEq(address(game).balance, 0);
        assertEq(address(dice).balance, 0.000_05 ether);
    }

    function testCallbackAuthenticationUnknownRequestsReplayAndZeroWord() public {
        game.fund(10 ether);
        _buy(ALICE, ALICE_FRIEND, 1);
        vm.prank(ALICE);
        game.play(ALICE_FRIEND, 1);
        uint64 sequence = game.requestRandomness{ value: dice.FEE() }(1);
        vm.expectRevert(ChanceGame.UnauthorizedRandomness.selector);
        game._entropyCallback(sequence, PROVIDER, bytes32(0));
        vm.prank(address(dice));
        vm.expectRevert(ChanceGame.UnauthorizedRandomness.selector);
        game._entropyCallback(sequence, BOB, bytes32(0));
        vm.prank(address(dice));
        vm.expectRevert(ChanceGame.InvalidRandomness.selector);
        game._entropyCallback(sequence + 1, PROVIDER, bytes32(0));
        uint256 callbackGas = dice.fulfill(sequence, bytes32(0));
        assertLt(callbackGas, game.CALLBACK_GAS_LIMIT());
        (,, bool fulfilled, bytes32 word) = game.randomness(1);
        assertTrue(fulfilled);
        assertEq(word, bytes32(0));
        vm.expectRevert(ChanceGame.InvalidRandomness.selector);
        dice.fulfill(sequence, bytes32(uint256(1)));
        vm.prank(BOB);
        game.settle(1);
        (,, uint256 outcome) = game.plays(1);
        assertEq(outcome, _outcome(0, 1, 1));
        assertEq(game.balanceOf(_account(ALICE_FRIEND), outcome), 1);
        assertEq(game.balanceOf(_account(BOB_FRIEND), outcome), 0);
    }

    function testSeparateBatchesCannotShareOrReplaceRandomness() public {
        game.fund(20 ether);
        _buy(ALICE, ALICE_FRIEND, 2);
        vm.startPrank(ALICE);
        (uint256 first, uint256 firstBatch) = game.play(ALICE_FRIEND, 1);
        (uint256 second, uint256 secondBatch) = game.play(ALICE_FRIEND, 1);
        vm.stopPrank();
        assertNotEq(firstBatch, secondBatch);
        uint64 firstSequence = game.requestRandomness{ value: dice.FEE() }(firstBatch);
        uint64 secondSequence = game.requestRandomness{ value: dice.FEE() }(secondBatch);
        dice.fulfill(secondSequence, bytes32(uint256(42)));
        vm.expectRevert(ChanceGame.RandomnessPending.selector);
        game.settle(first);
        game.settle(second);
        dice.fulfill(firstSequence, bytes32(uint256(7)));
        game.settle(first);
        assertEq(game.pendingPlays(), 0);
        _assertBacking();
    }

    function testFuzzBackingAcrossBuyersCastsWithdrawalsAndRedemptions(
        uint8 aliceQuantity,
        uint8 bobQuantity,
        uint256 firstWord,
        uint256 secondWord
    ) public {
        uint256 a = bound(aliceQuantity, 1, 8);
        uint256 b = bound(bobQuantity, 1, 8);
        game.fund((a + b) * 10 ether);
        _buy(ALICE, ALICE_FRIEND, a);
        _assertBacking();
        _buy(BOB, BOB_FRIEND, b);
        _assertBacking();
        vm.prank(ALICE);
        (, uint256 firstBatch) = game.play(ALICE_FRIEND, a);
        vm.prank(BOB);
        (, uint256 secondBatch) = game.play(BOB_FRIEND, b);
        game.withdrawSurplus(address(this), game.freeStake());
        _fulfill(firstBatch, firstWord);
        _fulfill(secondBatch, secondWord);
        for (uint256 playId = a + b; playId != 0; --playId) {
            game.settle(playId);
            _assertBacking();
        }
        for (uint256 id = 2; id <= game.outcomeCount(); ++id) {
            uint256 amount = game.balanceOf(_account(ALICE_FRIEND), id);
            if (amount != 0) {
                vm.prank(ALICE);
                game.redeem(ALICE_FRIEND, id, amount);
                _assertBacking();
            }
            amount = game.balanceOf(_account(BOB_FRIEND), id);
            if (amount != 0) {
                vm.prank(BOB);
                game.redeem(BOB_FRIEND, id, amount);
                _assertBacking();
            }
        }
        assertEq(game.reservedPlays(), 0);
        assertEq(game.rewardLiability(), 0);
    }

    /// @dev One play still pending on one fresh request, with its reserve untouched.
    function _assertOnlyTheRequestChanged(uint256 batchId, uint64 expected) private view {
        (uint64 sequence, bool requested, bool fulfilled,) = game.randomness(batchId);
        assertEq(sequence, expected);
        assertTrue(requested);
        assertFalse(fulfilled);
        assertEq(game.pendingPlays(), 1);
        assertEq(game.reservedPlays(), 10 ether);
        assertEq(address(game).balance, 0);
    }

    function _retryAsWallet(uint256 batchId) private returns (uint64 sequence) {
        address wallet = _account(ALICE_FRIEND);
        vm.deal(wallet, 1 ether);
        uint256 walletETH = wallet.balance;
        sequence = abi.decode(
            _execute(
                ALICE,
                ALICE_FRIEND,
                address(game),
                dice.FEE(),
                abi.encodeCall(ChanceGame.retryRandomness, (batchId))
            ),
            (uint64)
        );
        assertEq(wallet.balance, walletETH);
    }

    function _assertBacking() private view {
        assertGe(rf.balanceOf(address(game)), game.reservedPlays() + game.rewardLiability());
        assertEq(
            game.reservedPlays(),
            (game.consumable().totalSupply() + game.pendingPlays()) * game.maxPrize()
        );
        uint256 rewards;
        for (uint256 id = 1; id <= game.outcomeCount(); ++id) {
            (, uint256 reward,) = game.outcomes(id);
            rewards += reward
                * (game.balanceOf(_account(ALICE_FRIEND), id)
                    + game.balanceOf(_account(BOB_FRIEND), id));
        }
        assertEq(game.rewardLiability(), rewards);
    }

    function _expectBuyFailure(uint256 friendId, uint256 quantity) private {
        vm.prank(_account(friendId));
        vm.expectRevert(ChanceGame.InsufficientStake.selector);
        game.buy(friendId, quantity);
    }

    function _buy(address owner, uint256 friendId, uint256 quantity) private {
        _execute(owner, friendId, address(game), abi.encodeCall(game.buy, (friendId, quantity)));
    }

    function _execute(address owner, uint256 friendId, address target, bytes memory data) private {
        _execute(owner, friendId, target, 0, data);
    }

    function _execute(address owner, uint256 friendId, address target, uint256 value, bytes memory data)
        private
        returns (bytes memory)
    {
        address account = _account(friendId);
        vm.prank(owner);
        return MockFriendWallet(payable(account)).execute(target, value, data, 0);
    }

    function _account(uint256 friendId) private view returns (address) {
        return generations.tokenBoundAccount(friendId);
    }

    function _fulfill(uint256 batchId, uint256 word) private {
        uint64 sequence = game.requestRandomness{ value: dice.FEE() }(batchId);
        dice.fulfill(sequence, bytes32(word));
    }

    function _outcome(uint256 word, uint256 batchId, uint256 playId)
        private
        view
        returns (uint256)
    {
        return game.outcomeForRoll(
            uint256(
                keccak256(abi.encode(bytes32(word), address(game), block.chainid, batchId, playId))
            ) % 10_000
        );
    }

    function _wordForOutcome(uint256 batchId, uint256 playId, uint256 outcomeId)
        private
        view
        returns (uint256 word)
    {
        while (_outcome(word, batchId, playId) != outcomeId) ++word;
    }

    function _deploy(ChanceGame.Outcome[] memory table) private returns (ChanceGame) {
        return new ChanceGame(
            address(rf),
            address(generations),
            address(dice),
            PROVIDER,
            "Bait",
            "BAIT",
            1 ether,
            table
        );
    }

    function _table() private pure returns (ChanceGame.Outcome[] memory table) {
        table = new ChanceGame.Outcome[](8);
        uint16[8] memory chances = [uint16(1500), 3000, 2200, 1400, 900, 500, 300, 200];
        uint256[8] memory rewards = [
            uint256(0), 0.25 ether, 0.5 ether, 0.75 ether, 1.5 ether, 2.5 ether, 5 ether, 10 ether
        ];
        for (uint256 i; i < 8; ++i) {
            table[i] = ChanceGame.Outcome(chances[i], rewards[i], "data:application/json,{}");
        }
    }
}
