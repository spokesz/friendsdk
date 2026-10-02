// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test, Vm } from "forge-std/Test.sol";
import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { GameItems } from "../src/GameItems.sol";
import { GameRegistry } from "../src/GameRegistry.sol";
import { IGameModule } from "../src/interfaces/IGameModule.sol";
import { IGameRegistry } from "../src/interfaces/IGameRegistry.sol";
import { MockCustody, MockGenerations, MockRF, MockUSDG } from "./doubles/ExternalDoubles.sol";

/// @dev A module as the registry sees it: a lineage and a seal the test scripts per game.
contract StubModule is IGameModule {
    bytes32 public immutable LINEAGE;
    address public lastSealer;
    mapping(uint256 gameId => bytes32) public termsHash;

    constructor(bytes32 lineage) {
        LINEAGE = lineage;
    }

    function setTerms(uint256 gameId, bytes32 hash) external {
        termsHash[gameId] = hash;
    }

    function seal(uint256 gameId) external returns (bytes32) {
        lastSealer = msg.sender;
        return termsHash[gameId];
    }

    bool public busy;

    function setBusy(bool value) external {
        busy = value;
    }

    function succeedable(uint256) external view returns (bool) {
        return !busy;
    }
}

contract GameRegistryTest is Test {
    bytes32 internal constant DRAW = keccak256("Draw");
    bytes32 internal constant ROUND = keccak256("Round");
    bytes32 internal constant TERMS = keccak256("terms");

    MockRF internal rf;
    MockUSDG internal usdg;
    MockGenerations internal generations;
    MockCustody internal custody;
    GameRegistry internal registry;
    StubModule internal draw;
    StubModule internal drawV2;
    StubModule internal round;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal funder = makeAddr("funder");
    address internal developer = makeAddr("developer");
    address internal operator = makeAddr("operator");
    address internal settler = makeAddr("settler");
    address internal executor = makeAddr("executor");

    function setUp() public {
        rf = new MockRF();
        usdg = new MockUSDG(6);
        generations = new MockGenerations(address(rf));
        custody = new MockCustody();
        registry = new GameRegistry(
            owner, address(generations), address(rf), address(usdg), address(custody), executor
        );
        draw = new StubModule(DRAW);
        drawV2 = new StubModule(DRAW);
        round = new StubModule(ROUND);
        vm.startPrank(owner);
        registry.allowModule(address(draw));
        registry.allowModule(address(round));
        vm.stopPrank();
    }

    function _createDraw(uint256 classCount) internal returns (uint256 gameId) {
        vm.prank(owner);
        gameId = registry.createGame(
            address(draw), address(rf), funder, developer, operator, address(0), classCount, "u"
        );
    }

    function _createRound() internal returns (uint256 gameId) {
        vm.prank(owner);
        gameId = registry.createGame(
            address(round), address(rf), funder, address(0), address(0), settler, 0, ""
        );
    }

    function _activate(StubModule module, uint256 gameId) internal {
        module.setTerms(gameId, TERMS);
        vm.prank(owner);
        registry.activateGame(gameId);
    }

    // ---- construction -------------------------------------------------------------------------

    function testConstructorRecordsConfiguration() public view {
        assertEq(registry.owner(), owner);
        assertEq(address(registry.generations()), address(generations));
        assertEq(registry.rf(), address(rf));
        assertEq(registry.usdg(), address(usdg));
        assertEq(registry.custody(), address(custody));
        assertEq(registry.custodyExecutor(), executor);
        assertEq(registry.ROUND_LINEAGE(), ROUND);
        assertEq(registry.gameCount(), 0);
    }

    function testConstructorAllowsZeroExecutor() public {
        GameRegistry r = new GameRegistry(
            owner, address(generations), address(rf), address(usdg), address(custody), address(0)
        );
        assertEq(r.custodyExecutor(), address(0));
    }

    function testConstructorRejectsAddressesWithoutCode() public {
        address g = address(generations);
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        new GameRegistry(owner, stranger, address(rf), address(usdg), address(custody), executor);
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        new GameRegistry(owner, g, stranger, address(usdg), address(custody), executor);
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        new GameRegistry(owner, g, address(rf), stranger, address(custody), executor);
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        new GameRegistry(owner, g, address(rf), address(usdg), stranger, executor);
    }

    function testConstructorRejectsRfNotMatchingGenerationsToken() public {
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        new GameRegistry(
            owner, address(generations), address(usdg), address(usdg), address(custody), executor
        );
    }

    function testConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new GameRegistry(
            address(0), address(generations), address(rf), address(usdg), address(custody), executor
        );
    }

    // ---- ownership -----------------------------------------------------------------------------

    function testRenounceOwnershipAlwaysReverts() public {
        vm.prank(owner);
        vm.expectRevert(GameRegistry.OwnershipRequired.selector);
        registry.renounceOwnership();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.renounceOwnership();
        assertEq(registry.owner(), owner);
    }

    function testOwnershipTransfersInTwoSteps() public {
        address next = makeAddr("next");
        vm.prank(owner);
        registry.transferOwnership(next);
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), next);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.acceptOwnership();
        vm.prank(next);
        registry.acceptOwnership();
        assertEq(registry.owner(), next);
        assertEq(registry.pendingOwner(), address(0));
    }

    /// @dev Every non-view selector of the registry, with the owner surface listed in 10.1 first.
    function testOwnerSurfaceIsExactlyEnumerated() public {
        uint256 gameId = _createDraw(1);
        bytes[] memory ownerCalls = new bytes[](10);
        ownerCalls[0] = abi.encodeCall(registry.allowModule, (address(drawV2)));
        ownerCalls[1] = abi.encodeCall(
            registry.createGame,
            (address(draw), address(rf), funder, developer, operator, address(0), 1, "u")
        );
        ownerCalls[2] = abi.encodeCall(registry.activateGame, (gameId));
        ownerCalls[3] = abi.encodeCall(registry.retireGame, (gameId));
        ownerCalls[4] = abi.encodeCall(registry.succeedModule, (gameId, address(drawV2)));
        ownerCalls[5] = abi.encodeCall(registry.setSettler, (gameId, settler));
        ownerCalls[6] = abi.encodeCall(registry.setItemsURI, (gameId, "v"));
        ownerCalls[7] = abi.encodeCall(registry.setCustodyExecutor, (stranger));
        ownerCalls[8] = abi.encodeCall(registry.transferOwnership, (stranger));
        ownerCalls[9] = abi.encodeCall(registry.renounceOwnership, ());
        bytes memory unauthorized =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        for (uint256 i; i < ownerCalls.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(registry).call(ownerCalls[i]);
            assertFalse(ok, "owner call succeeded for a stranger");
            assertEq(ret, unauthorized, "owner call failed for another reason");
        }
        // The two remaining writers are not owner powers and refuse a stranger on their own rule.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.acceptOwnership();
        vm.prank(stranger);
        vm.expectRevert(GameRegistry.NotBoundModule.selector);
        registry.consumeCustodyAction(bytes32(uint256(1)), gameId);
    }

    // ---- allowModule ---------------------------------------------------------------------------

    function testAllowModuleRecordsLineage() public {
        assertEq(registry.lineageOf(address(draw)), DRAW);
        assertEq(registry.lineageOf(address(round)), ROUND);
        assertEq(registry.lineageOf(address(drawV2)), bytes32(0));
        vm.expectEmit(address(registry));
        emit GameRegistry.ModuleAllowed(address(drawV2), DRAW);
        vm.prank(owner);
        registry.allowModule(address(drawV2));
        assertEq(registry.lineageOf(address(drawV2)), DRAW);
    }

    function testAllowModuleRejectsRepeatsNoCodeAndZeroLineage() public {
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.ModuleAlreadyAllowed.selector);
        registry.allowModule(address(draw));
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        registry.allowModule(stranger);
        StubModule noLineage = new StubModule(0);
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        registry.allowModule(address(noLineage));
        vm.stopPrank();
    }

    // ---- createGame ----------------------------------------------------------------------------

    function testCreateGameDeploysItemsAndRecordsTheGame() public {
        vm.recordLogs();
        uint256 gameId = _createDraw(5);
        assertEq(gameId, 1);
        assertEq(registry.gameCount(), 1);

        IGameRegistry.Game memory g = registry.game(gameId);
        assertEq(g.module, address(draw));
        assertEq(uint8(g.status), uint8(IGameRegistry.Status.Draft));
        assertEq(g.currency, address(rf));
        assertEq(g.funder, funder);
        assertEq(g.developer, developer);
        assertEq(g.operator, operator);
        assertEq(g.settler, address(0));
        assertEq(g.termsHash, bytes32(0));
        assertTrue(g.items != address(0));

        GameItems items = GameItems(g.items);
        assertEq(address(items.registry()), address(registry));
        assertEq(items.gameId(), gameId);
        assertEq(items.classCount(), 5);
        assertEq(items.uri(1), "u");

        assertEq(
            uint8(registry.bindingOf(gameId, address(draw))), uint8(IGameRegistry.Binding.Active)
        );
        assertEq(registry.currentModule(gameId), address(draw));
        assertEq(registry.itemsOf(gameId), g.items);
        assertEq(registry.currencyOf(gameId), address(rf));
        assertTrue(registry.isBound(gameId, address(draw)));
        assertFalse(registry.isActive(gameId));
        assertFalse(registry.canCommit(gameId, address(draw)));
        (address f, address d, address o) = registry.recipientsOf(gameId);
        assertEq(f, funder);
        assertEq(d, developer);
        assertEq(o, operator);

        // GameCreated is the last log of the transaction and names the deployed collection.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory created = logs[logs.length - 1];
        assertEq(created.topics[0], GameRegistry.GameCreated.selector);
        assertEq(created.topics[1], bytes32(gameId));
        assertEq(created.topics[2], bytes32(uint256(uint160(address(draw)))));
        assertEq(created.topics[3], bytes32(uint256(uint160(address(rf)))));
        (address items_, address f_, address d_, address o_, address s_) =
            abi.decode(created.data, (address, address, address, address, address));
        assertEq(items_, g.items);
        assertEq(f_, funder);
        assertEq(d_, developer);
        assertEq(o_, operator);
        assertEq(s_, address(0));
    }

    function testCreateGameWithoutClassesHasNoItems() public {
        uint256 gameId = _createRound();
        assertEq(registry.itemsOf(gameId), address(0));
        assertEq(registry.settlerOf(gameId), settler);
        assertEq(registry.game(gameId).items, address(0));
    }

    function testCreateGameAcceptsUsdgAndNumbersGamesSequentially() public {
        vm.prank(owner);
        uint256 a = registry.createGame(
            address(draw), address(usdg), funder, developer, operator, address(0), 7, ""
        );
        uint256 b = _createRound();
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(registry.currencyOf(a), address(usdg));
        assertEq(registry.gameCount(), 2);
    }

    function testCreateGameRejectsUnknownModuleCurrencyAndFunder() public {
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.ModuleNotAllowed.selector);
        registry.createGame(
            address(drawV2), address(rf), funder, developer, operator, address(0), 1, ""
        );
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        registry.createGame(address(draw), stranger, funder, developer, operator, address(0), 1, "");
        vm.expectRevert(GameRegistry.InvalidConfiguration.selector);
        registry.createGame(
            address(draw), address(rf), address(0), developer, operator, address(0), 1, ""
        );
        vm.stopPrank();
    }

    function testSettlerRuleBothWays() public {
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.SettlerRule.selector);
        registry.createGame(address(draw), address(rf), funder, developer, operator, settler, 1, "");
        vm.expectRevert(GameRegistry.SettlerRule.selector);
        registry.createGame(
            address(round), address(rf), funder, address(0), address(0), address(0), 0, ""
        );
        vm.stopPrank();
    }

    function testCreateGamePropagatesItemsConfigurationError() public {
        vm.prank(owner);
        vm.expectRevert(GameItems.InvalidConfiguration.selector);
        registry.createGame(
            address(draw), address(rf), funder, developer, operator, address(0), 65, ""
        );
        assertEq(registry.gameCount(), 0);
    }

    // ---- activate and retire -------------------------------------------------------------------

    function testActivateGameSealsAndRecordsTermsHash() public {
        uint256 gameId = _createDraw(1);
        draw.setTerms(gameId, TERMS);
        vm.expectEmit(address(registry));
        emit GameRegistry.GameActivated(gameId, TERMS);
        vm.prank(owner);
        registry.activateGame(gameId);
        assertEq(draw.lastSealer(), address(registry));
        assertEq(registry.game(gameId).termsHash, TERMS);
        assertEq(uint8(registry.game(gameId).status), uint8(IGameRegistry.Status.Active));
        assertTrue(registry.isActive(gameId));
        assertTrue(registry.canCommit(gameId, address(draw)));
        assertFalse(registry.canCommit(gameId, address(drawV2)));
    }

    function testActivateGameRequiresNonzeroSeal() public {
        uint256 gameId = _createDraw(1);
        vm.prank(owner);
        vm.expectRevert(GameRegistry.TermsMismatch.selector);
        registry.activateGame(gameId);
        assertEq(uint8(registry.game(gameId).status), uint8(IGameRegistry.Status.Draft));
    }

    function testActivateGameOnlyFromDraft() public {
        uint256 gameId = _createDraw(1);
        _activate(draw, gameId);
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.WrongStatus.selector);
        registry.activateGame(gameId);
        vm.expectRevert(GameRegistry.WrongStatus.selector);
        registry.activateGame(99);
        vm.stopPrank();
    }

    function testRetireGameOnlyFromActive() public {
        uint256 gameId = _createDraw(1);
        vm.prank(owner);
        vm.expectRevert(GameRegistry.WrongStatus.selector);
        registry.retireGame(gameId);

        _activate(draw, gameId);
        vm.expectEmit(address(registry));
        emit GameRegistry.GameRetired(gameId);
        vm.prank(owner);
        registry.retireGame(gameId);
        assertEq(uint8(registry.game(gameId).status), uint8(IGameRegistry.Status.Retired));
        assertFalse(registry.isActive(gameId));
        assertFalse(registry.canCommit(gameId, address(draw)));
        // Retirement never unbinds: the module keeps settling and redeeming.
        assertTrue(registry.isBound(gameId, address(draw)));
        assertEq(registry.currentModule(gameId), address(draw));

        vm.prank(owner);
        vm.expectRevert(GameRegistry.WrongStatus.selector);
        registry.retireGame(gameId);
    }

    // ---- succession ----------------------------------------------------------------------------

    function testSucceedModuleFlipsBindingsAndKeepsPredecessorBound() public {
        uint256 gameId = _createDraw(1);
        _activate(draw, gameId);
        vm.prank(owner);
        registry.allowModule(address(drawV2));
        drawV2.setTerms(gameId, TERMS);

        vm.expectEmit(address(registry));
        emit GameRegistry.ModuleSucceeded(gameId, address(draw), address(drawV2));
        vm.prank(owner);
        registry.succeedModule(gameId, address(drawV2));

        assertEq(drawV2.lastSealer(), address(registry));
        assertEq(registry.currentModule(gameId), address(drawV2));
        assertEq(
            uint8(registry.bindingOf(gameId, address(draw))), uint8(IGameRegistry.Binding.Draining)
        );
        assertEq(
            uint8(registry.bindingOf(gameId, address(drawV2))), uint8(IGameRegistry.Binding.Active)
        );
        assertTrue(registry.isBound(gameId, address(draw)));
        assertTrue(registry.isBound(gameId, address(drawV2)));
        assertFalse(registry.canCommit(gameId, address(draw)));
        assertTrue(registry.canCommit(gameId, address(drawV2)));
        assertEq(registry.game(gameId).termsHash, TERMS);
        // The collection follows the registry: v2 may mint, v1 still may.
        GameItems items = GameItems(registry.itemsOf(gameId));
        address wallet = makeAddr("wallet");
        vm.prank(address(drawV2));
        items.mintBatch(wallet, _single(1), _single(1));
        vm.prank(address(draw));
        items.burn(wallet, 1, 1);
    }

    function testSucceedModuleWorksOnRetiredGame() public {
        uint256 gameId = _createDraw(1);
        _activate(draw, gameId);
        vm.startPrank(owner);
        registry.retireGame(gameId);
        registry.allowModule(address(drawV2));
        drawV2.setTerms(gameId, TERMS);
        registry.succeedModule(gameId, address(drawV2));
        vm.stopPrank();
        assertEq(registry.currentModule(gameId), address(drawV2));
        assertFalse(registry.canCommit(gameId, address(drawV2)));
    }

    function testSucceedModuleRefusesDraftAndUnknownGames() public {
        uint256 gameId = _createDraw(1);
        vm.startPrank(owner);
        registry.allowModule(address(drawV2));
        vm.expectRevert(GameRegistry.WrongStatus.selector);
        registry.succeedModule(gameId, address(drawV2));
        vm.expectRevert(GameRegistry.WrongStatus.selector);
        registry.succeedModule(42, address(drawV2));
        vm.stopPrank();
    }

    function testSucceedModuleRefusesOtherLineageAndUnlistedModules() public {
        uint256 gameId = _createDraw(1);
        _activate(draw, gameId);
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.LineageMismatch.selector);
        registry.succeedModule(gameId, address(round));
        vm.expectRevert(GameRegistry.LineageMismatch.selector);
        registry.succeedModule(gameId, address(drawV2));
        vm.expectRevert(GameRegistry.LineageMismatch.selector);
        registry.succeedModule(gameId, stranger);
        vm.stopPrank();
    }

    function testSucceedModuleRefusesAlreadyBoundModules() public {
        uint256 gameId = _createDraw(1);
        _activate(draw, gameId);
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.AlreadyBound.selector);
        registry.succeedModule(gameId, address(draw));
        registry.allowModule(address(drawV2));
        drawV2.setTerms(gameId, TERMS);
        registry.succeedModule(gameId, address(drawV2));
        // Going back to the draining predecessor is refused too: it is still bound.
        vm.expectRevert(GameRegistry.AlreadyBound.selector);
        registry.succeedModule(gameId, address(draw));
        vm.stopPrank();
    }

    function testSucceedModuleRequiresIdenticalTerms() public {
        uint256 gameId = _createDraw(1);
        _activate(draw, gameId);
        vm.startPrank(owner);
        registry.allowModule(address(drawV2));
        vm.expectRevert(GameRegistry.TermsMismatch.selector);
        registry.succeedModule(gameId, address(drawV2));
        drawV2.setTerms(gameId, keccak256("other terms"));
        vm.expectRevert(GameRegistry.TermsMismatch.selector);
        registry.succeedModule(gameId, address(drawV2));
        vm.stopPrank();
        assertEq(registry.currentModule(gameId), address(draw));
        assertFalse(registry.isBound(gameId, address(drawV2)));
    }

    // ---- setSettler, setItemsURI, setCustodyExecutor ------------------------------------------

    function testSetSettlerRoundOnly() public {
        uint256 drawId = _createDraw(1);
        uint256 roundId = _createRound();
        address next = makeAddr("nextSettler");
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.UnknownGame.selector);
        registry.setSettler(99, next);
        vm.expectRevert(GameRegistry.SettlerRule.selector);
        registry.setSettler(drawId, next);
        vm.expectRevert(GameRegistry.SettlerRule.selector);
        registry.setSettler(roundId, address(0));
        vm.expectEmit(address(registry));
        emit GameRegistry.SettlerSet(roundId, next);
        registry.setSettler(roundId, next);
        vm.stopPrank();
        assertEq(registry.settlerOf(roundId), next);
        assertEq(registry.settlerOf(drawId), address(0));
    }

    function testSetItemsURIForwardsToTheCollection() public {
        uint256 drawId = _createDraw(2);
        uint256 roundId = _createRound();
        vm.startPrank(owner);
        vm.expectRevert(GameRegistry.NoItems.selector);
        registry.setItemsURI(roundId, "x");
        vm.expectRevert(GameRegistry.NoItems.selector);
        registry.setItemsURI(99, "x");
        registry.setItemsURI(drawId, "ipfs://new/{id}");
        vm.stopPrank();
        assertEq(GameItems(registry.itemsOf(drawId)).uri(2), "ipfs://new/{id}");
    }

    function testCustodyExecutorRotatesAndMayBeDisabled() public {
        address next = makeAddr("nextExecutor");
        vm.expectEmit(address(registry));
        emit GameRegistry.CustodyExecutorSet(next);
        vm.prank(owner);
        registry.setCustodyExecutor(next);
        assertEq(registry.custodyExecutor(), next);
        vm.prank(owner);
        registry.setCustodyExecutor(address(0));
        assertEq(registry.custodyExecutor(), address(0));
    }

    // ---- consumeCustodyAction ------------------------------------------------------------------

    function testConsumeCustodyActionOnlyByBoundModuleOfThatGame() public {
        uint256 gameId = _createDraw(1);
        bytes32 id = keccak256("order-1");
        vm.prank(stranger);
        vm.expectRevert(GameRegistry.NotBoundModule.selector);
        registry.consumeCustodyAction(id, gameId);
        vm.prank(owner);
        vm.expectRevert(GameRegistry.NotBoundModule.selector);
        registry.consumeCustodyAction(id, gameId);
        // Allowlisted but not bound to this game.
        vm.prank(address(round));
        vm.expectRevert(GameRegistry.NotBoundModule.selector);
        registry.consumeCustodyAction(id, gameId);
        vm.prank(address(draw));
        vm.expectRevert(GameRegistry.NotBoundModule.selector);
        registry.consumeCustodyAction(id, gameId + 1);
        assertFalse(registry.custodyActionUsed(id));

        vm.expectEmit(address(registry));
        emit GameRegistry.CustodyActionConsumed(id, gameId, address(draw));
        vm.prank(address(draw));
        registry.consumeCustodyAction(id, gameId);
        assertTrue(registry.custodyActionUsed(id));
    }

    function testConsumeCustodyActionNeverTwiceAcrossGamesAndModules() public {
        uint256 a = _createDraw(1);
        uint256 b = _createRound();
        bytes32 id = keccak256("order-2");
        vm.prank(address(draw));
        registry.consumeCustodyAction(id, a);
        vm.prank(address(draw));
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        registry.consumeCustodyAction(id, a);
        vm.prank(address(round));
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        registry.consumeCustodyAction(id, b);
    }

    function testConsumeCustodyActionRejectsZeroId() public {
        uint256 gameId = _createDraw(1);
        vm.prank(address(draw));
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        registry.consumeCustodyAction(bytes32(0), gameId);
    }

    function testDrainingModuleStillConsumesButSuccessorCannotReplay() public {
        uint256 gameId = _createDraw(1);
        _activate(draw, gameId);
        bytes32 before = keccak256("fulfilled-on-v1");
        vm.prank(address(draw));
        registry.consumeCustodyAction(before, gameId);
        vm.startPrank(owner);
        registry.allowModule(address(drawV2));
        drawV2.setTerms(gameId, TERMS);
        registry.succeedModule(gameId, address(drawV2));
        vm.stopPrank();
        vm.prank(address(drawV2));
        vm.expectRevert(GameRegistry.InvalidCustodyAction.selector);
        registry.consumeCustodyAction(before, gameId);
        vm.prank(address(draw));
        registry.consumeCustodyAction(keccak256("late-v1-order"), gameId);
    }

    // ---- views ---------------------------------------------------------------------------------

    function testViewsOnUnknownGame() public {
        vm.expectRevert(GameRegistry.UnknownGame.selector);
        registry.game(1);
        assertEq(registry.currentModule(1), address(0));
        assertFalse(registry.isActive(1));
        assertFalse(registry.isBound(1, address(draw)));
        assertFalse(registry.canCommit(1, address(draw)));
        assertEq(registry.currencyOf(1), address(0));
        assertEq(registry.itemsOf(1), address(0));
        assertEq(registry.settlerOf(1), address(0));
        (address f, address d, address o) = registry.recipientsOf(1);
        assertEq(f, address(0));
        assertEq(d, address(0));
        assertEq(o, address(0));
    }

    function testGameRecordDecodesThroughTheSharedInterface() public {
        uint256 gameId = _createDraw(3);
        IGameRegistry viewed = IGameRegistry(address(registry));
        IGameRegistry.Game memory g = viewed.game(gameId);
        assertEq(g.module, address(draw));
        assertEq(uint8(g.status), uint8(IGameRegistry.Status.Draft));
        assertEq(g.items, registry.itemsOf(gameId));
        assertEq(g.funder, funder);
        assertEq(viewed.owner(), owner);
        assertEq(viewed.generations(), address(generations));
        assertTrue(viewed.isBound(gameId, address(draw)));
    }

    function _single(uint256 value) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = value;
    }
}
