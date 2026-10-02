// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { IGenerations } from "./interfaces/IExternal.sol";
import { IGameItems } from "./interfaces/IGameItems.sol";
import { IGameModule } from "./interfaces/IGameModule.sol";
import { IGameRegistry } from "./interfaces/IGameRegistry.sol";
import { IRandomnessCoordinator } from "./interfaces/IRandomnessCoordinator.sol";
import { ITreasury } from "./interfaces/ITreasury.sol";
import { DrawTables } from "./libraries/DrawTables.sol";
import { FriendAccess } from "./libraries/FriendAccess.sol";
import { Rolls } from "./libraries/Rolls.sol";

/// @notice Declarative weighted-draw engine serving every Draw game by id (Rare Breeds, Penalty
/// Kings). Terms are defined by the registry owner and frozen at activation; a commit reserves
/// its maximum value in the Treasury, one-row tables settle inline, every other table settles
/// from the coordinator's word. The module holds no funds.
contract DrawModule is IGameModule, ReentrancyGuard {
    struct Commit {
        uint256 gameId;
        uint256 friendId;
        uint8 actionId;
        uint8 quantity;
        // Snapshotted at commit; drives the table and the split.
        uint8 generation;
        bool settled;
        // Backing locked by this commit; resolved at settlement.
        uint128 reservedTotal;
        // Zero when the table had one row (settled inline).
        uint256 requestId;
    }

    /// @dev Rolls, mint counts and ledger legs of one settlement.
    struct Outcome {
        uint8[] rows;
        // Units minted per class id; index 0 is unused.
        uint256[] counts;
        uint256 distinct;
        uint256 paid;
        uint256 owed;
        uint256 keep;
    }

    bytes32 public constant LINEAGE = keccak256("Draw");

    IGameRegistry public immutable registry;
    ITreasury public immutable treasury;
    IRandomnessCoordinator public immutable coordinator;
    IGenerations public immutable generations;

    // Terms, per game; immutable once sealed.
    mapping(uint256 gameId => bool) public isSealed;
    mapping(uint256 gameId => bytes32) public runningHash;
    mapping(uint256 gameId => uint8) public actionCount;
    // Index classId - 1.
    mapping(uint256 gameId => DrawTables.Class[]) private _classes;
    mapping(uint256 gameId => mapping(uint8 actionId => DrawTables.Action)) public actions;
    // Generation 1..6.
    mapping(
        uint256 gameId => mapping(uint8 actionId => mapping(uint8 generation => DrawTables.Split))
    ) public splits;
    // Table index 0, or 1..6 by generation.
    mapping(
        uint256 gameId => mapping(uint8 actionId => mapping(uint8 tableIndex => DrawTables.Row[]))
    ) private _rows;
    mapping(uint256 gameId => mapping(uint8 actionId => mapping(uint8 tableIndex => uint128)))
        public maxPayable;
    // Play state.
    uint256 public commitCount;
    mapping(uint256 commitId => Commit) public commits;

    error InvalidConfiguration();
    error NotRegistryOwner();
    error OnlyRegistry();
    error Sealed();
    error NotSealed();
    error ClassesAlreadyDefined();
    error ClassCountMismatch();
    error TooManyActions();
    error InvalidAction();
    error InvalidSplit();
    error InvalidClass();
    error NotCurrentModule();
    error GameNotActive();
    error UnknownAction();
    error InvalidQuantity();
    error OnlyCustodyExecutor();
    error UnknownCommit();
    error AlreadySettled();
    error RandomnessPending();
    error NotRedeemable();
    error ZeroQuantity();
    error NoTerms();

    event ClassesDefined(uint256 indexed gameId, DrawTables.Class[] classes);
    event ActionDefined(
        uint256 indexed gameId,
        uint8 indexed actionId,
        DrawTables.Action action,
        DrawTables.Split[6] splits,
        DrawTables.Row[][] tables,
        uint128[] maxPayable
    );
    event TermsSealed(uint256 indexed gameId, bytes32 termsHash);
    event Committed(
        uint256 indexed commitId,
        uint256 indexed gameId,
        uint256 indexed friendId,
        address wallet,
        uint8 actionId,
        uint8 quantity,
        uint8 generation,
        uint256 reservedTotal,
        uint256 requestId,
        bytes32 context,
        bytes32 custodyActionId
    );
    event Settled(
        uint256 indexed commitId,
        uint256 indexed gameId,
        uint256 indexed friendId,
        address wallet,
        uint8[] rows,
        uint256 paid,
        uint256 owed
    );
    event Redeemed(
        uint256 indexed gameId,
        uint256 indexed friendId,
        address indexed wallet,
        uint16 classId,
        uint256 quantity,
        uint256 amount,
        bytes32 custodyActionId
    );

    constructor(address registry_, address treasury_, address coordinator_, address generations_) {
        if (
            registry_.code.length == 0 || treasury_.code.length == 0
                || coordinator_.code.length == 0 || generations_.code.length == 0
                || IGameRegistry(registry_).generations() != generations_
        ) revert InvalidConfiguration();
        registry = IGameRegistry(registry_);
        treasury = ITreasury(treasury_);
        coordinator = IRandomnessCoordinator(coordinator_);
        generations = IGenerations(generations_);
    }

    // ------------------------------------------------------------------------------ terms

    /// @notice Owner defines the game's classes once, matching its GameItems class count.
    function defineClasses(uint256 gameId, DrawTables.Class[] calldata list) external {
        _defining(gameId);
        DrawTables.Class[] storage stored = _classes[gameId];
        if (stored.length != 0) revert ClassesAlreadyDefined();
        address items = registry.itemsOf(gameId);
        if (items == address(0) || list.length != IGameItems(items).classCount()) {
            revert ClassCountMismatch();
        }
        for (uint256 i; i < list.length; ++i) {
            if (list[i].value != 0 && list[i].reserve != 0) revert InvalidClass();
            stored.push(list[i]);
        }
        runningHash[gameId] = keccak256(abi.encode(runningHash[gameId], uint8(1), list));
        emit ClassesDefined(gameId, list);
    }

    /// @notice Owner appends one action with its six splits and its table(s); validated here only.
    function defineAction(
        uint256 gameId,
        DrawTables.Action calldata a,
        DrawTables.Split[6] calldata s,
        DrawTables.Row[][] calldata tables
    ) external {
        _defining(gameId);
        DrawTables.Class[] storage classes_ = _classes[gameId];
        if (classes_.length == 0) revert InvalidAction();
        uint8 actionId = actionCount[gameId] + 1;
        if (actionId > DrawTables.MAX_ACTIONS) revert TooManyActions();
        if (
            a.input == DrawTables.Input.None || a.draws == 0 || a.draws > DrawTables.MAX_DRAWS
                || a.maxUnits == 0 || a.maxUnits > DrawTables.MAX_UNITS
                || tables.length != (a.perGeneration ? 6 : 1)
        ) revert InvalidAction();
        if (a.input == DrawTables.Input.Currency) {
            if (a.price == 0) revert InvalidAction();
            _checkSplits(gameId, s);
        } else {
            // A valued class cannot be an input: burning it would leave its liability in owed.
            if (
                a.inputClass == 0 || a.inputClass > classes_.length || a.inputCount == 0
                    || classes_[a.inputClass - 1].value != 0
            ) revert InvalidAction();
            for (uint256 g; g < 6; ++g) {
                DrawTables.Split calldata split = s[g];
                if (
                    split.freeBps != 0 || split.developerBps != 0 || split.operatorBps != 0
                        || split.burnBps != 0 || split.rewardsBps != 0
                ) revert InvalidSplit();
            }
        }
        uint128[] memory maxima = new uint128[](tables.length);
        for (uint256 t; t < tables.length; ++t) {
            // At most six tables, so the index fits.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 index = a.perGeneration ? uint8(t + 1) : 0;
            uint128 maximum = DrawTables.validate(tables[t], classes_);
            // Keeps every commit's reservedTotal (maximum × draws × quantity) in uint128.
            if (uint256(maximum) * a.draws * a.maxUnits > type(uint128).max) {
                revert InvalidAction();
            }
            maxima[t] = maximum;
            maxPayable[gameId][actionId][index] = maximum;
            DrawTables.Row[] storage rows_ = _rows[gameId][actionId][index];
            for (uint256 r; r < tables[t].length; ++r) {
                rows_.push(tables[t][r]);
            }
        }
        actions[gameId][actionId] = a;
        for (uint8 g = 1; g <= 6; ++g) {
            splits[gameId][actionId][g] = s[g - 1];
        }
        actionCount[gameId] = actionId;
        runningHash[gameId] =
            keccak256(abi.encode(runningHash[gameId], uint8(2), actionId, a, s, tables));
        emit ActionDefined(gameId, actionId, a, s, tables, maxima);
    }

    /// @inheritdoc IGameModule
    function seal(uint256 gameId) external returns (bytes32) {
        if (msg.sender != address(registry)) revert OnlyRegistry();
        bytes32 hash = runningHash[gameId];
        if (isSealed[gameId]) return hash;
        if (actionCount[gameId] == 0) revert NoTerms();
        isSealed[gameId] = true;
        emit TermsSealed(gameId, hash);
        return hash;
    }

    /// @inheritdoc IGameModule
    function termsHash(uint256 gameId) external view returns (bytes32) {
        return isSealed[gameId] ? runningHash[gameId] : bytes32(0);
    }

    /// @inheritdoc IGameModule
    /// @dev Always: a pending commit settles on the module that created it, and nothing a Draw
    /// game locks per Friend lives in module storage.
    function succeedable(uint256) external pure returns (bool) {
        return true;
    }

    /// @dev Terms may be written by the registry owner while the game is not sealed.
    function _defining(uint256 gameId) private view {
        if (msg.sender != registry.owner()) revert NotRegistryOwner();
        if (isSealed[gameId]) revert Sealed();
    }

    /// @dev Currency splits: each sums to 10_000 and routes only to legs the game supports.
    function _checkSplits(uint256 gameId, DrawTables.Split[6] calldata s) private view {
        bool isRf = registry.currencyOf(gameId) == registry.rf();
        (, address developer, address operator) = registry.recipientsOf(gameId);
        for (uint256 g; g < 6; ++g) {
            DrawTables.Split calldata split = s[g];
            if (
                uint256(split.freeBps) + split.developerBps + split.operatorBps + split.burnBps
                            + split.rewardsBps != DrawTables.BPS
                    || (!isRf && (split.burnBps != 0 || split.rewardsBps != 0))
                    || (developer == address(0) && split.developerBps != 0)
                    || (operator == address(0) && split.operatorBps != 0)
            ) revert InvalidSplit();
        }
    }

    // ------------------------------------------------------------------------------- play

    /// @notice Commit `quantity` units of an action for a Friend; the caller pays. One-row
    /// tables settle inline, every other table binds one randomness request.
    function commit(
        uint256 gameId,
        uint8 actionId,
        uint256 friendId,
        uint8 quantity,
        bytes32 context,
        bytes32 custodyActionId
    ) external nonReentrant returns (uint256 commitId) {
        if (registry.currentModule(gameId) != address(this)) {
            revert NotCurrentModule();
        }
        if (!isSealed[gameId]) revert NotSealed();
        DrawTables.Action storage a = actions[gameId][actionId];
        if (a.input == DrawTables.Input.None) revert UnknownAction();
        if (quantity == 0 || quantity > a.maxUnits) revert InvalidQuantity();
        (address wallet, uint8 generation) = _access(gameId, friendId, custodyActionId);
        uint8 tableIndex = a.perGeneration ? generation : 0;
        uint128 need = _take(gameId, actionId, a, wallet, generation, quantity, tableIndex);
        commitId = _open(gameId, friendId, actionId, quantity, generation, need);
        bool oneRow = _rows[gameId][actionId][tableIndex].length == 1;
        if (!oneRow) commits[commitId].requestId = coordinator.request(gameId, bytes32(commitId));
        _committed(commitId, wallet, context, custodyActionId);
        if (oneRow) _settle(commitId, bytes32(0));
    }

    /// @notice Anyone settles a commit once its word is available; idempotent through `settled`.
    function settle(uint256 commitId) external nonReentrant {
        Commit storage c = commits[commitId];
        if (c.gameId == 0) revert UnknownCommit();
        // An inline-settled commit is already settled, so requestId is nonzero here.
        if (c.settled) revert AlreadySettled();
        (bool fulfilled, bytes32 word) = coordinator.word(c.requestId);
        if (!fulfilled) revert RandomnessPending();
        _settle(commitId, word);
    }

    /// @notice Burn valued items and pay their fixed value to the Friend wallet from `owed`.
    /// Works on retired games and Draining modules forever.
    function redeem(
        uint256 gameId,
        uint256 friendId,
        uint16 classId,
        uint256 quantity,
        bytes32 custodyActionId
    ) external nonReentrant {
        (address wallet,) = _access(gameId, friendId, custodyActionId);
        if (quantity == 0) revert ZeroQuantity();
        DrawTables.Class[] storage classes_ = _classes[gameId];
        if (classId == 0 || classId > classes_.length) revert NotRedeemable();
        uint256 value = classes_[classId - 1].value;
        if (value == 0) revert NotRedeemable();
        IGameItems(registry.itemsOf(gameId)).burn(wallet, classId, quantity);
        uint256 amount = value * quantity;
        treasury.payOwed(gameId, wallet, amount);
        emit Redeemed(gameId, friendId, wallet, classId, quantity, amount, custodyActionId);
    }

    /// @notice Reproduce the roll for draw `index` of a commit from public state.
    function rollFor(uint256 commitId, uint256 index) external view returns (uint16) {
        (bool fulfilled, bytes32 word) = coordinator.word(commits[commitId].requestId);
        if (!fulfilled) revert RandomnessPending();
        return Rolls.roll(word, address(this), block.chainid, commitId, index);
    }

    /// @notice The game's classes, index classId - 1.
    function classes(uint256 gameId) external view returns (DrawTables.Class[] memory) {
        return _classes[gameId];
    }

    /// @notice One action's table: index 0, or 1..6 by generation.
    function rows(uint256 gameId, uint8 actionId, uint8 tableIndex)
        external
        view
        returns (DrawTables.Row[] memory)
    {
        return _rows[gameId][actionId][tableIndex];
    }

    /// @dev Owned path when `custodyActionId` is zero, custody path otherwise. The caller pays
    /// in both: an owner from its own address, a wallet through `execute`, the executor itself.
    function _access(uint256 gameId, uint256 friendId, bytes32 custodyActionId)
        private
        returns (address wallet, uint8 generation)
    {
        if (custodyActionId == bytes32(0)) {
            return FriendAccess.controlled(generations, friendId, msg.sender);
        }
        address executor = registry.custodyExecutor();
        if (msg.sender != executor || executor == address(0)) revert OnlyCustodyExecutor();
        registry.consumeCustodyAction(custodyActionId, gameId);
        return FriendAccess.custodied(generations, friendId, registry.custody());
    }

    /// @dev Takes the action's input (payment or burned items) and reserves the maximum value.
    function _take(
        uint256 gameId,
        uint8 actionId,
        DrawTables.Action storage a,
        address wallet,
        uint8 generation,
        uint8 quantity,
        uint8 tableIndex
    ) private returns (uint128 need) {
        if (a.input == DrawTables.Input.Currency) {
            // Retire stops purchases only.
            if (!registry.isActive(gameId)) revert GameNotActive();
            _collect(gameId, actionId, generation, uint256(a.price) * quantity);
        } else {
            uint256 units = uint256(a.inputCount) * quantity;
            IGameItems(registry.itemsOf(gameId)).burn(wallet, a.inputClass, units);
            // The input's backing returns to free before the play re-reserves it.
            uint256 inputReserve = uint256(_classes[gameId][a.inputClass - 1].reserve) * units;
            if (inputReserve != 0) treasury.release(gameId, inputReserve);
        }
        // Every one of the quantity × draws outcomes can realise the table maximum.
        // Bounded in defineAction: maximum × draws × maxUnits fits uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        need = uint128(uint256(maxPayable[gameId][actionId][tableIndex]) * a.draws * quantity);
        if (need != 0) treasury.reserve(gameId, need);
    }

    /// @dev Routes a purchase by the generation's split; rounding dust stays as stake.
    function _collect(uint256 gameId, uint8 actionId, uint8 generation, uint256 amount) private {
        DrawTables.Split storage s = splits[gameId][actionId][generation];
        ITreasury.Legs memory legs;
        legs.developer = amount * s.developerBps / DrawTables.BPS;
        legs.operator = amount * s.operatorBps / DrawTables.BPS;
        legs.burn = amount * s.burnBps / DrawTables.BPS;
        legs.rewards = amount * s.rewardsBps / DrawTables.BPS;
        legs.toFree = amount - legs.developer - legs.operator - legs.burn - legs.rewards;
        treasury.collect(gameId, msg.sender, legs);
    }

    /// @dev Stores the commit with the generation snapshot and its reservation.
    function _open(
        uint256 gameId,
        uint256 friendId,
        uint8 actionId,
        uint8 quantity,
        uint8 generation,
        uint128 need
    ) private returns (uint256 commitId) {
        commitId = ++commitCount;
        commits[commitId] = Commit(gameId, friendId, actionId, quantity, generation, false, need, 0);
    }

    /// @dev Emits `Committed` from storage; `requestId` is zero when settled inline.
    function _committed(uint256 commitId, address wallet, bytes32 context, bytes32 custodyActionId)
        private
    {
        Commit storage c = commits[commitId];
        emit Committed(
            commitId,
            c.gameId,
            c.friendId,
            wallet,
            c.actionId,
            c.quantity,
            c.generation,
            c.reservedTotal,
            c.requestId,
            context,
            custodyActionId
        );
    }

    /// @dev Rolls every draw, resolves the reservation, mints last, emits the chosen rows.
    function _settle(uint256 commitId, bytes32 word) private {
        Commit storage c = commits[commitId];
        c.settled = true;
        // Resolved, never stored: a transferred Friend's new owner controls the result.
        address wallet = generations.tokenBoundAccount(c.friendId);
        Outcome memory o = _draw(commitId, c, word);
        if (c.reservedTotal != 0 || o.paid != 0 || o.owed != 0 || o.keep != 0) {
            treasury.resolve(c.gameId, c.reservedTotal, o.owed, o.keep, wallet, o.paid);
        }
        if (o.distinct != 0) {
            uint256[] memory ids = new uint256[](o.distinct);
            uint256[] memory amounts = new uint256[](o.distinct);
            uint256 k;
            for (uint256 id = 1; id < o.counts.length; ++id) {
                if (o.counts[id] == 0) continue;
                ids[k] = id;
                amounts[k++] = o.counts[id];
            }
            IGameItems(registry.itemsOf(c.gameId)).mintBatch(wallet, ids, amounts);
        }
        emit Settled(commitId, c.gameId, c.friendId, wallet, o.rows, o.paid, o.owed);
    }

    /// @dev One roll per unit and draw, in order `unit * draws + draw`; a one-row table rolls
    /// nothing.
    function _draw(uint256 commitId, Commit storage c, bytes32 word)
        private
        view
        returns (Outcome memory o)
    {
        DrawTables.Action storage a = actions[c.gameId][c.actionId];
        DrawTables.Row[] storage table =
            _rows[c.gameId][c.actionId][a.perGeneration ? c.generation : 0];
        DrawTables.Class[] storage classes_ = _classes[c.gameId];
        uint256 n = uint256(c.quantity) * a.draws;
        o.rows = new uint8[](n);
        o.counts = new uint256[](classes_.length + 1);
        for (uint256 i; i < n; ++i) {
            uint8 index = table.length == 1
                ? 0
                : Rolls.pick(table, Rolls.roll(word, address(this), block.chainid, commitId, i));
            o.rows[i] = index;
            DrawTables.Row storage row = table[index];
            if (row.classId != 0) {
                if (o.counts[row.classId]++ == 0) ++o.distinct;
                DrawTables.Class storage class = classes_[row.classId - 1];
                o.owed += class.value;
                o.keep += class.reserve;
            }
            o.paid += row.value;
        }
    }
}
