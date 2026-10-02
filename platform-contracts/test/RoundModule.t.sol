// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { RoundModule } from "../src/RoundModule.sol";
import { IRareFriends } from "../src/interfaces/IExternal.sol";
import { IGameRegistry } from "../src/interfaces/IGameRegistry.sol";
import { IRandomnessCoordinator } from "../src/interfaces/IRandomnessCoordinator.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { FriendAccess } from "../src/libraries/FriendAccess.sol";
import { MockFriendWallet, MockGenerations, MockRF, MockUSDG } from "./doubles/ExternalDoubles.sol";

/// @dev Registry views with settable records; the real GameRegistry is tested separately.
contract StubRegistry is IGameRegistry {
    address public owner;
    address public generations;
    address public rf;
    address public usdg;
    address public custody;
    address public custodyExecutor;
    mapping(uint256 => Game) private _games;
    mapping(uint256 => bool) public isActive;
    mapping(bytes32 => bool) public custodyActionUsed;

    constructor(address owner_, address generations_, address rf_, address usdg_) {
        owner = owner_;
        generations = generations_;
        rf = rf_;
        usdg = usdg_;
    }

    function setGame(uint256 gameId, address module, address currency, address settler) external {
        _games[gameId].module = module;
        _games[gameId].currency = currency;
        _games[gameId].settler = settler;
        _games[gameId].status = Status.Active;
        isActive[gameId] = true;
    }

    function setActive(uint256 gameId, bool active) external {
        isActive[gameId] = active;
    }

    function setModule(uint256 gameId, address module) external {
        _games[gameId].module = module;
    }

    function setSettler(uint256 gameId, address settler) external {
        _games[gameId].settler = settler;
    }

    function game(uint256 gameId) external view returns (Game memory) {
        return _games[gameId];
    }

    function currentModule(uint256 gameId) external view returns (address) {
        return _games[gameId].module;
    }

    function isBound(uint256 gameId, address module) external view returns (bool) {
        return _games[gameId].module == module;
    }

    function canCommit(uint256 gameId, address module) external view returns (bool) {
        return isActive[gameId] && _games[gameId].module == module;
    }

    function currencyOf(uint256 gameId) external view returns (address) {
        return _games[gameId].currency;
    }

    function itemsOf(uint256 gameId) external view returns (address) {
        return _games[gameId].items;
    }

    function settlerOf(uint256 gameId) external view returns (address) {
        return _games[gameId].settler;
    }

    function recipientsOf(uint256 gameId) external view returns (address, address, address) {
        Game storage g = _games[gameId];
        return (g.funder, g.developer, g.operator);
    }

    function consumeCustodyAction(bytes32 actionId, uint256) external {
        custodyActionUsed[actionId] = true;
    }
}

