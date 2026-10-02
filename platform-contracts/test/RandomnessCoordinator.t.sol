// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { RandomnessCoordinator } from "../src/RandomnessCoordinator.sol";
import { IDiceEntropy } from "../src/interfaces/IExternal.sol";
import { MockDice } from "./doubles/ExternalDoubles.sol";

/// @dev The two registry views the coordinator reads: owner and per-game module bindings.
contract StubRegistry {
    address public owner;
    mapping(uint256 gameId => mapping(address module => bool)) private _bound;

    constructor(address owner_) {
        owner = owner_;
    }

    function setBound(uint256 gameId, address module, bool value) external {
        _bound[gameId][module] = value;
    }

    function isBound(uint256 gameId, address module) external view returns (bool) {
        return _bound[gameId][module];
    }
}

contract RandomnessCoordinatorTest is Test {
    uint128 internal constant FEE = 25_000_000_000_000;
    uint256 internal constant GAME = 1;
    bytes32 internal constant ACTION = bytes32(uint256(7));
    bytes32 internal constant WORD = keccak256("word");

    address internal owner = makeAddr("owner");
    address internal module = makeAddr("module");
    address internal draining = makeAddr("draining");
    address internal stranger = makeAddr("stranger");
    address internal provider = makeAddr("provider");

    StubRegistry internal registry;
    MockDice internal dice;
    RandomnessCoordinator internal coord;

    function setUp() public {
        registry = new StubRegistry(owner);
        dice = new MockDice(provider);
        coord = new RandomnessCoordinator(address(registry), address(dice), provider);
        registry.setBound(GAME, module, true);
        registry.setBound(GAME, draining, true);
        vm.startPrank(owner);
        coord.setMaxFee(FEE);
        coord.setBudget(GAME, 1 ether);
        vm.stopPrank();
        vm.deal(address(this), 100 ether);
        (bool sent,) = address(coord).call{ value: 10 ether }("");
        assertTrue(sent);
    }

    function _request() internal returns (uint256 requestId) {
        vm.prank(module);
        requestId = coord.request(GAME, ACTION);
    }

    function _bindingKey(address module_, uint256 gameId, bytes32 actionKey)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(module_, gameId, actionKey));
    }

    function _callback(uint64 sequence, address provider_, bytes32 word_) internal {
        vm.prank(address(dice));
        coord._entropyCallback(sequence, provider_, word_);
    }

    /// @dev Dice reports `reported` (0 = cleared) with `status` when asked about `sequence`.
    function _mockDiceRequest(uint64 sequence, uint64 reported, uint8 status) internal {
        IDiceEntropy.Request memory req;
        if (reported != 0) req.provider = provider;
        req.sequenceNumber = reported;
        req.requester = address(coord);
        req.callbackStatus = status;
        req.feePaid = FEE;
        vm.mockCall(
            address(dice),
            abi.encodeCall(IDiceEntropy.getRequestV2, (provider, sequence)),
            abi.encode(req)
        );
    }

    // ----------------------------------------------------------------- construction and funding

    function testConstructorRejectsBadConfiguration() public {
        vm.expectRevert(RandomnessCoordinator.InvalidConfiguration.selector);
        new RandomnessCoordinator(stranger, address(dice), provider);
        vm.expectRevert(RandomnessCoordinator.InvalidConfiguration.selector);
        new RandomnessCoordinator(address(registry), stranger, provider);
        vm.expectRevert(RandomnessCoordinator.InvalidConfiguration.selector);
        new RandomnessCoordinator(address(registry), address(dice), address(0));
        assertEq(address(coord.registry()), address(registry));
        assertEq(address(coord.dice()), address(dice));
        assertEq(coord.provider(), provider);
        assertEq(coord.CALLBACK_GAS_LIMIT(), 200_000);
    }

    function testReceiveFromAnyone() public {
        vm.deal(stranger, 1 ether);
        uint256 before = address(coord).balance;
        vm.expectEmit(address(coord));
        emit RandomnessCoordinator.Deposited(stranger, 0.5 ether);
        vm.prank(stranger);
        (bool sent,) = address(coord).call{ value: 0.5 ether }("");
        assertTrue(sent);
        assertEq(address(coord).balance, before + 0.5 ether);
    }

    // ---------------------------------------------------------------------------------- request

    function testRequestOnlyByBoundModule() public {
        vm.expectRevert(RandomnessCoordinator.NotBoundModule.selector);
        vm.prank(stranger);
        coord.request(GAME, ACTION);
        // Bound for another game only.
        registry.setBound(2, stranger, true);
        vm.expectRevert(RandomnessCoordinator.NotBoundModule.selector);
        vm.prank(stranger);
        coord.request(GAME, ACTION);
    }

    function testRequestBindsPaysAndRecords() public {
        uint256 budgetBefore = coord.budget(GAME);
        uint256 balanceBefore = address(coord).balance;
        vm.expectEmit(address(coord));
        emit RandomnessCoordinator.Requested(1, GAME, module, ACTION, 1, FEE);
        uint256 id = _request();
        assertEq(id, 1);
        assertEq(coord.requestCount(), 1);
        (
            address m,
            uint256 g,
            bytes32 a,
            uint64 seq,
            uint32 attempt,
            RandomnessCoordinator.State state,
            bytes32 w
        ) = coord.requests(id);
        assertEq(m, module);
        assertEq(g, GAME);
        assertEq(a, ACTION);
        assertEq(seq, 1);
        assertEq(attempt, 0);
        assertEq(uint8(state), uint8(RandomnessCoordinator.State.Requested));
        assertEq(w, bytes32(0));
        assertEq(coord.requestOfSequence(1), id);
        assertEq(coord.boundRequest(_bindingKey(module, GAME, ACTION)), id);
        assertEq(coord.budget(GAME), budgetBefore - FEE);
        assertEq(address(coord).balance, balanceBefore - FEE);
        assertEq(address(dice).balance, FEE);
        MockDice.Request memory d = dice.getRequestV2(provider, 1);
        assertEq(d.requester, address(coord));
        assertEq(d.feePaid, FEE);
        assertEq(
            dice.userRandomness(1), keccak256(abi.encode(address(coord), block.chainid, id, 0))
        );
        (bool fulfilled, bytes32 value) = coord.word(id);
        assertFalse(fulfilled);
        assertEq(value, bytes32(0));
    }

    function testRequestAlreadyBound() public {
        _request();
        vm.expectRevert(RandomnessCoordinator.AlreadyBound.selector);
        _request();
        // The binding is per (module, game, action): other modules and games are independent.
        vm.prank(draining);
        assertEq(coord.request(GAME, ACTION), 2);
        registry.setBound(2, module, true);
        vm.prank(owner);
        coord.setBudget(2, FEE);
        vm.prank(module);
        assertEq(coord.request(2, ACTION), 3);
    }

    function testRequestFeeAboveCap() public {
        vm.prank(owner);
        coord.setMaxFee(FEE - 1);
        vm.expectRevert(RandomnessCoordinator.FeeAboveCap.selector);
        _request();
        vm.prank(owner);
        coord.setMaxFee(0);
        vm.expectRevert(RandomnessCoordinator.FeeAboveCap.selector);
        _request();
        assertEq(coord.boundRequest(_bindingKey(module, GAME, ACTION)), 0);
        assertEq(coord.requestCount(), 0);
    }

    function testRequestBudgetExceeded() public {
        vm.prank(owner);
        coord.setBudget(GAME, FEE - 1);
        vm.expectRevert(RandomnessCoordinator.BudgetExceeded.selector);
        _request();
        vm.prank(owner);
        coord.setBudget(GAME, 2 * FEE);
        _request();
        vm.prank(draining);
        coord.request(GAME, ACTION);
        assertEq(coord.budget(GAME), 0);
        vm.expectRevert(RandomnessCoordinator.BudgetExceeded.selector);
        vm.prank(module);
        coord.request(GAME, bytes32(uint256(8)));
    }

    function testRequestInsufficientBalance() public {
        vm.prank(owner);
        coord.withdraw(owner, address(coord).balance - FEE + 1);
        vm.expectRevert(RandomnessCoordinator.InsufficientBalance.selector);
        _request();
    }

    function testRequestSequenceReused() public {
        _request();
        vm.mockCall(
            address(dice), abi.encodeWithSelector(IDiceEntropy.requestV2.selector), abi.encode(1)
        );
        vm.expectRevert(RandomnessCoordinator.SequenceReused.selector);
        vm.prank(draining);
        coord.request(GAME, ACTION);
    }

    // --------------------------------------------------------------------------------- callback

    function testCallbackAuthenticatesSenderAndProvider() public {
        _request();
        vm.expectRevert(RandomnessCoordinator.UnauthorizedRandomness.selector);
        vm.prank(stranger);
        coord._entropyCallback(1, provider, WORD);
        vm.expectRevert(RandomnessCoordinator.UnauthorizedRandomness.selector);
        _callback(1, stranger, WORD);
        assertFalse(dice.deliverRaw(address(coord), 1, stranger, WORD));
        (bool fulfilled,) = coord.word(1);
        assertFalse(fulfilled);
    }

    function testCallbackRejectsUnknownAndDuplicateSequence() public {
        uint256 id = _request();
        vm.expectRevert(RandomnessCoordinator.InvalidRandomness.selector);
        _callback(99, provider, WORD);
        assertFalse(dice.deliverRaw(address(coord), 99, provider, WORD));
        vm.expectEmit(address(coord));
        emit RandomnessCoordinator.Fulfilled(id, 1, WORD);
        assertTrue(dice.reveal(1, WORD));
        (bool fulfilled, bytes32 value) = coord.word(id);
        assertTrue(fulfilled);
        assertEq(value, WORD);
        assertEq(coord.requestOfSequence(1), 0);
        // Replay of the same sequence is refused; the stored word never changes.
        vm.expectRevert(RandomnessCoordinator.InvalidRandomness.selector);
        _callback(1, provider, keccak256("other"));
        (, value) = coord.word(id);
        assertEq(value, WORD);
    }

    function testCallbackZeroWordIsValid() public {
        uint256 id = _request();
        assertTrue(dice.reveal(1, bytes32(0)));
        (bool fulfilled, bytes32 value) = coord.word(id);
        assertTrue(fulfilled);
        assertEq(value, bytes32(0));
        (,,,,, RandomnessCoordinator.State state,) = coord.requests(id);
        assertEq(uint8(state), uint8(RandomnessCoordinator.State.Fulfilled));
    }

    function testWordForUnknownRequest() public view {
        (bool fulfilled, bytes32 value) = coord.word(42);
        assertFalse(fulfilled);
        assertEq(value, bytes32(0));
    }

    // ------------------------------------------------------------------------------------ retry

    function testRetryRefusedBeforeDiceDelay() public {
        uint256 id = _request();
        vm.roll(block.number + dice.refundDelayBlocks() - 1);
        vm.expectRevert(MockDice.RefundNotAvailable.selector);
        coord.retry(id);
    }

    function testRetryRefusedWhenNotRequested() public {
        vm.expectRevert(RandomnessCoordinator.RetryUnavailable.selector);
        coord.retry(42);
        uint256 id = _request();
        dice.reveal(1, WORD);
        vm.roll(block.number + 10);
        vm.expectRevert(RandomnessCoordinator.RetryUnavailable.selector);
        coord.retry(id);
    }

    function testRetryRefusedForFailedAndInProgressCallbacks() public {
        uint256 id = _request();
        vm.roll(block.number + 10);
        _mockDiceRequest(1, 1, 3);
        vm.expectRevert(RandomnessCoordinator.RetryUnavailable.selector);
        coord.retry(id);
        _mockDiceRequest(1, 1, 2);
        vm.expectRevert(RandomnessCoordinator.RetryUnavailable.selector);
        coord.retry(id);
        vm.clearMockedCalls();
        // The request itself stays live and revealable.
        assertTrue(dice.reveal(1, WORD));
    }

    function testRetryRefusedForClearedRequest() public {
        uint256 id = _request();
        vm.roll(block.number + 10);
        _mockDiceRequest(1, 0, 0);
        vm.expectRevert(RandomnessCoordinator.RetryUnavailable.selector);
        coord.retry(id);
    }

    function testRetryRebindsAndReclaimsFee() public {
        uint256 id = _request();
        vm.prank(draining);
        coord.request(GAME, ACTION);
        uint256 budgetBefore = coord.budget(GAME);
        uint256 balanceBefore = address(coord).balance;
        bytes32 key = _bindingKey(module, GAME, ACTION);
        vm.roll(block.number + dice.refundDelayBlocks());
        vm.expectEmit(address(coord));
        emit RandomnessCoordinator.Retried(id, 1, 3, 1, FEE, FEE);
        vm.prank(stranger);
        coord.retry(id);
        // INV_RETRY_LEDGER_NEUTRAL: binding, module data, budget and balance are unchanged.
        assertEq(coord.boundRequest(key), id);
        (
            address m,
            uint256 g,
            bytes32 a,
            uint64 seq,
            uint32 attempt,
            RandomnessCoordinator.State state,
        ) = coord.requests(id);
        assertEq(m, module);
        assertEq(g, GAME);
        assertEq(a, ACTION);
        assertEq(seq, 3);
        assertEq(attempt, 1);
        assertEq(uint8(state), uint8(RandomnessCoordinator.State.Requested));
        assertEq(coord.budget(GAME), budgetBefore);
        assertEq(address(coord).balance, balanceBefore);
        assertEq(coord.requestCount(), 2);
        assertEq(coord.requestOfSequence(1), 0);
        assertEq(coord.requestOfSequence(3), id);
        assertEq(dice.getRequestV2(provider, 1).sequenceNumber, 0);
        assertEq(
            dice.userRandomness(3), keccak256(abi.encode(address(coord), block.chainid, id, 1))
        );
        // A late callback for the stale sequence is rejected; the new one fulfils.
        vm.expectRevert(RandomnessCoordinator.InvalidRandomness.selector);
        _callback(1, provider, WORD);
        assertTrue(dice.reveal(3, WORD));
        (bool fulfilled, bytes32 value) = coord.word(id);
        assertTrue(fulfilled);
        assertEq(value, WORD);
        // The request cannot be retried once fulfilled and the other request is untouched.
        vm.expectRevert(RandomnessCoordinator.RetryUnavailable.selector);
        coord.retry(id);
        assertEq(coord.requestOfSequence(2), 2);
    }

    function testRetryChargesNewFeeAgainstReclaimedBudget() public {
        uint256 id = _request();
        vm.prank(owner);
        coord.setBudget(GAME, 0);
        vm.roll(block.number + dice.refundDelayBlocks());
        // A higher fee than the reclaimed one exceeds a zero budget and the refund rolls back.
        dice.setFee(FEE + 1);
        vm.prank(owner);
        coord.setMaxFee(FEE + 1);
        vm.expectRevert(RandomnessCoordinator.BudgetExceeded.selector);
        coord.retry(id);
        assertEq(dice.getRequestV2(provider, 1).sequenceNumber, 1);
        // Above the cap the retry is refused as well.
        vm.prank(owner);
        coord.setMaxFee(FEE);
        vm.expectRevert(RandomnessCoordinator.FeeAboveCap.selector);
        coord.retry(id);
        // A lower fee leaves the difference in the game's budget.
        dice.setFee(FEE - 1);
        vm.expectEmit(address(coord));
        emit RandomnessCoordinator.Retried(id, 1, 2, 1, FEE, FEE - 1);
        coord.retry(id);
        assertEq(coord.budget(GAME), 1);
        assertEq(coord.requestOfSequence(2), id);
    }

    // ---------------------------------------------------------------------------- owner surface

    function testSettersOwnerOnly() public {
        vm.expectRevert(RandomnessCoordinator.NotRegistryOwner.selector);
        vm.prank(stranger);
        coord.setMaxFee(1);
        vm.expectRevert(RandomnessCoordinator.NotRegistryOwner.selector);
        vm.prank(stranger);
        coord.setBudget(GAME, 1);
        vm.expectRevert(RandomnessCoordinator.NotRegistryOwner.selector);
        vm.prank(stranger);
        coord.withdraw(stranger, 1);
        vm.startPrank(owner);
        vm.expectEmit(address(coord));
        emit RandomnessCoordinator.MaxFeeSet(1);
        coord.setMaxFee(1);
        assertEq(coord.maxFee(), 1);
        vm.expectEmit(address(coord));
        emit RandomnessCoordinator.BudgetSet(GAME, 5);
        coord.setBudget(GAME, 5);
        assertEq(coord.budget(GAME), 5);
        vm.stopPrank();
    }

    function testWithdrawPlatformEth() public {
        vm.startPrank(owner);
        vm.expectRevert(RandomnessCoordinator.InvalidConfiguration.selector);
        coord.withdraw(address(0), 1);
        vm.expectRevert(RandomnessCoordinator.TransferFailed.selector);
        coord.withdraw(stranger, address(coord).balance + 1);
        // A recipient without a receive function fails the plain call.
        vm.expectRevert(RandomnessCoordinator.TransferFailed.selector);
        coord.withdraw(address(registry), 1);
        vm.expectEmit(address(coord));
        emit RandomnessCoordinator.Withdrawn(stranger, 1 ether);
        coord.withdraw(stranger, 1 ether);
        vm.stopPrank();
        assertEq(stranger.balance, 1 ether);
        assertEq(address(coord).balance, 9 ether);
    }
}
