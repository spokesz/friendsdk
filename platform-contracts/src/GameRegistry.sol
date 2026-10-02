// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { Ownable2Step } from "./access/Ownable2Step.sol";
import { GameItems } from "./GameItems.sol";
import { IGenerations } from "./interfaces/IExternal.sol";
import { IGameItems } from "./interfaces/IGameItems.sol";
import { IGameModule } from "./interfaces/IGameModule.sol";
import { IGameRegistry } from "./interfaces/IGameRegistry.sol";

/// @notice The platform's only owned contract: module allowlist, game records, module bindings,
/// per-game item collections, the custody executor key and the global custody replay table.
/// @dev The owner is the Rare Friends multisig. Every owner power is enumerated here; the owner
/// never touches terms, ledgers or items. Treasury, coordinator and collections read this record.
contract GameRegistry is Ownable2Step, IGameRegistry {
    bytes32 public constant ROUND_LINEAGE = keccak256("Round");

    address public immutable generations;
    address public immutable rf;
    address public immutable usdg;
    // FriendCustody.
    address public immutable custody;
    // Rotatable platform key; zero disables every custody path.
    address public custodyExecutor;
    // One replay namespace across modules, games and succession.
    mapping(bytes32 actionId => bool) public custodyActionUsed;
    uint256 public gameCount;
    // Nonzero = allowlisted. There is no revocation.
    mapping(address module => bytes32 lineage) public lineageOf;
    mapping(uint256 gameId => Game) private _games;
    mapping(uint256 gameId => mapping(address module => Binding)) public bindingOf;

    error OwnershipRequired();
    error InvalidConfiguration();
    error ModuleNotAllowed();
    error ModuleAlreadyAllowed();
    error UnknownGame();
    error WrongStatus();
    error LineageMismatch();
    error AlreadyBound();
    error TermsMismatch();
    error SettlerRule();
    error NoItems();
    error NotBoundModule();
    error InvalidCustodyAction();
    error ModuleBusy();

    event ModuleAllowed(address indexed module, bytes32 indexed lineage);
    event GameCreated(
        uint256 indexed gameId,
        address indexed module,
        address indexed currency,
        address items,
        address funder,
        address developer,
        address operator,
        address settler
    );
    event GameActivated(uint256 indexed gameId, bytes32 termsHash);
    event GameRetired(uint256 indexed gameId);
    event ModuleSucceeded(
        uint256 indexed gameId, address indexed previous, address indexed successor
    );
    event SettlerSet(uint256 indexed gameId, address indexed settler);
    event CustodyExecutorSet(address indexed executor);
    event CustodyActionConsumed(
        bytes32 indexed actionId, uint256 indexed gameId, address indexed module
    );

    constructor(
        address owner_,
        address generations_,
        address rf_,
        address usdg_,
        address custody_,
        address executor_
    ) Ownable(owner_) {
        if (
            generations_.code.length == 0 || rf_.code.length == 0 || usdg_.code.length == 0
                || custody_.code.length == 0 || IGenerations(generations_).token() != rf_
        ) revert InvalidConfiguration();
        generations = generations_;
        rf = rf_;
        usdg = usdg_;
        custody = custody_;
        custodyExecutor = executor_;
    }

    /// @notice The platform always has an owner; renouncing is disabled.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    /// @dev Both bases declare `owner`; the compiler requires naming the one that is used.
    function owner() public view override(Ownable, IGameRegistry) returns (address) {
        return Ownable.owner();
    }

    /// @notice Allowlist a deployed module once; its lineage is read from the module itself.
    function allowModule(address module) external onlyOwner {
        if (module.code.length == 0) revert InvalidConfiguration();
        if (lineageOf[module] != 0) revert ModuleAlreadyAllowed();
        bytes32 lineage = IGameModule(module).LINEAGE();
        if (lineage == 0) revert InvalidConfiguration();
        lineageOf[module] = lineage;
        emit ModuleAllowed(module, lineage);
    }

    /// @notice Register a Draft game on an allowlisted module and deploy its item collection.
    /// @dev The only place `new GameItems` appears. A settler is required exactly for Round games.
    function createGame(
        address module,
        address currency,
        address funder,
        address developer,
        address operator,
        address settler,
        uint256 classCount,
        string calldata uri
    ) external onlyOwner returns (uint256 gameId) {
        bytes32 lineage = lineageOf[module];
        if (lineage == 0) revert ModuleNotAllowed();
        if ((currency != rf && currency != usdg) || funder == address(0)) {
            revert InvalidConfiguration();
        }
        if ((settler != address(0)) != (lineage == ROUND_LINEAGE)) revert SettlerRule();
        gameId = ++gameCount;
        address items = classCount == 0
            ? address(0)
            : address(new GameItems(address(this), gameId, classCount, uri));
        _games[gameId] = Game({
            module: module,
            status: Status.Draft,
            currency: currency,
            items: items,
            funder: funder,
            developer: developer,
            operator: operator,
            settler: settler,
            termsHash: 0
        });
        bindingOf[gameId][module] = Binding.Active;
        emit GameCreated(gameId, module, currency, items, funder, developer, operator, settler);
    }

    /// @notice Draft → Active once the module validates and freezes the game's terms.
    function activateGame(uint256 gameId) external onlyOwner {
        Game storage g = _games[gameId];
        if (g.status != Status.Draft) revert WrongStatus();
        bytes32 hash = IGameModule(g.module).seal(gameId);
        if (hash == 0) revert TermsMismatch();
        g.termsHash = hash;
        g.status = Status.Active;
        emit GameActivated(gameId, hash);
    }

    /// @notice Stops new purchases, deposits, round opens and entries; everything else continues.
    function retireGame(uint256 gameId) external onlyOwner {
        Game storage g = _games[gameId];
        if (g.status != Status.Active) revert WrongStatus();
        g.status = Status.Retired;
        emit GameRetired(gameId);
    }

    /// @notice Hand the game's committing role to a same-lineage module with identical terms.
    /// @dev The predecessor drains: it keeps settling, redeeming and refunding its own commits.
    /// A module whose player locks live in its own storage refuses while they are live.
    function succeedModule(uint256 gameId, address successor) external onlyOwner {
        Game storage g = _games[gameId];
        if (g.status != Status.Active && g.status != Status.Retired) revert WrongStatus();
        address previous = g.module;
        // lineageOf[previous] is nonzero for every registered game, so equality implies
        // allowlisted.
        if (lineageOf[successor] != lineageOf[previous]) revert LineageMismatch();
        if (bindingOf[gameId][successor] != Binding.None) revert AlreadyBound();
        if (!IGameModule(previous).succeedable(gameId)) revert ModuleBusy();
        if (IGameModule(successor).seal(gameId) != g.termsHash) revert TermsMismatch();
        bindingOf[gameId][previous] = Binding.Draining;
        bindingOf[gameId][successor] = Binding.Active;
        g.module = successor;
        emit ModuleSucceeded(gameId, previous, successor);
    }

    /// @notice Rotate the settler of a Round game.
    function setSettler(uint256 gameId, address settler) external onlyOwner {
        Game storage g = _games[gameId];
        if (g.status == Status.None) revert UnknownGame();
        if (lineageOf[g.module] != ROUND_LINEAGE || settler == address(0)) revert SettlerRule();
        g.settler = settler;
        emit SettlerSet(gameId, settler);
    }

    /// @notice Metadata only; the collection emits `URI`.
    function setItemsURI(uint256 gameId, string calldata uri) external onlyOwner {
        address items = _games[gameId].items;
        if (items == address(0)) revert NoItems();
        IGameItems(items).setURI(uri);
    }

    /// @notice Rotate the custody executor key; zero disables every custody path.
    function setCustodyExecutor(address executor) external onlyOwner {
        custodyExecutor = executor;
        emit CustodyExecutorSet(executor);
    }

    /// @notice A bound module spends a custody action id exactly once, platform-wide.
    function consumeCustodyAction(bytes32 actionId, uint256 gameId) external {
        if (bindingOf[gameId][msg.sender] == Binding.None) revert NotBoundModule();
        if (actionId == 0 || custodyActionUsed[actionId]) revert InvalidCustodyAction();
        custodyActionUsed[actionId] = true;
        emit CustodyActionConsumed(actionId, gameId, msg.sender);
    }

    function game(uint256 gameId) external view returns (Game memory) {
        Game memory g = _games[gameId];
        if (g.status == Status.None) revert UnknownGame();
        return g;
    }

    function currentModule(uint256 gameId) external view returns (address) {
        return _games[gameId].module;
    }

    function isActive(uint256 gameId) external view returns (bool) {
        return _games[gameId].status == Status.Active;
    }

    function isBound(uint256 gameId, address module) external view returns (bool) {
        return bindingOf[gameId][module] != Binding.None;
    }

    function canCommit(uint256 gameId, address module) external view returns (bool) {
        Game storage g = _games[gameId];
        return g.status == Status.Active && g.module == module;
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

    function recipientsOf(uint256 gameId)
        external
        view
        returns (address funder, address developer, address operator)
    {
        Game storage g = _games[gameId];
        return (g.funder, g.developer, g.operator);
    }
}