/// @dev Treasury ledger arithmetic from SPEC section 4.2, with real RF movement and burns.
contract StubTreasury is ITreasury {
    using SafeERC20 for IERC20;

    struct Ledger {
        uint256 free;
        uint256 reserved;
        uint256 owed;
        uint256 credit;
    }

    IRareFriends public immutable rf;
    mapping(uint256 => Ledger) private _ledgers;
    mapping(uint256 => mapping(uint256 => uint256)) public creditOf;
    uint256 public burnedTotal;
    uint256 public rewardsPending;
    address public lastPayer;
    uint256 public resolveCalls;

    error UnbalancedSpend();

    constructor(IRareFriends rf_) {
        rf = rf_;
    }

    function collect(uint256 gameId, address payer, Legs calldata l) external {
        uint256 total = l.toFree + l.toReserved + l.developer + l.operator + l.burn + l.rewards;
        IERC20(address(rf)).safeTransferFrom(payer, address(this), total);
        _ledgers[gameId].free += l.toFree;
        _ledgers[gameId].reserved += l.toReserved;
        if (l.burn != 0) rf.burn(l.burn);
        burnedTotal += l.burn;
        rewardsPending += l.rewards;
        lastPayer = payer;
    }

    function reserve(uint256 gameId, uint256 amount) external {
        _ledgers[gameId].free -= amount;
        _ledgers[gameId].reserved += amount;
    }

    function release(uint256 gameId, uint256 amount) external {
        _ledgers[gameId].reserved -= amount;
        _ledgers[gameId].free += amount;
    }

    function resolve(
        uint256 gameId,
        uint256 amount,
        uint256 toOwed,
        uint256 toKeep,
        address payTo,
        uint256 pay
    ) external {
        Ledger storage l = _ledgers[gameId];
        l.reserved = l.reserved - amount + toKeep;
        l.free += amount - toOwed - toKeep - pay;
        l.owed += toOwed;
        ++resolveCalls;
        if (pay != 0) IERC20(address(rf)).safeTransfer(payTo, pay);
    }

    function routeReserved(uint256 gameId, uint256 burned, uint256 rewards) external {
        _ledgers[gameId].reserved -= burned + rewards;
        if (burned != 0) rf.burn(burned);
        burnedTotal += burned;
        rewardsPending += rewards;
    }

    function payOwed(uint256 gameId, address to, uint256 amount) external {
        _ledgers[gameId].owed -= amount;
        IERC20(address(rf)).safeTransfer(to, amount);
    }

    function creditDeposit(uint256 gameId, uint256 friendId, address payer, uint256 amount)
        external
    {
        IERC20(address(rf)).safeTransferFrom(payer, address(this), amount);
        creditOf[gameId][friendId] += amount;
        _ledgers[gameId].credit += amount;
        lastPayer = payer;
    }

    function creditWithdraw(uint256 gameId, uint256 friendId, address to, uint256 amount) external {
        creditOf[gameId][friendId] -= amount;
        _ledgers[gameId].credit -= amount;
        IERC20(address(rf)).safeTransfer(to, amount);
    }

    function creditSpend(
        uint256 gameId,
        uint256 friendId,
        uint256 amount,
        uint256 burned,
        uint256 rewards
    ) external {
        if (burned + rewards != amount) revert UnbalancedSpend();
        creditOf[gameId][friendId] -= amount;
        _ledgers[gameId].credit -= amount;
        if (burned != 0) rf.burn(burned);
        burnedTotal += burned;
        rewardsPending += rewards;
    }

    function ledgers(uint256 gameId)
        external
        view
        returns (uint256 free, uint256 reserved, uint256 owed, uint256 credit)
    {
        Ledger storage l = _ledgers[gameId];
        return (l.free, l.reserved, l.owed, l.credit);
    }
}

/// @dev Coordinator that hands out request ids and lets the test reveal words directly.
contract StubCoordinator is IRandomnessCoordinator {
    struct Req {
        address module;
        uint256 gameId;
        bytes32 actionKey;
        bool fulfilled;
        bytes32 value;
    }

    uint256 public requestCount;
    mapping(uint256 => Req) public requests;

    function request(uint256 gameId, bytes32 actionKey) external returns (uint256 requestId) {
        requestId = ++requestCount;
        requests[requestId] = Req(msg.sender, gameId, actionKey, false, 0);
    }

    function fulfill(uint256 requestId, bytes32 value) external {
        requests[requestId].fulfilled = true;
        requests[requestId].value = value;
    }

    function word(uint256 requestId) external view returns (bool, bytes32) {
        return (requests[requestId].fulfilled, requests[requestId].value);
    }

    function retry(uint256) external { }
}

