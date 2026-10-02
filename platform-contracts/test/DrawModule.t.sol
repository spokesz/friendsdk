// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test, stdError } from "forge-std/Test.sol";
import { DrawModule } from "../src/DrawModule.sol";
import { IGameItems } from "../src/interfaces/IGameItems.sol";
import { IGameRegistry } from "../src/interfaces/IGameRegistry.sol";
import { IRandomnessCoordinator } from "../src/interfaces/IRandomnessCoordinator.sol";
import { ITreasury } from "../src/interfaces/ITreasury.sol";
import { DrawTables } from "../src/libraries/DrawTables.sol";
import { FriendAccess } from "../src/libraries/FriendAccess.sol";
import { Rolls } from "../src/libraries/Rolls.sol";
import { LaunchTerms } from "../script/LaunchTerms.sol";
import {
    MockCustody,
    MockFriendWallet,
    MockGenerations,
    MockRF,
    MockUSDG
} from "./doubles/ExternalDoubles.sol";

/// @dev Records every call's calldata so tests assert exact sequences.
contract Recorder {
    bytes[] public calls;

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function _record() internal {
        calls.push(msg.data);
    }
}

/// @dev Minimal registry: one module per game, recipients, executor and the custody replay table.
contract StubRegistry is IGameRegistry {
    address public owner;
    address public generations;
    address public rf;
    address public usdg;
    address public custody;
    address public custodyExecutor;
    mapping(uint256 => address) public currentModule;
    mapping(uint256 => bool) public isActive;
    mapping(uint256 => address) public currencyOf;
    mapping(uint256 => address) public itemsOf;
    mapping(uint256 => address) private _developer;
    mapping(uint256 => address) private _operator;
    mapping(bytes32 => bool) public custodyActionUsed;
    address public lastConsumer;
    uint256 public lastConsumedGame;

    error InvalidCustodyAction();

    constructor(
        address owner_,
        address generations_,
        address rf_,
        address usdg_,
        address custody_
    ) {
        owner = owner_;
        generations = generations_;
        rf = rf_;
        usdg = usdg_;
        custody = custody_;
    }

    function setGame(
        uint256 gameId,
        address module,
        address currency,
        address items,
        address developer,
        address operator
    ) external {
        currentModule[gameId] = module;
        currencyOf[gameId] = currency;
        itemsOf[gameId] = items;
        _developer[gameId] = developer;
        _operator[gameId] = operator;
        isActive[gameId] = true;
    }

    function setActive(uint256 gameId, bool active) external {
        isActive[gameId] = active;
    }

    function setCustodyExecutor(address executor) external {
        custodyExecutor = executor;
    }

    function game(uint256 gameId) external view returns (Game memory g) {
        g.module = currentModule[gameId];
        g.status = isActive[gameId] ? Status.Active : Status.Retired;
        g.currency = currencyOf[gameId];
        g.items = itemsOf[gameId];
        g.developer = _developer[gameId];
        g.operator = _operator[gameId];
    }

    function isBound(uint256 gameId, address module) external view returns (bool) {
        return currentModule[gameId] == module;
    }

    function canCommit(uint256 gameId, address module) external view returns (bool) {
        return isActive[gameId] && currentModule[gameId] == module;
    }

    function settlerOf(uint256) external pure returns (address) {
        return address(0);
    }

    function recipientsOf(uint256 gameId) external view returns (address, address, address) {
        return (address(0xF00D), _developer[gameId], _operator[gameId]);
    }

    function consumeCustodyAction(bytes32 actionId, uint256 gameId) external {
        if (actionId == 0 || custodyActionUsed[actionId]) revert InvalidCustodyAction();
        custodyActionUsed[actionId] = true;
        lastConsumer = msg.sender;
        lastConsumedGame = gameId;
    }
}