contract RoundModuleTest is Test {
    uint256 internal constant GAME = 3;
    uint256 internal constant UNSEALED_GAME = 4;
    uint256 internal constant USDG_GAME = 5;
    uint256 internal constant FRIENDS = 51;
    uint256 internal constant ENTRY = 1e18;
    address internal constant OWNER = address(0xA11CE);
    address internal constant SETTLER = address(0x5E77);
    bytes32 internal constant SECRET = keccak256("royale-secret");
    bytes32 internal constant WORD = keccak256("dice-word");

    MockRF internal rf;
    MockUSDG internal usdg;
    MockGenerations internal gens;
    StubRegistry internal registry;
    StubTreasury internal treasury;
    StubCoordinator internal coordinator;
    RoundModule internal module;
    bytes32 internal secretHash;

    function setUp() public {
        rf = new MockRF();
        usdg = new MockUSDG(6);
        gens = new MockGenerations(address(rf));
        rf.setGenerations(gens);
        registry = new StubRegistry(OWNER, address(gens), address(rf), address(usdg));
        treasury = new StubTreasury(IRareFriends(address(rf)));
        coordinator = new StubCoordinator();
        module = new RoundModule(
            address(registry), address(treasury), address(coordinator), address(gens)
        );
        registry.setGame(GAME, address(module), address(rf), SETTLER);
        registry.setGame(UNSEALED_GAME, address(module), address(rf), SETTLER);
        registry.setGame(USDG_GAME, address(module), address(usdg), SETTLER);
        vm.prank(OWNER);
        module.defineTerms(GAME, _terms(), _prices());
        vm.prank(address(registry));
        module.seal(GAME);
        secretHash = keccak256(abi.encode(SECRET));
        for (uint256 id = 1; id <= FRIENDS; ++id) {
            address owner = _ownerOf(id);
            gens.mint(owner, id, 3);
            rf.mint(owner, 100e18);
            vm.prank(owner);
            rf.approve(address(treasury), type(uint256).max);
        }
    }

    // ---- helpers ----

    function _terms() internal pure returns (RoundModule.Terms memory) {
        return RoundModule.Terms(1e18, 8000, 1000, 1000, 5000, 5000, 5, 50);
    }

    function _prices() internal pure returns (uint128[] memory p) {
        p = new uint128[](13);
        p[0] = 1e18;
        p[1] = 1e18;
        p[2] = 2e18;
        p[3] = 4e18;
        p[4] = 8e18;
        p[5] = 1e18;
        p[6] = 1e18;
        p[7] = 2e18;
        p[8] = 2e18;
        p[9] = 5e18;
        p[10] = 1e18;
        p[11] = 3e18;
        p[12] = 5e18;
    }

    function _ownerOf(uint256 friendId) internal pure returns (address) {
        return vm.addr(0xF000 + friendId);
    }

    function _wallet(uint256 friendId) internal view returns (address) {
        return gens.tokenBoundAccount(friendId);
    }

    function _open() internal returns (uint256 roundId) {
        vm.prank(SETTLER);
        roundId = module.openRound(GAME, secretHash);
    }

    function _enter(uint256 roundId, uint256 friendId) internal {
        vm.prank(_ownerOf(friendId));
        module.enter(roundId, friendId);
    }

    function _fill(uint256 roundId, uint256 count) internal {
        for (uint256 id = 1; id <= count; ++id) {
            _enter(roundId, id);
        }
    }

    function _close(uint256 roundId) internal {
        vm.prank(SETTLER);
        module.closeRound(roundId);
    }

    function _closeAndFulfill(uint256 roundId) internal returns (uint256 requestId) {
        _close(roundId);
        (,,,, requestId) = module.rounds(roundId);
        coordinator.fulfill(requestId, WORD);
    }

    /// @dev Ten payouts summing to the 9.6 RF pot of a twelve-entry round.
    function _payouts() internal pure returns (uint256[] memory ids, uint256[] memory amounts) {
        ids = new uint256[](10);
        amounts = new uint256[](10);
        uint256[10] memory ladder =
            [uint256(3e18), 2e18, 1e18, 1e18, 0.6e18, 0.5e18, 0.5e18, 0.5e18, 0.3e18, 0.2e18];
        for (uint256 i; i < 10; ++i) {
            ids[i] = i + 1;
            amounts[i] = ladder[i];
        }
    }

    function _settle(uint256 roundId, uint256[] memory ids, uint256[] memory amounts) internal {
        vm.prank(SETTLER);
        module.settleRound(roundId, SECRET, ids, amounts);
    }

    function _status(uint256 roundId) internal view returns (RoundModule.Status status) {
        (,,, status,) = module.rounds(roundId);
    }

    function _reserved() internal view returns (uint256 reserved) {
        (, reserved,,) = treasury.ledgers(GAME);
    }

    // ---- terms ----

    function testLineageAndHash() public view {
        assertEq(module.LINEAGE(), keccak256("Round"));
        assertEq(module.termsHash(GAME), keccak256(abi.encode(_terms(), _prices())));
        assertEq(module.termsHash(UNSEALED_GAME), bytes32(0));
        assertTrue(module.isSealed(GAME));
        assertEq(module.kindPrices(GAME).length, 13);
        assertEq(module.kindPrices(GAME)[4], 8e18);
    }

    function testDefineTermsOnlyRegistryOwner() public {
        vm.expectRevert(RoundModule.NotRegistryOwner.selector);
        module.defineTerms(UNSEALED_GAME, _terms(), _prices());
    }

    function testDefineTermsEmitsAndStores() public {
        vm.expectEmit(true, false, false, true);
        emit RoundModule.TermsDefined(UNSEALED_GAME, _terms(), _prices());
        vm.prank(OWNER);
        module.defineTerms(UNSEALED_GAME, _terms(), _prices());
        (uint128 entryPrice,,,,,, uint16 minEntries, uint16 maxEntries) =
            module.terms(UNSEALED_GAME);
        assertEq(entryPrice, ENTRY);
        assertEq(minEntries, 5);
        assertEq(maxEntries, 50);
        assertFalse(module.isSealed(UNSEALED_GAME));
        assertEq(module.termsHash(UNSEALED_GAME), bytes32(0));
    }

    function testDefineTermsRejectsInvalidTerms() public {
        RoundModule.Terms memory t = _terms();
        uint128[] memory p = _prices();
        vm.startPrank(OWNER);
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(USDG_GAME, t, p);
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(99, t, p);
        t.entryPrice = 0;
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, t, p);
        t = _terms();
        t.potBps = 7999;
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, t, p);
        t = _terms();
        t.spendBurnBps = 5001;
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, t, p);
        t = _terms();
        t.minEntries = 0;
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, t, p);
        t = _terms();
        t.minEntries = 51;
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, t, p);
        t = _terms();
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, t, new uint128[](0));
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, t, new uint128[](33));
        p[6] = 0;
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, t, p);
        vm.stopPrank();
    }

    function testDefineTermsOnceAndNeverAfterSeal() public {
        vm.prank(OWNER);
        vm.expectRevert(RoundModule.Sealed.selector);
        module.defineTerms(GAME, _terms(), _prices());
        vm.startPrank(OWNER);
        module.defineTerms(UNSEALED_GAME, _terms(), _prices());
        vm.expectRevert(RoundModule.InvalidTerms.selector);
        module.defineTerms(UNSEALED_GAME, _terms(), _prices());
        vm.stopPrank();
    }

    function testSealRules() public {
        vm.expectRevert(RoundModule.OnlyRegistry.selector);
        module.seal(UNSEALED_GAME);
        vm.prank(address(registry));
        vm.expectRevert(RoundModule.NoTerms.selector);
        module.seal(UNSEALED_GAME);
        vm.prank(OWNER);
        module.defineTerms(UNSEALED_GAME, _terms(), _prices());
        bytes32 expected = keccak256(abi.encode(_terms(), _prices()));
        vm.expectEmit(true, false, false, true);
        emit RoundModule.TermsSealed(UNSEALED_GAME, expected);
        vm.prank(address(registry));
        assertEq(module.seal(UNSEALED_GAME), expected);
        // Idempotent and silent once sealed.
        vm.recordLogs();
        vm.prank(address(registry));
        assertEq(module.seal(UNSEALED_GAME), expected);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(module.termsHash(UNSEALED_GAME), expected);
    }

    // ---- open and enter ----

    function testOpenRoundRules() public {
        vm.expectRevert(RoundModule.OnlySettler.selector);
        module.openRound(GAME, secretHash);
        vm.startPrank(SETTLER);
        vm.expectRevert(RoundModule.BadSecret.selector);
        module.openRound(GAME, bytes32(0));
        vm.stopPrank();
        registry.setActive(GAME, false);
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.GameNotActive.selector);
        module.openRound(GAME, secretHash);
        registry.setActive(GAME, true);
        registry.setModule(GAME, address(0xBEEF));
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.NotCurrentModule.selector);
        module.openRound(GAME, secretHash);
        registry.setModule(GAME, address(module));
        vm.warp(1_700_000_000);
        vm.expectEmit(true, true, false, true);
        emit RoundModule.RoundOpened(1, GAME, secretHash, 1_700_000_000);
        uint256 roundId = _open();
        assertEq(roundId, 1);
        (uint256 gameId, bytes32 hash, uint64 openedAt, RoundModule.Status status, uint256 req) =
            module.rounds(1);
        assertEq(gameId, GAME);
        assertEq(hash, secretHash);
        assertEq(openedAt, 1_700_000_000);
        assertEq(uint8(status), uint8(RoundModule.Status.Open));
        assertEq(req, 0);
        // Several rounds may be open at once.
        assertEq(_open(), 2);
    }

    function testEnterReservesWholeEntryAndRoutesNothing() public {
        uint256 roundId = _open();
        uint256 before = rf.balanceOf(_ownerOf(1));
        vm.expectEmit(true, true, true, true);
        emit RoundModule.Entered(roundId, 1, _wallet(1), _ownerOf(1), 1);
        _enter(roundId, 1);
        assertEq(rf.balanceOf(_ownerOf(1)), before - ENTRY);
        assertEq(treasury.lastPayer(), _ownerOf(1));
        (uint256 free, uint256 reserved,,) = treasury.ledgers(GAME);
        assertEq(free, 0);
        assertEq(reserved, ENTRY);
        assertEq(treasury.burnedTotal(), 0);
        assertEq(treasury.rewardsPending(), 0);
        assertEq(module.roundOf(GAME, 1), roundId);
        assertEq(module.entrants(roundId).length, 1);
        assertEq(module.entrants(roundId)[0], 1);
        assertEq(module.potOf(roundId), 0.8e18);
    }

    function testEnterFromCanonicalWallet() public {
        uint256 roundId = _open();
        MockFriendWallet wallet = MockFriendWallet(payable(_wallet(2)));
        rf.mint(address(wallet), ENTRY);
        vm.startPrank(_ownerOf(2));
        wallet.execute(
            address(rf), 0, abi.encodeCall(IERC20.approve, (address(treasury), ENTRY)), 0
        );
        wallet.execute(address(module), 0, abi.encodeCall(RoundModule.enter, (roundId, 2)), 0);
        vm.stopPrank();
        assertEq(treasury.lastPayer(), address(wallet));
        assertEq(rf.balanceOf(address(wallet)), 0);
        assertEq(module.roundOf(GAME, 2), roundId);
    }

    function testEnterRules() public {
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.WrongStatus.selector);
        module.enter(7, 1);
        uint256 roundId = _open();
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        module.enter(roundId, 1);
        gens.mint(_ownerOf(1), 900, 0);
        vm.prank(_ownerOf(1));
        vm.expectRevert(FriendAccess.InvalidFriend.selector);
        module.enter(roundId, 900);
        registry.setActive(GAME, false);
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.GameNotActive.selector);
        module.enter(roundId, 1);
        registry.setActive(GAME, true);
        _enter(roundId, 1);
        // Double entry is the one-live-round rule.
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        module.enter(roundId, 1);
    }

    function testRoundFull() public {
        uint256 roundId = _open();
        _fill(roundId, 50);
        assertEq(module.entrants(roundId).length, 50);
        assertEq(module.potOf(roundId), 40e18);
        vm.prank(_ownerOf(51));
        vm.expectRevert(RoundModule.RoundFull.selector);
        module.enter(roundId, 51);
    }

    function testOneUnsettledRoundPerFriend() public {
        uint256 first = _open();
        uint256 second = _open();
        _fill(first, 12);
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        module.enter(second, 1);
        _closeAndFulfill(first);
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        module.enter(second, 1);
        (uint256[] memory ids, uint256[] memory amounts) = _payouts();
        _settle(first, ids, amounts);
        _enter(second, 1);
        assertEq(module.roundOf(GAME, 1), second);
    }

    function testEnterAllowedAfterRefundAndAfterAbandon() public {
        uint256 refunded = _open();
        _fill(refunded, 3);
        _close(refunded);
        uint256 next = _open();
        _enter(next, 1);
        vm.warp(block.timestamp + 1 days);
        module.abandonRound(next);
        uint256 last = _open();
        _enter(last, 1);
        assertEq(module.roundOf(GAME, 1), last);
    }

    // ---- close and settle ----

    function testCloseRequestsOneWordBoundToTheRound() public {
        uint256 roundId = _open();
        _fill(roundId, 12);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        module.closeRound(roundId);
        vm.expectEmit(true, false, false, true);
        emit RoundModule.RoundClosed(roundId, 12, 9.6e18, 1);
        _close(roundId);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Closed));
        (address m, uint256 gameId, bytes32 key,,) = coordinator.requests(1);
        assertEq(m, address(module));
        assertEq(gameId, GAME);
        assertEq(key, bytes32(roundId));
        assertEq(_reserved(), 12e18);
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        module.closeRound(roundId);
        vm.prank(_ownerOf(13));
        vm.expectRevert(RoundModule.WrongStatus.selector);
        module.enter(roundId, 13);
    }

    function testSettleExactPotArithmetic() public {
        uint256 roundId = _open();
        _fill(roundId, 12);
        _closeAndFulfill(roundId);
        (uint256[] memory ids, uint256[] memory amounts) = _payouts();
        uint256 supplyBefore = rf.totalSupply();
        uint256[] memory walletBefore = new uint256[](12);
        for (uint256 i; i < 12; ++i) {
            walletBefore[i] = rf.balanceOf(_wallet(i + 1));
        }
        vm.expectEmit(true, false, false, true);
        emit RoundModule.RoundSettled(roundId, WORD, SECRET, ids, amounts);
        _settle(roundId, ids, amounts);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Settled));
        assertEq(treasury.burnedTotal(), 1.2e18);
        assertEq(treasury.rewardsPending(), 1.2e18);
        assertEq(rf.totalSupply(), supplyBefore - 1.2e18);
        (uint256 free, uint256 reserved, uint256 owed,) = treasury.ledgers(GAME);
        assertEq(free, 0);
        assertEq(reserved, 0);
        assertEq(owed, 0);
        assertEq(treasury.resolveCalls(), 10);
        uint256 paid;
        for (uint256 i; i < 12; ++i) {
            uint256 got = rf.balanceOf(_wallet(i + 1)) - walletBefore[i];
            assertEq(got, i < 10 ? amounts[i] : 0);
            paid += got;
        }
        assertEq(paid, 9.6e18);
        assertEq(rf.balanceOf(address(treasury)), 1.2e18);
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
    }

    function testSettleAllowsDuplicateRecipients() public {
        uint256 roundId = _open();
        _fill(roundId, 12);
        _closeAndFulfill(roundId);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 4;
        ids[1] = 4;
        amounts[0] = 9e18;
        amounts[1] = 0.6e18;
        uint256 before = rf.balanceOf(_wallet(4));
        _settle(roundId, ids, amounts);
        assertEq(rf.balanceOf(_wallet(4)), before + 9.6e18);
    }

    function testPotMismatchAtOneWei() public {
        uint256 roundId = _open();
        _fill(roundId, 12);
        _closeAndFulfill(roundId);
        (uint256[] memory ids, uint256[] memory amounts) = _payouts();
        amounts[9] += 1;
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.PotMismatch.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        amounts[9] -= 2;
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.PotMismatch.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        amounts[9] += 1;
        _settle(roundId, ids, amounts);
    }

    function testSettleRejectsBadInputs() public {
        uint256 roundId = _open();
        _fill(roundId, 12);
        (uint256[] memory ids, uint256[] memory amounts) = _payouts();
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        _close(roundId);
        uint256 requestId = coordinator.requestCount();
        vm.expectRevert(RoundModule.OnlySettler.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        vm.startPrank(SETTLER);
        vm.expectRevert(RoundModule.BadSecret.selector);
        module.settleRound(roundId, keccak256("wrong"), ids, amounts);
        vm.expectRevert(RoundModule.RandomnessPending.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        vm.stopPrank();
        coordinator.fulfill(requestId, WORD);
        vm.startPrank(SETTLER);
        vm.expectRevert(RoundModule.LengthMismatch.selector);
        module.settleRound(roundId, SECRET, ids, new uint256[](9));
        vm.expectRevert(RoundModule.LengthMismatch.selector);
        module.settleRound(roundId, SECRET, new uint256[](0), new uint256[](0));
        ids[3] = 13;
        vm.expectRevert(RoundModule.NotEntrant.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        ids[3] = 4;
        amounts[0] += amounts[9];
        amounts[9] = 0;
        vm.expectRevert(RoundModule.ZeroAmount.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        vm.stopPrank();
        assertEq(_reserved(), 12e18);
    }

    // ---- refund and abandonment ----

    function _assertRefundedWhole(uint256 roundId, uint256 count, uint256[] memory before)
        internal
        view
    {
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Refunded));
        for (uint256 i; i < count; ++i) {
            assertEq(rf.balanceOf(_wallet(i + 1)), before[i] + ENTRY);
        }
        assertEq(_reserved(), 0);
        assertEq(treasury.burnedTotal(), 0);
        assertEq(treasury.rewardsPending(), 0);
        assertEq(treasury.resolveCalls(), count);
    }

    function _walletBalances(uint256 count) internal view returns (uint256[] memory before) {
        before = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            before[i] = rf.balanceOf(_wallet(i + 1));
        }
    }

    function testCloseBelowMinEntriesRefundsEveryEntry() public {
        uint256 roundId = _open();
        _fill(roundId, 4);
        assertEq(_reserved(), 4e18);
        uint256[] memory before = _walletBalances(4);
        vm.recordLogs();
        vm.expectEmit(true, false, false, true);
        emit RoundModule.RoundRefunded(roundId, 4, false);
        _close(roundId);
        _assertRefundedWhole(roundId, 4, before);
        assertEq(coordinator.requestCount(), 0);
        (,,,, uint256 requestId) = module.rounds(roundId);
        assertEq(requestId, 0);
        // No RoundClosed alongside the refund.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != RoundModule.RoundClosed.selector);
        }
    }

    function testCloseEmptyRoundRefundsNothing() public {
        uint256 roundId = _open();
        _close(roundId);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Refunded));
        assertEq(treasury.resolveCalls(), 0);
    }

    function testAbandonRefusesBeforeTheClock() public {
        uint256 open = _open();
        _fill(open, 2);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        module.abandonRound(open);
        uint256 closed = _open();
        _enter(closed, 3);
        _enter(closed, 4);
        _enter(closed, 5);
        _enter(closed, 6);
        _enter(closed, 7);
        _close(closed);
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        module.abandonRound(closed);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        module.abandonRound(open);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        module.abandonRound(42);
    }

    function testAbandonRefundsWholeFromOpen() public {
        uint256 roundId = _open();
        _fill(roundId, 7);
        uint256[] memory before = _walletBalances(7);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, true);
        emit RoundModule.RoundRefunded(roundId, 7, true);
        vm.prank(address(0xDEAD));
        module.abandonRound(roundId);
        _assertRefundedWhole(roundId, 7, before);
    }

    function testAbandonRefundsWholeFromClosedAndNeverReadsTheWord() public {
        uint256 roundId = _open();
        _fill(roundId, 12);
        uint256 requestId = _closeAndFulfill(roundId);
        // Spent credit stays spent.
        vm.prank(_ownerOf(1));
        module.depositCredit(GAME, 1, 3e18);
        vm.prank(SETTLER);
        module.spend(roundId, 1, 2, 3);
        uint256[] memory before = _walletBalances(12);
        vm.warp(block.timestamp + 1 days);
        module.abandonRound(roundId);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Refunded));
        for (uint256 i; i < 12; ++i) {
            assertEq(rf.balanceOf(_wallet(i + 1)), before[i] + ENTRY);
        }
        assertEq(_reserved(), 0);
        assertEq(treasury.burnedTotal(), 1e18);
        assertEq(treasury.rewardsPending(), 1e18);
        assertEq(treasury.creditOf(GAME, 1), 1e18);
        (bool fulfilled,) = coordinator.word(requestId);
        assertTrue(fulfilled);
        (uint256[] memory ids, uint256[] memory amounts) = _payouts();
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        module.abandonRound(roundId);
    }

    function testAbandonRefusesSettledRound() public {
        uint256 roundId = _open();
        _fill(roundId, 12);
        _closeAndFulfill(roundId);
        (uint256[] memory ids, uint256[] memory amounts) = _payouts();
        _settle(roundId, ids, amounts);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(RoundModule.NotAbandonable.selector);
        module.abandonRound(roundId);
    }

    // ---- spend ----

    function testSpendDebitsCreditHalfBurnHalfRewards() public {
        uint256 roundId = _open();
        _fill(roundId, 5);
        vm.prank(_ownerOf(1));
        module.depositCredit(GAME, 1, 10e18);
        assertEq(treasury.creditOf(GAME, 1), 10e18);
        assertEq(treasury.lastPayer(), _ownerOf(1));
        uint256 supply = rf.totalSupply();
        vm.expectEmit(true, true, true, true);
        emit RoundModule.Spent(roundId, 1, 77, 3, 2e18);
        vm.prank(SETTLER);
        module.spend(roundId, 1, 77, 3);
        assertEq(treasury.creditOf(GAME, 1), 8e18);
        assertEq(treasury.burnedTotal(), 1e18);
        assertEq(treasury.rewardsPending(), 1e18);
        assertEq(rf.totalSupply(), supply - 1e18);
        (uint256 free, uint256 reserved, uint256 owed, uint256 credit) = treasury.ledgers(GAME);
        assertEq(free, 0);
        assertEq(reserved, 5e18);
        assertEq(owed, 0);
        assertEq(credit, 8e18);
        // Works while Closed too; kind 13 is the last term-listed kind.
        _close(roundId);
        vm.prank(SETTLER);
        module.spend(roundId, 1, 1, 13);
        assertEq(treasury.creditOf(GAME, 1), 3e18);
    }

    function testSpendRules() public {
        uint256 roundId = _open();
        _fill(roundId, 5);
        vm.prank(_ownerOf(1));
        module.depositCredit(GAME, 1, 10e18);
        vm.prank(_ownerOf(6));
        module.depositCredit(GAME, 6, 10e18);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        module.spend(roundId, 1, 1, 1);
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.OnlySettler.selector);
        module.spend(roundId, 1, 1, 1);
        vm.startPrank(SETTLER);
        vm.expectRevert(RoundModule.NotEntrant.selector);
        module.spend(roundId, 6, 1, 1);
        vm.expectRevert(RoundModule.UnknownKind.selector);
        module.spend(roundId, 1, 1, 0);
        vm.expectRevert(RoundModule.UnknownKind.selector);
        module.spend(roundId, 1, 1, 14);
        vm.stopPrank();
        // An unknown round has no settler, so nobody passes the settler check.
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        module.spend(99, 1, 1, 1);
        // Insufficient credit reverts in the Treasury ledger: 8 RF spent leaves 2 RF.
        vm.prank(SETTLER);
        module.spend(roundId, 1, 1, 5);
        vm.prank(SETTLER);
        vm.expectRevert();
        module.spend(roundId, 1, 1, 10);
        vm.prank(SETTLER);
        module.spend(roundId, 1, 1, 1);
        // Not after settlement or refund.
        _closeAndFulfill(roundId);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 2;
        amounts[0] = 4e18;
        _settle(roundId, ids, amounts);
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        module.spend(roundId, 1, 1, 1);
        uint256 next = _open();
        _enter(next, 1);
        _close(next);
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.WrongStatus.selector);
        module.spend(next, 1, 1, 1);
    }

    // ---- credit ----

    function testDepositCreditRules() public {
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        module.depositCredit(GAME, 1, 1e18);
        registry.setActive(GAME, false);
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.GameNotActive.selector);
        module.depositCredit(GAME, 1, 1e18);
        registry.setActive(GAME, true);
        registry.setModule(GAME, address(0xBEEF));
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.NotCurrentModule.selector);
        module.depositCredit(GAME, 1, 1e18);
        registry.setModule(GAME, address(module));
        vm.prank(_ownerOf(1));
        module.depositCredit(GAME, 1, 1e18);
        assertEq(treasury.creditOf(GAME, 1), 1e18);
    }

    function testWithdrawCreditBlockedWhileLiveAndPaidToWallet() public {
        vm.prank(_ownerOf(1));
        module.depositCredit(GAME, 1, 10e18);
        uint256 roundId = _open();
        _fill(roundId, 5);
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        module.withdrawCredit(GAME, 1, 1e18);
        _closeAndFulfill(roundId);
        vm.prank(_ownerOf(1));
        vm.expectRevert(RoundModule.RoundInProgress.selector);
        module.withdrawCredit(GAME, 1, 1e18);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        module.withdrawCredit(GAME, 1, 1e18);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 3;
        amounts[0] = 4e18;
        _settle(roundId, ids, amounts);
        // Works when retired and when another module is current; always lands in the wallet.
        registry.setActive(GAME, false);
        registry.setModule(GAME, address(0xBEEF));
        uint256 ownerBefore = rf.balanceOf(_ownerOf(1));
        uint256 walletBefore = rf.balanceOf(_wallet(1));
        vm.prank(_ownerOf(1));
        module.withdrawCredit(GAME, 1, 6e18);
        assertEq(rf.balanceOf(_ownerOf(1)), ownerBefore);
        assertEq(rf.balanceOf(_wallet(1)), walletBefore + 6e18);
        assertEq(treasury.creditOf(GAME, 1), 4e18);
        // Over-withdrawal reverts in the Treasury ledger.
        vm.prank(_ownerOf(1));
        vm.expectRevert();
        module.withdrawCredit(GAME, 1, 5e18);
    }

    function testCreditFollowsTheFriendToItsNewOwner() public {
        vm.prank(_ownerOf(1));
        module.depositCredit(GAME, 1, 2e18);
        address buyer = address(0xB0B);
        vm.prank(_ownerOf(1));
        gens.transfer(1, buyer);
        vm.prank(_ownerOf(1));
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        module.withdrawCredit(GAME, 1, 2e18);
        vm.prank(buyer);
        module.withdrawCredit(GAME, 1, 2e18);
        assertEq(rf.balanceOf(_wallet(1)), 2e18);
    }

    // ---- settler rotation ----

    function testSettlerRotationUnblocksAStuckRound() public {
        uint256 roundId = _open();
        _fill(roundId, 12);
        _closeAndFulfill(roundId);
        address next = address(0x5E772);
        registry.setSettler(GAME, next);
        (uint256[] memory ids, uint256[] memory amounts) = _payouts();
        vm.prank(SETTLER);
        vm.expectRevert(RoundModule.OnlySettler.selector);
        module.settleRound(roundId, SECRET, ids, amounts);
        vm.prank(next);
        module.settleRound(roundId, SECRET, ids, amounts);
        assertEq(uint8(_status(roundId)), uint8(RoundModule.Status.Settled));
        assertEq(_reserved(), 0);
    }
}