/// @dev Treasury with the three ledgers the Draw module touches and a recorded call log.
contract StubTreasury is ITreasury, Recorder {
    struct Ledger {
        uint256 free;
        uint256 reserved;
        uint256 owed;
    }

    mapping(uint256 => Ledger) private _ledgers;

    error InsufficientFree();

    function setFree(uint256 gameId, uint256 amount) external {
        _ledgers[gameId].free = amount;
    }

    function collect(uint256 gameId, address, Legs calldata legs) external {
        _record();
        _ledgers[gameId].free += legs.toFree;
        _ledgers[gameId].reserved += legs.toReserved;
    }

    function reserve(uint256 gameId, uint256 amount) external {
        _record();
        Ledger storage l = _ledgers[gameId];
        if (amount > l.free) revert InsufficientFree();
        l.free -= amount;
        l.reserved += amount;
    }

    function release(uint256 gameId, uint256 amount) external {
        _record();
        _ledgers[gameId].reserved -= amount;
        _ledgers[gameId].free += amount;
    }

    function resolve(
        uint256 gameId,
        uint256 amount,
        uint256 toOwed,
        uint256 toKeep,
        address,
        uint256 pay
    ) external {
        _record();
        Ledger storage l = _ledgers[gameId];
        l.free += amount - toOwed - toKeep - pay;
        l.reserved -= amount - toKeep;
        l.owed += toOwed;
    }

    function routeReserved(uint256, uint256, uint256) external {
        _record();
    }

    function payOwed(uint256 gameId, address, uint256 amount) external {
        _record();
        _ledgers[gameId].owed -= amount;
    }

    function creditDeposit(uint256, uint256, address, uint256) external {
        _record();
    }

    function creditWithdraw(uint256, uint256, address, uint256) external {
        _record();
    }

    function creditSpend(uint256, uint256, uint256, uint256, uint256) external {
        _record();
    }

    function ledgers(uint256 gameId)
        external
        view
        returns (uint256 free, uint256 reserved, uint256 owed, uint256 credit)
    {
        Ledger storage l = _ledgers[gameId];
        return (l.free, l.reserved, l.owed, 0);
    }

    function creditOf(uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Coordinator that hands out request ids and stores words the test supplies.
contract StubCoordinator is IRandomnessCoordinator {
    struct Request {
        address module;
        uint256 gameId;
        bytes32 actionKey;
        bool fulfilled;
        bytes32 word;
    }

    uint256 public requestCount;
    mapping(uint256 => Request) public requests;

    function request(uint256 gameId, bytes32 actionKey) external returns (uint256 requestId) {
        requestId = ++requestCount;
        requests[requestId] = Request(msg.sender, gameId, actionKey, false, 0);
    }

    function fulfill(uint256 requestId, bytes32 value) external {
        requests[requestId].fulfilled = true;
        requests[requestId].word = value;
    }

    function word(uint256 requestId) external view returns (bool, bytes32) {
        return (requests[requestId].fulfilled, requests[requestId].word);
    }

    function retry(uint256) external { }
}

/// @dev Items collection with balances and a recorded call log; burns revert on underflow.
contract StubItems is IGameItems, Recorder {
    uint256 public immutable classCount;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    constructor(uint256 classCount_) {
        classCount = classCount_;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _record();
        balanceOf[to][id] += amount;
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        _record();
        for (uint256 i; i < ids.length; ++i) {
            balanceOf[to][ids[i]] += amounts[i];
        }
    }

    function burn(address from, uint256 id, uint256 amount) external {
        _record();
        balanceOf[from][id] -= amount;
    }

    function setURI(string calldata) external { }
}

/// @dev DrawModule in isolation against the Rare Breeds and Penalty Kings terms of SPEC section 3.
contract DrawModuleTest is Test {
    uint256 internal constant BREEDS = 1;
    uint256 internal constant PARK = 2;
    uint256 internal constant FRIEND = 1234;
    uint256 internal constant CUSTODIED = 777;
    uint256 internal constant STRIKER = 999;
    address internal constant PARK_DEVELOPER = 0xd0BB5CC938dA89E0d7129F1eE01C2cfc61C2e36F;
    address internal constant PARK_OPERATOR = 0x1EcBF27dC1F809179B9ef2d382cd76ccBa21B6d2;

    MockRF internal rf;
    MockUSDG internal usdg;
    MockGenerations internal generations;
    MockCustody internal custody;
    StubRegistry internal registry;
    StubTreasury internal treasury;
    StubCoordinator internal coordinator;
    StubItems internal breedsItems;
    StubItems internal parkItems;
    DrawModule internal draw;

    address internal owner = makeAddr("owner");
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");
    address internal wallet;
    address internal custodiedWallet;
    address internal strikerWallet;

    function setUp() public {
        rf = new MockRF();
        usdg = new MockUSDG(6);
        generations = new MockGenerations(address(rf));
        custody = new MockCustody();
        registry = new StubRegistry(
            owner, address(generations), address(rf), address(usdg), address(custody)
        );
        registry.setCustodyExecutor(executor);
        treasury = new StubTreasury();
        coordinator = new StubCoordinator();
        breedsItems = new StubItems(5);
        parkItems = new StubItems(LaunchTerms.PARK_BALLS);
        draw = new DrawModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        registry.setGame(
            BREEDS, address(draw), address(rf), address(breedsItems), address(0), address(0)
        );
        registry.setGame(
            PARK, address(draw), address(usdg), address(parkItems), PARK_DEVELOPER, PARK_OPERATOR
        );
        _defineBreeds(draw, BREEDS);
        _definePark(draw, PARK);
        vm.startPrank(address(registry));
        draw.seal(BREEDS);
        draw.seal(PARK);
        vm.stopPrank();
        treasury.setFree(BREEDS, 10_000e18);
        treasury.setFree(PARK, 5000e6);

        generations.mint(alice, FRIEND, 3);
        generations.mint(address(custody), CUSTODIED, 5);
        generations.mint(alice, STRIKER, 6);
        wallet = generations.tokenBoundAccount(FRIEND);
        custodiedWallet = generations.tokenBoundAccount(CUSTODIED);
        strikerWallet = generations.tokenBoundAccount(STRIKER);
    }

    // ------------------------------------------------------------------------ helpers

    function _defineBreeds(DrawModule module, uint256 gameId) internal {
        vm.startPrank(owner);
        module.defineClasses(gameId, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        module.defineAction(gameId, a, s, t);
        (a, s, t) = LaunchTerms.breedsPlayAction();
        module.defineAction(gameId, a, s, t);
        vm.stopPrank();
    }

    function _definePark(DrawModule module, uint256 gameId) internal {
        vm.startPrank(owner);
        module.defineClasses(gameId, LaunchTerms.parkClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.parkPackAction();
        module.defineAction(gameId, a, s, t);
        for (uint16 ball = 1; ball <= LaunchTerms.PARK_BALLS; ++ball) {
            (a, s, t) = LaunchTerms.parkKickActionTerms(ball);
            module.defineAction(gameId, a, s, t);
        }
        vm.stopPrank();
    }

    function _legs(uint256 toFree, uint256 developer, uint256 operator)
        internal
        pure
        returns (ITreasury.Legs memory)
    {
        return ITreasury.Legs(toFree, 0, developer, operator, 0, 0);
    }

    function _one(uint256 id, uint256 amount)
        internal
        pure
        returns (uint256[] memory ids, uint256[] memory amounts)
    {
        ids = new uint256[](1);
        amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = amount;
    }

    function _mintBatchCall(address to, uint256 id, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        (uint256[] memory ids, uint256[] memory amounts) = _one(id, amount);
        return abi.encodeCall(IGameItems.mintBatch, (to, ids, amounts));
    }

    /// @dev A word whose roll for draw 0 of `commitId` equals `target` (expected 10k tries).
    /// Runs in its own call frame and hashes in scratch memory so the search never grows memory.
    function _wordFor(uint256 commitId, uint16 target) internal view returns (bytes32) {
        return this.wordFor(commitId, target);
    }

    function wordFor(uint256 commitId, uint16 target) external view returns (bytes32 word) {
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
                mstore(add(p, 128), 0)
                value := keccak256(p, 160)
            }
            if (value < limit && value % Rolls.RANGE == target) break;
        }
        assertEq(Rolls.roll(word, module, chainId, commitId, 0), target, "search");
    }

    function _buyEggs(uint8 quantity) internal returns (uint256 commitId) {
        vm.prank(alice);
        commitId = draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, quantity, 0, 0);
    }

    function _playEgg(bytes32 context) internal returns (uint256 commitId) {
        vm.prank(alice);
        commitId = draw.commit(BREEDS, LaunchTerms.BREEDS_PLAY, FRIEND, 1, context, 0);
    }

    function _free(uint256 gameId) internal view returns (uint256 free) {
        (free,,,) = treasury.ledgers(gameId);
    }

    function _reserved(uint256 gameId) internal view returns (uint256 reserved) {
        (, reserved,,) = treasury.ledgers(gameId);
    }

    function _owed(uint256 gameId) internal view returns (uint256 owed) {
        (,, owed,) = treasury.ledgers(gameId);
    }

    function _commit(uint256 commitId)
        internal
        view
        returns (uint8 generation, bool settled, uint128 reservedTotal, uint256 requestId)
    {
        (,,,, generation, settled, reservedTotal, requestId) = draw.commits(commitId);
    }

    // -------------------------------------------------------------------------- terms

    function testLineage() public view {
        assertEq(draw.LINEAGE(), keccak256("Draw"));
    }

    function testConstructorRequiresCode() public {
        vm.expectRevert(DrawModule.InvalidConfiguration.selector);
        new DrawModule(address(registry), address(treasury), address(coordinator), alice);
    }

    function testBreedsTermsStoredExactly() public view {
        DrawTables.Class[] memory classes = draw.classes(BREEDS);
        assertEq(classes.length, 5);
        assertEq(classes[0].reserve, 6e18);
        assertEq(classes[0].value, 0);
        assertEq(classes[1].value, 5e17);
        assertEq(classes[4].value, 6e18);
        assertEq(draw.actionCount(BREEDS), 2);
        assertEq(draw.maxPayable(BREEDS, LaunchTerms.BREEDS_BUY, 0), 6e18);
        assertEq(draw.maxPayable(BREEDS, LaunchTerms.BREEDS_PLAY, 0), 6e18);
        DrawTables.Row[] memory rows = draw.rows(BREEDS, LaunchTerms.BREEDS_PLAY, 0);
        assertEq(rows.length, 4);
        assertEq(rows[0].weightBps, 6000);
        assertEq(rows[0].classId, LaunchTerms.BREEDS_COMMON);
        assertEq(rows[3].weightBps, 250);
        assertEq(rows[3].classId, LaunchTerms.BREEDS_PRISMATIC);
        assertEq(draw.rows(BREEDS, LaunchTerms.BREEDS_BUY, 0).length, 1);
        (DrawTables.Input input,,, uint128 price, uint8 draws, uint8 maxUnits, bool perGen) =
            draw.actions(BREEDS, LaunchTerms.BREEDS_BUY);
        assertEq(uint8(input), uint8(DrawTables.Input.Currency));
        assertEq(price, 1e18);
        assertEq(draws, 1);
        assertEq(maxUnits, 10);
        assertFalse(perGen);
        (uint16 freeBps,,,,) = draw.splits(BREEDS, LaunchTerms.BREEDS_BUY, 3);
        assertEq(freeBps, 10_000);
    }

    function testSealIsRegistryOnlyIdempotentAndFreezesTerms() public {
        DrawModule fresh = new DrawModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        assertEq(fresh.termsHash(BREEDS), bytes32(0));
        vm.prank(address(registry));
        vm.expectRevert(DrawModule.NoTerms.selector);
        fresh.seal(BREEDS);
        _defineBreeds(fresh, BREEDS);
        assertEq(fresh.termsHash(BREEDS), bytes32(0), "zero until sealed");
        vm.expectRevert(DrawModule.OnlyRegistry.selector);
        fresh.seal(BREEDS);
        bytes32 expected = fresh.runningHash(BREEDS);
        vm.prank(address(registry));
        vm.expectEmit(address(fresh));
        emit DrawModule.TermsSealed(BREEDS, expected);
        assertEq(fresh.seal(BREEDS), expected);
        assertEq(fresh.termsHash(BREEDS), expected);
        assertTrue(fresh.isSealed(BREEDS));
        vm.prank(address(registry));
        assertEq(fresh.seal(BREEDS), expected, "idempotent");
        // Same calls on two modules produce the same hash; sealed terms are frozen.
        assertEq(expected, draw.runningHash(BREEDS));
        vm.startPrank(owner);
        vm.expectRevert(DrawModule.Sealed.selector);
        fresh.defineClasses(BREEDS, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsPlayAction();
        vm.expectRevert(DrawModule.Sealed.selector);
        fresh.defineAction(BREEDS, a, s, t);
        vm.stopPrank();
    }

    function testOneBpsChangesTheHash() public {
        DrawModule fresh = new DrawModule(
            address(registry), address(treasury), address(coordinator), address(generations)
        );
        vm.startPrank(owner);
        fresh.defineClasses(BREEDS, LaunchTerms.breedsClasses());
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        fresh.defineAction(BREEDS, a, s, t);
        (a, s, t) = LaunchTerms.breedsPlayAction();
        t[0][0].weightBps = 5999;
        t[0][1].weightBps = 2501;
        fresh.defineAction(BREEDS, a, s, t);
        vm.stopPrank();
        assertNotEq(fresh.runningHash(BREEDS), draw.runningHash(BREEDS));
        assertNotEq(fresh.runningHash(BREEDS), bytes32(0));
    }

    function testDefinitionErrors() public {
        uint256 gameId = 7;
        StubItems items = new StubItems(5);
        registry.setGame(
            gameId, address(draw), address(usdg), address(items), address(0), address(0)
        );
        DrawTables.Class[] memory classes = LaunchTerms.breedsClasses();
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();

        vm.prank(stranger);
        vm.expectRevert(DrawModule.NotRegistryOwner.selector);
        draw.defineClasses(gameId, classes);
        vm.prank(stranger);
        vm.expectRevert(DrawModule.NotRegistryOwner.selector);
        draw.defineAction(gameId, a, s, t);

        vm.startPrank(owner);
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t); // classes not defined yet
        vm.expectRevert(DrawModule.ClassCountMismatch.selector);
        draw.defineClasses(8, classes); // no items collection
        vm.expectRevert(DrawModule.ClassCountMismatch.selector);
        draw.defineClasses(gameId, LaunchTerms.parkClasses()); // 7 != 5
        classes[2].reserve = 1;
        vm.expectRevert(DrawModule.InvalidClass.selector);
        draw.defineClasses(gameId, classes); // both value and reserve
        classes[2].reserve = 0;
        draw.defineClasses(gameId, classes);
        vm.expectRevert(DrawModule.ClassesAlreadyDefined.selector);
        draw.defineClasses(gameId, classes);

        // Currency action on a USDG game with no developer: burn and developer legs refused.
        s[2].freeBps = 9000;
        s[2].burnBps = 1000;
        vm.expectRevert(DrawModule.InvalidSplit.selector);
        draw.defineAction(gameId, a, s, t);
        s[2].burnBps = 0;
        s[2].developerBps = 1000;
        vm.expectRevert(DrawModule.InvalidSplit.selector);
        draw.defineAction(gameId, a, s, t);
        s[2].developerBps = 0;
        vm.expectRevert(DrawModule.InvalidSplit.selector);
        draw.defineAction(gameId, a, s, t); // sums to 9000
        s[2].freeBps = 10_000;
        a.price = 0;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.price = 1e6;
        a.draws = 5;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.draws = 1;
        a.maxUnits = 17;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.maxUnits = 0;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.maxUnits = 10;
        a.perGeneration = true;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t); // one table for six generations
        a.perGeneration = false;
        a.input = DrawTables.Input.None;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.input = DrawTables.Input.Currency;
        t[0][0].weightBps = 9999;
        vm.expectRevert(DrawTables.InvalidTable.selector);
        draw.defineAction(gameId, a, s, t);
        t[0][0].weightBps = 10_000;
        t[0][0].classId = 6;
        vm.expectRevert(DrawTables.InvalidTable.selector);
        draw.defineAction(gameId, a, s, t);
        t[0][0].classId = 1;
        draw.defineAction(gameId, a, s, t);
        assertEq(draw.actionCount(gameId), 1);

        // BurnClass action: input class in range, nonzero count, every split zero.
        (a, s, t) = LaunchTerms.breedsPlayAction();
        a.inputClass = 6;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.inputClass = 0;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.inputClass = 1;
        a.inputCount = 0;
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.inputCount = 1;
        s[5].rewardsBps = 1;
        vm.expectRevert(DrawModule.InvalidSplit.selector);
        draw.defineAction(gameId, a, s, t);
        s[5].rewardsBps = 0;
        draw.defineAction(gameId, a, s, t);
        assertEq(draw.actionCount(gameId), 2);
        vm.stopPrank();
    }

    function testTooManyActions() public {
        uint256 gameId = 7;
        StubItems items = new StubItems(5);
        registry.setGame(gameId, address(draw), address(rf), address(items), address(0), address(0));
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsPlayAction();
        vm.startPrank(owner);
        draw.defineClasses(gameId, LaunchTerms.breedsClasses());
        for (uint256 i; i < DrawTables.MAX_ACTIONS; ++i) {
            draw.defineAction(gameId, a, s, t);
        }
        vm.expectRevert(DrawModule.TooManyActions.selector);
        draw.defineAction(gameId, a, s, t);
        vm.stopPrank();
    }

    function testMaximumTimesMaxUnitsMustFitUint128() public {
        uint256 gameId = 7;
        StubItems items = new StubItems(1);
        registry.setGame(gameId, address(draw), address(rf), address(items), address(0), address(0));
        DrawTables.Class[] memory classes = new DrawTables.Class[](1);
        classes[0] = DrawTables.Class(type(uint128).max, 0);
        (DrawTables.Action memory a, DrawTables.Split[6] memory s, DrawTables.Row[][] memory t) =
            LaunchTerms.breedsBuyAction();
        a.maxUnits = 2;
        vm.startPrank(owner);
        draw.defineClasses(gameId, classes);
        vm.expectRevert(DrawModule.InvalidAction.selector);
        draw.defineAction(gameId, a, s, t);
        a.maxUnits = 1;
        draw.defineAction(gameId, a, s, t);
        vm.stopPrank();
    }

    // --------------------------------------------------------------- Rare Breeds: buy

    function testBuyEggsSettlesInline() public {
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(1, BREEDS, FRIEND, wallet, 1, 5, 3, 30e18, 0, 0, 0);
        uint8[] memory rows = new uint8[](5);
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(1, BREEDS, FRIEND, wallet, rows, 0, 0);
        uint256 commitId = _buyEggs(5);
        assertEq(commitId, 1);

        assertEq(treasury.callCount(), 3);
        assertEq(
            treasury.calls(0), abi.encodeCall(ITreasury.collect, (BREEDS, alice, _legs(5e18, 0, 0)))
        );
        assertEq(treasury.calls(1), abi.encodeCall(ITreasury.reserve, (BREEDS, 30e18)));
        assertEq(
            treasury.calls(2),
            abi.encodeCall(ITreasury.resolve, (BREEDS, 30e18, 0, 30e18, wallet, 0))
        );
        assertEq(breedsItems.callCount(), 1);
        assertEq(breedsItems.calls(0), _mintBatchCall(wallet, LaunchTerms.BREEDS_EGG, 5));
        assertEq(breedsItems.balanceOf(wallet, LaunchTerms.BREEDS_EGG), 5);
        assertEq(coordinator.requestCount(), 0, "no word for a one-row table");

        (uint8 generation, bool settled, uint128 reservedTotal, uint256 requestId) = _commit(1);
        assertEq(generation, 3);
        assertTrue(settled);
        assertEq(reservedTotal, 30e18);
        assertEq(requestId, 0);
        assertEq(_free(BREEDS), 10_000e18 + 5e18 - 30e18);
        assertEq(_reserved(BREEDS), 30e18);
        vm.expectRevert(DrawModule.AlreadySettled.selector);
        draw.settle(1); // settled inline: nothing left to settle
    }

    function testBuyEggsNeedsBankrollForSixPerEgg() public {
        treasury.setFree(BREEDS, 24e18);
        vm.prank(alice);
        vm.expectRevert(StubTreasury.InsufficientFree.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 5, 0, 0); // 24 + 5 < 30
        treasury.setFree(BREEDS, 25e18);
        _buyEggs(5); // 25 + 5 == 30
        assertEq(_free(BREEDS), 0);
    }

    function testQuantityBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(DrawModule.InvalidQuantity.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 0, 0, 0);
        vm.expectRevert(DrawModule.InvalidQuantity.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 11, 0, 0);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 10, 0, 0);
        vm.expectRevert(DrawModule.UnknownAction.selector);
        draw.commit(BREEDS, 3, FRIEND, 1, 0, 0);
        vm.stopPrank();
        assertEq(breedsItems.balanceOf(wallet, LaunchTerms.BREEDS_EGG), 10);
    }

    function testCommitRequiresCurrentSealedModule() public {
        registry.setGame(
            BREEDS, stranger, address(rf), address(breedsItems), address(0), address(0)
        );
        vm.prank(alice);
        vm.expectRevert(DrawModule.NotCurrentModule.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        uint256 draft = 9;
        registry.setGame(
            draft, address(draw), address(rf), address(breedsItems), address(0), address(0)
        );
        vm.prank(alice);
        vm.expectRevert(DrawModule.NotSealed.selector);
        draw.commit(draft, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
    }

    function testOwnedPathAccess() public {
        vm.prank(stranger);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        // Paying from the Friend wallet: the owner calls through execute, the wallet is the payer.
        bytes memory data =
            abi.encodeCall(draw.commit, (BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0));
        vm.prank(alice);
        MockFriendWallet(payable(wallet)).execute(address(draw), 0, data, 0);
        assertEq(
            treasury.calls(0),
            abi.encodeCall(ITreasury.collect, (BREEDS, wallet, _legs(1e18, 0, 0)))
        );
        // Generation 0 and 7 never play; a transferred Friend follows its new owner.
        generations.mint(alice, 4242, 0);
        vm.prank(alice);
        vm.expectRevert(FriendAccess.InvalidFriend.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, 4242, 1, 0, 0);
        vm.prank(alice);
        generations.transfer(FRIEND, stranger);
        vm.prank(alice);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        vm.prank(stranger);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        assertEq(breedsItems.balanceOf(wallet, LaunchTerms.BREEDS_EGG), 2);
    }

    // -------------------------------------------------------------- Rare Breeds: play

    function testPlayEggReleasesThenReservesSix() public {
        _buyEggs(1);
        treasury.setFree(BREEDS, 0); // the bankroll is otherwise empty
        bytes32 context = keccak256(abi.encode(uint256(11), uint256(22)));
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(2, BREEDS, FRIEND, wallet, 2, 1, 3, 6e18, 1, context, 0);
        uint256 commitId = _playEgg(context);
        assertEq(commitId, 2);

        assertEq(
            breedsItems.calls(1),
            abi.encodeCall(IGameItems.burn, (wallet, LaunchTerms.BREEDS_EGG, 1))
        );
        assertEq(breedsItems.balanceOf(wallet, LaunchTerms.BREEDS_EGG), 0);
        assertEq(treasury.callCount(), 5);
        assertEq(treasury.calls(3), abi.encodeCall(ITreasury.release, (BREEDS, 6e18)));
        assertEq(treasury.calls(4), abi.encodeCall(ITreasury.reserve, (BREEDS, 6e18)));
        assertEq(_free(BREEDS), 0);
        assertEq(_reserved(BREEDS), 6e18, "the pending play holds exactly 6 RF");

        (address module, uint256 gameId, bytes32 actionKey,,) = coordinator.requests(1);
        assertEq(module, address(draw));
        assertEq(gameId, BREEDS);
        assertEq(actionKey, bytes32(commitId));
        (, bool settled, uint128 reservedTotal, uint256 requestId) = _commit(commitId);
        assertFalse(settled);
        assertEq(reservedTotal, 6e18);
        assertEq(requestId, 1);
    }

    function testPlayEggWithoutAnEggReverts() public {
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        draw.commit(BREEDS, LaunchTerms.BREEDS_PLAY, FRIEND, 1, 0, 0);
    }

    /// @dev Exact table boundaries: rolls 0, 5999, 6000, 8499, 8500, 9749, 9750, 9999.
    function testPlayEggSettlesAtEveryBoundary() public {
        uint16[8] memory rolls = [uint16(0), 5999, 6000, 8499, 8500, 9749, 9750, 9999];
        uint8[8] memory expectedRow = [uint8(0), 0, 1, 1, 2, 2, 3, 3];
        _buyEggs(8);
        uint256 owed;
        for (uint256 i; i < rolls.length; ++i) {
            owed += _playAndSettle(bytes32(i), rolls[i], expectedRow[i]);
            assertEq(_owed(BREEDS), owed);
        }
        // 2 × (0.5 + 1 + 1.5 + 6) RF over the eight plays: every row was hit twice.
        assertEq(_owed(BREEDS), 18e18);
        assertEq(_reserved(BREEDS), 0, "every play's 6 RF resolved");
        assertEq(_free(BREEDS), 10_000e18 + 8e18 - 18e18);
        for (uint16 classId = 2; classId <= 5; ++classId) {
            assertEq(breedsItems.balanceOf(wallet, classId), 2);
        }
    }

    /// @dev Plays one egg, forces `roll`, settles and checks the row's class; returns its value.
    function _playAndSettle(bytes32 context, uint16 roll, uint8 row) internal returns (uint128) {
        uint128[4] memory values = [uint128(5e17), 1e18, 15e17, 6e18];
        uint256 commitId = _playEgg(context);
        coordinator.fulfill(commitId - 1, _wordFor(commitId, roll));
        assertEq(draw.rollFor(commitId, 0), roll, "rollFor");
        uint256 treasuryCalls = treasury.callCount();
        uint256 itemCalls = breedsItems.callCount();
        uint8[] memory rowsOut = new uint8[](1);
        rowsOut[0] = row;
        vm.expectEmit(address(draw));
        emit DrawModule.Settled(commitId, BREEDS, FRIEND, wallet, rowsOut, 0, values[row]);
        draw.settle(commitId);
        assertEq(
            treasury.calls(treasuryCalls),
            abi.encodeCall(ITreasury.resolve, (BREEDS, 6e18, values[row], 0, wallet, 0))
        );
        assertEq(breedsItems.calls(itemCalls), _mintBatchCall(wallet, uint16(row) + 2, 1));
        (, bool settled,,) = _commit(commitId);
        assertTrue(settled);
        return values[row];
    }

    function testSettleIdempotencyAndErrors() public {
        vm.expectRevert(DrawModule.UnknownCommit.selector);
        draw.settle(1);
        _buyEggs(2);
        uint256 commitId = _playEgg(0);
        vm.expectRevert(DrawModule.RandomnessPending.selector);
        draw.settle(commitId);
        vm.expectRevert(DrawModule.RandomnessPending.selector);
        draw.rollFor(commitId, 0);
        coordinator.fulfill(1, keccak256("word"));
        draw.settle(commitId);
        vm.expectRevert(DrawModule.AlreadySettled.selector);
        draw.settle(commitId);
        // The word is never consumed; the outcome is reproducible from public state.
        DrawTables.Row[] memory table = draw.rows(BREEDS, LaunchTerms.BREEDS_PLAY, 0);
        uint16 roll = draw.rollFor(commitId, 0);
        uint256 cumulative;
        uint256 expected;
        for (uint256 i; i < table.length; ++i) {
            cumulative += table[i].weightBps;
            if (roll < cumulative) {
                expected = table[i].classId;
                break;
            }
        }
        assertEq(breedsItems.balanceOf(wallet, expected), 1);
    }

    function testSettleResolvesWalletAtSettlement() public {
        _buyEggs(1);
        uint256 commitId = _playEgg(0);
        vm.prank(alice);
        generations.transfer(FRIEND, stranger);
        coordinator.fulfill(1, keccak256("word"));
        draw.settle(commitId);
        // The wallet is a pure function of the token, so the item lands with the new owner.
        assertEq(generations.tokenBoundAccount(FRIEND), wallet);
        uint256 tiers;
        for (uint16 classId = 2; classId <= 5; ++classId) {
            tiers += breedsItems.balanceOf(wallet, classId);
        }
        assertEq(tiers, 1, "the tier token lands in the Friend wallet");
        assertEq(breedsItems.balanceOf(generations.tokenBoundAccount(FRIEND), 1), 0);
    }

    function testGameNotActiveStopsPurchasesOnly() public {
        _buyEggs(1);
        registry.setActive(BREEDS, false);
        vm.prank(alice);
        vm.expectRevert(DrawModule.GameNotActive.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, 0);
        uint256 commitId = _playEgg(0);
        coordinator.fulfill(1, keccak256("word"));
        draw.settle(commitId);
        (, bool settled,,) = _commit(commitId);
        assertTrue(settled);
    }

    // ------------------------------------------------------------- Rare Breeds: redeem

    function testRedeemPaysFixedValueForever() public {
        _buyEggs(1);
        uint256 commitId = _playEgg(0);
        coordinator.fulfill(1, _wordFor(commitId, 7100)); // Spotted
        draw.settle(commitId);
        assertEq(_owed(BREEDS), 1e18);
        registry.setActive(BREEDS, false);
        registry.setGame(
            BREEDS, stranger, address(rf), address(breedsItems), address(0), address(0)
        );
        vm.warp(block.timestamp + 5 * 365 days);

        vm.startPrank(alice);
        vm.expectRevert(DrawModule.ZeroQuantity.selector);
        draw.redeem(BREEDS, FRIEND, LaunchTerms.BREEDS_SPOTTED, 0, 0);
        vm.expectRevert(DrawModule.NotRedeemable.selector);
        draw.redeem(BREEDS, FRIEND, LaunchTerms.BREEDS_EGG, 1, 0);
        vm.expectRevert(DrawModule.NotRedeemable.selector);
        draw.redeem(BREEDS, FRIEND, 0, 1, 0);
        vm.expectRevert(DrawModule.NotRedeemable.selector);
        draw.redeem(BREEDS, FRIEND, 6, 1, 0);
        vm.expectEmit(address(draw));
        emit DrawModule.Redeemed(BREEDS, FRIEND, wallet, LaunchTerms.BREEDS_SPOTTED, 1, 1e18, 0);
        draw.redeem(BREEDS, FRIEND, LaunchTerms.BREEDS_SPOTTED, 1, 0);
        vm.stopPrank();
        uint256 n = treasury.callCount();
        assertEq(treasury.calls(n - 1), abi.encodeCall(ITreasury.payOwed, (BREEDS, wallet, 1e18)));
        assertEq(
            breedsItems.calls(breedsItems.callCount() - 1),
            abi.encodeCall(IGameItems.burn, (wallet, LaunchTerms.BREEDS_SPOTTED, 1))
        );
        assertEq(_owed(BREEDS), 0);
        vm.prank(stranger);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.redeem(BREEDS, FRIEND, LaunchTerms.BREEDS_SPOTTED, 1, 0);
    }

    // ------------------------------------------------------------------ custody path

    function testCustodyPathConsumesActionOnce() public {
        bytes32 a1 = keccak256("A1");
        vm.prank(executor);
        vm.expectEmit(address(draw));
        emit DrawModule.Committed(1, BREEDS, CUSTODIED, custodiedWallet, 1, 2, 5, 12e18, 0, 0, a1);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, CUSTODIED, 2, 0, a1);
        assertTrue(registry.custodyActionUsed(a1));
        assertEq(registry.lastConsumer(), address(draw));
        assertEq(registry.lastConsumedGame(), BREEDS);
        assertEq(
            treasury.calls(0),
            abi.encodeCall(ITreasury.collect, (BREEDS, executor, _legs(2e18, 0, 0)))
        );
        assertEq(breedsItems.balanceOf(custodiedWallet, LaunchTerms.BREEDS_EGG), 2);

        vm.startPrank(executor);
        vm.expectRevert(StubRegistry.InvalidCustodyAction.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, CUSTODIED, 1, 0, a1);
        vm.expectRevert(StubRegistry.InvalidCustodyAction.selector);
        draw.redeem(BREEDS, CUSTODIED, LaunchTerms.BREEDS_SPOTTED, 1, a1);
        // A Friend outside custody cannot be driven by the executor.
        vm.expectRevert(FriendAccess.NotCustodied.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, FRIEND, 1, 0, keccak256("A2"));
        assertFalse(registry.custodyActionUsed(keccak256("A2")), "revert leaves the id unused");
        // A revert after consumption also leaves the id unused.
        treasury.setFree(BREEDS, 0);
        vm.expectRevert(StubTreasury.InsufficientFree.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, CUSTODIED, 1, 0, keccak256("A3"));
        assertFalse(registry.custodyActionUsed(keccak256("A3")));
        vm.stopPrank();
    }

    function testCustodyPathRequiresTheExecutor() public {
        bytes32 a4 = keccak256("A4");
        vm.prank(stranger);
        vm.expectRevert(DrawModule.OnlyCustodyExecutor.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, CUSTODIED, 1, 0, a4);
        // A zero id is the owned path, which custody does not satisfy.
        vm.prank(executor);
        vm.expectRevert(FriendAccess.NotFriendController.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, CUSTODIED, 1, 0, 0);
        registry.setCustodyExecutor(address(0));
        vm.prank(executor);
        vm.expectRevert(DrawModule.OnlyCustodyExecutor.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, CUSTODIED, 1, 0, a4);
        assertFalse(registry.custodyActionUsed(a4));
    }

    function testCustodyPathAfterLeavingCustody() public {
        vm.prank(executor);
        draw.commit(BREEDS, LaunchTerms.BREEDS_BUY, CUSTODIED, 1, 0, keccak256("A1"));
        vm.prank(address(custody));
        generations.transfer(CUSTODIED, alice);
        vm.prank(executor);
        vm.expectRevert(FriendAccess.NotCustodied.selector);
        draw.commit(BREEDS, LaunchTerms.BREEDS_PLAY, CUSTODIED, 1, 0, keccak256("A5"));
        // The new owner plays the egg through the owned path; the wallet is unchanged.
        vm.prank(alice);
        uint256 commitId = draw.commit(BREEDS, LaunchTerms.BREEDS_PLAY, CUSTODIED, 1, 0, 0);
        coordinator.fulfill(1, keccak256("word"));
        draw.settle(commitId);
        assertEq(breedsItems.balanceOf(custodiedWallet, LaunchTerms.BREEDS_EGG), 0);
    }

    // ------------------------------------------------------------------ Penalty Kings

    /// @dev Golden Boot, generation 6: 100/100/200/400/800 for 64..4 USDG, 3900 for 2 USDG,
    /// 4500 saved; maxPayable 64e6. Balls 1..4 pay 2e6 at most, Silver 16e6, Gold 32e6.
    function testParkKickTablesAndMaxima() public view {
        DrawTables.Row[] memory rows = draw.rows(PARK, LaunchTerms.parkKickAction(7), 6);
        uint16[7] memory weights = [uint16(100), 100, 200, 400, 800, 3900, 4500];
        uint128[7] memory prizes = [uint128(64e6), 32e6, 16e6, 8e6, 4e6, 2e6, 0];
        assertEq(rows.length, 7);
        for (uint256 i; i < 7; ++i) {
            assertEq(rows[i].weightBps, weights[i], "weight");
            assertEq(rows[i].value, prizes[i], "prize");
            assertEq(rows[i].classId, 0, "kicks mint nothing");
        }
        // Generation 1 moves 250 bps from the saved row to the 2 USDG row.
        rows = draw.rows(PARK, LaunchTerms.parkKickAction(7), 1);
        assertEq(rows[5].weightBps, 4150);
        assertEq(rows[6].weightBps, 4250);
        for (uint8 gen = 1; gen <= 6; ++gen) {
            assertEq(draw.maxPayable(PARK, LaunchTerms.parkKickAction(7), gen), 64e6);
            assertEq(draw.maxPayable(PARK, LaunchTerms.parkKickAction(6), gen), 32e6);
            assertEq(draw.maxPayable(PARK, LaunchTerms.parkKickAction(5), gen), 16e6);
            for (uint16 ball = 1; ball <= 4; ++ball) {
                assertEq(draw.maxPayable(PARK, LaunchTerms.parkKickAction(ball), gen), 2e6);
                assertEq(draw.rows(PARK, LaunchTerms.parkKickAction(ball), gen).length, 2);
            }
        }
        assertEq(draw.maxPayable(PARK, LaunchTerms.PARK_PACK, 0), 0, "packs reserve nothing");
        assertEq(draw.rows(PARK, LaunchTerms.PARK_PACK, 0).length, 7);
        assertEq(draw.rows(PARK, LaunchTerms.parkKickAction(7), 0).length, 0, "no table at 0");
        assertEq(draw.actionCount(PARK), 8);
        (uint16 freeBps, uint16 developerBps, uint16 operatorBps,,) =
            draw.splits(PARK, LaunchTerms.PARK_PACK, 6);
        assertEq(freeBps, 9000);
        assertEq(developerBps, 750);
        assertEq(operatorBps, 250);
    }

    function testParkPackCollectsBySplitAndReservesNothing() public {
        vm.prank(alice);
        uint256 commitId = draw.commit(PARK, LaunchTerms.PARK_PACK, FRIEND, 2, 0, 0);
        assertEq(treasury.callCount(), 1, "collect only");
        assertEq(
            treasury.calls(0),
            abi.encodeCall(ITreasury.collect, (PARK, alice, _legs(3_720_000, 210_000, 70_000)))
        );
        (, bool settled, uint128 reservedTotal, uint256 requestId) = _commit(commitId);
        assertFalse(settled);
        assertEq(reservedTotal, 0);
        assertEq(requestId, 1);

        coordinator.fulfill(1, keccak256("pack"));
        draw.settle(commitId);
        assertEq(treasury.callCount(), 1, "nothing reserved, nothing paid");
        // Four rolls in order unit * draws + draw, aggregated per class for one mintBatch.
        DrawTables.Row[] memory table = draw.rows(PARK, LaunchTerms.PARK_PACK, 0);
        uint256[] memory counts = new uint256[](8);
        for (uint256 i; i < 4; ++i) {
            uint16 roll = draw.rollFor(commitId, i);
            uint256 cumulative;
            for (uint256 r; r < table.length; ++r) {
                cumulative += table[r].weightBps;
                if (roll < cumulative) {
                    ++counts[table[r].classId];
                    break;
                }
            }
        }
        uint256 minted;
        for (uint256 ball = 1; ball <= 7; ++ball) {
            assertEq(parkItems.balanceOf(wallet, ball), counts[ball], "ball count");
            minted += counts[ball];
        }
        assertEq(minted, 4);
        assertEq(parkItems.callCount(), 1, "one mintBatch");
    }

    function testParkGen6PackSplitMatchesDeployedFees() public {
        vm.prank(alice);
        draw.commit(PARK, LaunchTerms.PARK_PACK, STRIKER, 10, 0, 0);
        assertEq(
            treasury.calls(0),
            abi.encodeCall(ITreasury.collect, (PARK, alice, _legs(18_000_000, 1_500_000, 500_000)))
        );
    }

    function testParkKickGoldenBootGen6() public {
        parkItems.mint(strikerWallet, 7, 3);
        vm.prank(alice);
        vm.expectRevert(DrawModule.InvalidQuantity.selector);
        draw.commit(PARK, LaunchTerms.parkKickAction(7), STRIKER, 2, 0, 0);

        uint16[3] memory rolls = [uint16(150), 0, 5500];
        uint128[3] memory prizes = [uint128(32e6), 64e6, 0];
        uint8[3] memory rowsHit = [uint8(1), 0, 6];
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            vm.expectEmit(address(draw));
            emit DrawModule.Committed(
                i + 1, PARK, STRIKER, strikerWallet, 8, 1, 6, 64e6, i + 1, 0, 0
            );
            uint256 commitId = draw.commit(PARK, LaunchTerms.parkKickAction(7), STRIKER, 1, 0, 0);
            uint256 n = treasury.callCount();
            assertEq(parkItems.calls(i + 1), abi.encodeCall(IGameItems.burn, (strikerWallet, 7, 1)));
            assertEq(treasury.calls(n - 1), abi.encodeCall(ITreasury.reserve, (PARK, 64e6)));
            assertEq(_reserved(PARK), 64e6, "a kick reserves exactly its maximum");

            coordinator.fulfill(commitId, _wordFor(commitId, rolls[i]));
            uint8[] memory rowsOut = new uint8[](1);
            rowsOut[0] = rowsHit[i];
            vm.expectEmit(address(draw));
            emit DrawModule.Settled(commitId, PARK, STRIKER, strikerWallet, rowsOut, prizes[i], 0);
            draw.settle(commitId);
            assertEq(
                treasury.calls(n),
                abi.encodeCall(ITreasury.resolve, (PARK, 64e6, 0, 0, strikerWallet, prizes[i]))
            );
            assertEq(_reserved(PARK), 0, "the remainder returns to free");
        }
        assertEq(parkItems.callCount(), 4, "no mint for a kick");
        assertEq(_free(PARK), 5000e6 - 32e6 - 64e6);
    }

    function testParkKickNeedsFreeBankrollForItsMaximum() public {
        parkItems.mint(strikerWallet, 7, 1);
        parkItems.mint(strikerWallet, 1, 1);
        treasury.setFree(PARK, 64e6 - 1);
        vm.prank(alice);
        vm.expectRevert(StubTreasury.InsufficientFree.selector);
        draw.commit(PARK, LaunchTerms.parkKickAction(7), STRIKER, 1, 0, 0);
        assertEq(parkItems.balanceOf(strikerWallet, 7), 1, "the ball survives a reverted kick");
        // A Scuffed kick needs only 2 USDG, and works on a retired game.
        registry.setActive(PARK, false);
        vm.prank(alice);
        draw.commit(PARK, LaunchTerms.parkKickAction(1), STRIKER, 1, 0, 0);
        assertEq(_reserved(PARK), 2e6);
    }

    function testParkGenerationSnapshotDrivesTheTable() public {
        parkItems.mint(wallet, 7, 1);
        vm.prank(alice);
        uint256 commitId = draw.commit(PARK, LaunchTerms.parkKickAction(7), FRIEND, 1, 0, 0);
        (uint8 generation,,,) = _commit(commitId);
        assertEq(generation, 3);
        generations.promote(FRIEND); // gen 2 after commit changes nothing committed
        // Roll 5650 is the gen 3 2-USDG row (1600 + 4050 = 5650 is the first saved roll - 1).
        coordinator.fulfill(1, _wordFor(commitId, 5649));
        draw.settle(commitId);
        assertEq(
            treasury.calls(1), abi.encodeCall(ITreasury.resolve, (PARK, 64e6, 0, 0, wallet, 2e6))
        );
    }
}
