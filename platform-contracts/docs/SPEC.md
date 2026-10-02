# Rare Friends platform contracts — implementation spec (v1)

This document is the implementation contract for `platform-contracts/`. It was synthesized from
three independent design drafts (minimalism, accounting-first, operations-first) and the brief in
[BRIEF.md](BRIEF.md). Where this spec and the brief disagree, the brief wins; where this spec is
silent, apply the commandments and the brief's section 2. Engineers implement contracts from this
text in parallel; every cross-contract call named here has its counterpart signature here.

Conventions: Solidity `^0.8.36`; custom errors only; `UPPER_SNAKE` constants, lowerCamel immutables (they are getters, not literals);
leading underscore for internal and private members; `BPS = 10_000`; RF amounts are 18-decimal
base units, USDG 6-decimal; "wallet" always means `generations.tokenBoundAccount(friendId)` and is
never stored, because an ERC-6551 account is a pure function of the token id; "controller" means
the Friend's current owner or its wallet; "executor" means the registry's custody executor acting
for a Friend whose `ownerOf` is FriendCustody. Every function that moves money or items is
`nonReentrant` at its module entry point; core contracts are callable only by registered modules
(or the registry owner) and guard their own public entry points.

Decisions that deviate from one of the reference contracts are listed in section 10.3 so reviewers
can accept or reject each one explicitly.

## 1. File list

```
src/
  GameRegistry.sol             Ownable2Step owner surface. Module allowlist with lineage, game records
                               (module, status, currency, items, funder, developer, operator, settler,
                               termsHash), per-game module bindings (Active | Draining), deploys one
                               GameItems per game, custody executor key, global custody action replay
                               table. The only contract with an owner.
  Treasury.sol                 Custody of RF and USDG. Per-game ledgers {free, reserved, owed, credit},
                               per-currency totals, fee ledger, RF rewards ledger. Only bound modules move
                               ledgers; the owner may withdraw free stake to the recorded funder only.
  RandomnessCoordinator.sol    The only Dice requester. Platform ETH, fee cap, per-game budgets, one
                               request per (module, game, action) binding, store-only callback,
                               permissionless reclaim-and-retry through Dice refundRequest.
  GameItems.sol                ERC-1155 per game, deployed by the registry. Classes 1..classCount,
                               Friend-bound (transfers disabled except mint and burn). Mint/burn by any
                               module the registry reports as bound for the game; URI set by the registry.
  DrawModule.sol               Declarative weighted-draw engine (Rare Breeds, Penalty Kings). Terms per
                               game, commit with maximum-value reservation, inline settlement for one-row
                               tables, randomness-bound settlement, redemption, custody path, context.
  RoundModule.sol              Rare Royale. Rounds with settler secret hash, entries reserved whole, one
                               word per round, settler payout list equal to the pot, refund paths, Friend
                               credit through the Treasury.
  access/Ownable2Step.sol      Vendored OpenZeppelin v5.1 (exists).
  libraries/FriendAccess.sol   Internal. The one rule for who may act for a Friend; returns (wallet,
                               generation); rejects generation 0 / > 6 and wallets without code.
  libraries/Rolls.sol          Internal, pure. Domain-separated, rejection-sampled roll in [0, 10_000)
                               and cumulative-weight row lookup.
  libraries/DrawTables.sol     Internal. Draw term structs, table validation, maxPayable, running hash.
                               Promoted to a linked external library only if DrawModule exceeds the size
                               limit (section 8).
  interfaces/IExternal.sol     IRareFriends (IERC20 + burn), IGenerations, IDiceEntropy (with the Request
                               struct in Dice storage order), IActivationManager.
  interfaces/IGameRegistry.sol Views other contracts read: owner, game, currentModule, canCommit,
                               isBound, isActive, currencyOf, itemsOf, settlerOf, recipientsOf,
                               rf, usdg, custody, custodyExecutor, generations; plus the one write
                               bound modules may make, consumeCustodyAction.
  interfaces/ITreasury.sol     Legs struct and the module-facing primitives.
  interfaces/IRandomnessCoordinator.sol  request, word, retry (the Request struct lives in the contract).
  interfaces/IGameItems.sol    mintBatch, burn, setURI, classCount.
  interfaces/IGameModule.sol   LINEAGE, seal, termsHash (what the registry needs from any module).
script/
  Mainnet.sol                  Verified mainnet addresses (exists).
  Deploy.s.sol                 Simulation-only deployment of the hub and both modules.
  RegisterLaunchGames.s.sol    Simulation-only registration of the three launch games with section 3 terms.
test/                          Section 9. Doubles exist in test/doubles/ExternalDoubles.sol.
```

Not present, deliberately (section 10.2): no factory, no proxy, no pause, no per-class caps, no
`Free` transfer policy, no ERC-20/721 assets, no Crash module, no timelock, no module revocation.

## 2. Contracts and libraries

### 2.1 `interfaces/IExternal.sol`

```solidity
interface IRareFriends is IERC20 {
    function burn(uint256 value) external;
}

interface IGenerations {
    function ownerOf(uint256 tokenId) external view returns (address);
    function generation(uint256 tokenId) external view returns (uint8);
    function tokenBoundAccount(uint256 tokenId) external view returns (address);
    function token() external view returns (address);
    function activationManager() external view returns (address);
}

interface IActivationManager {
    function fund(address asset, uint256 amount) external;
    function retired() external view returns (bool);
}

interface IDiceEntropy {
    struct Request {            // mirrors Dice storage, field for field, in order
        address provider; uint64 sequenceNumber; uint32 numHashes;
        bytes32 commitment;
        uint64 blockNumber; address requester; bool useBlockhash; uint8 callbackStatus; uint16 gasLimit10k;
        uint128 feePaid;
    }
    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128);
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external payable returns (uint64 sequenceNumber);
    function refundRequest(address provider, uint64 sequenceNumber) external;
    function getRequestV2(address provider, uint64 sequenceNumber) external view returns (Request memory);
    function getRefundDelayBlocks() external view returns (uint64);
}
```

### 2.2 `interfaces/IGameModule.sol`

```solidity
interface IGameModule {
    function LINEAGE() external view returns (bytes32);          // keccak256("Draw") | keccak256("Round")
    /// Registry only. Validates and freezes the game's terms; idempotent once sealed. Returns the hash.
    function seal(uint256 gameId) external returns (bytes32);
    /// Zero until sealed.
    function termsHash(uint256 gameId) external view returns (bytes32);
    /// Whether the registry may hand the game's committing role to a successor now. Draw answers
    /// true (its pending commits settle on the module that created them); Round answers true only
    /// while no round is Open or Closed, because its per-Friend credit lock lives in module storage.
    function succeedable(uint256 gameId) external view returns (bool);
}
```

### 2.3 `libraries/FriendAccess.sol` (internal, no storage)

```solidity
library FriendAccess {
    error InvalidFriend();          // generation 0 or > 6, or wallet without code
    error NotFriendController();    // caller is neither owner nor canonical wallet
    error NotCustodied();           // ownerOf(friendId) != FriendCustody

    /// Eligibility only: generation in [1, 6] and a deployed canonical wallet.
    function wallet(IGenerations g, uint256 friendId)
        internal view returns (address account, uint8 generation);
    /// Owned path: caller must be the current owner or the canonical wallet.
    function controlled(IGenerations g, uint256 friendId, address caller)
        internal view returns (address account, uint8 generation);
    /// Custody path: the Friend must currently be held by FriendCustody. The executor identity and
    /// the action-id replay guard are the module's job.
    function custodied(IGenerations g, uint256 friendId, address custody)
        internal view returns (address account, uint8 generation);
}
```

`wallet`: `generation = g.generation(friendId)`; revert `InvalidFriend` unless `1 <= generation <= 6`;
`account = g.tokenBoundAccount(friendId)`; revert `InvalidFriend` if `account.code.length == 0`.
`controlled`: `wallet(...)`, then `caller == g.ownerOf(friendId) || caller == account` else
`NotFriendController` (`ownerOf` reverts for nonexistent ids as ERC-721 does). `custodied`:
`g.ownerOf(friendId) == custody` else `NotCustodied`, then `wallet(...)`. No `beneficiary` read on
chain: the grant service and Nakama enforce the binding; on chain the executor key plus
`ownerOf == custody` plus a consumed action id is the PenaltyKingsPark rule, kept as is.

### 2.4 `libraries/Rolls.sol` (internal, pure)

```solidity
library Rolls {
    uint256 internal constant RANGE = 10_000;
    error InvalidRoll();

    /// Unbiased roll in [0, 10_000): keccak(word, module, chainId, id, index), rejection-sampled.
    function roll(bytes32 word, address module, uint256 chainId, uint256 id, uint256 index)
        internal pure returns (uint16);
    /// First row index i with roll < Σ weights[0..i]. Reverts InvalidRoll if weights do not cover it.
    function pick(DrawTables.Row[] storage rows, uint16 value) internal view returns (uint8 index);
}
```

`roll`: `v = uint256(keccak256(abi.encode(word, module, chainId, id, index)))`;
`limit = type(uint256).max - type(uint256).max % RANGE`; `while (v >= limit) v = uint256(keccak256(abi.encode(v)))`;
return `uint16(v % RANGE)`. Identical sampler to the deployed PenaltyKingsPark, so its tests port.

### 2.5 `libraries/DrawTables.sol` (internal; see section 8 for the external fallback)

```solidity
library DrawTables {
    uint256 internal constant MAX_ACTIONS = 32;
    uint256 internal constant MAX_ROWS = 16;
    uint256 internal constant MAX_DRAWS = 4;
    uint256 internal constant MAX_UNITS = 16;

    enum Input { None, Currency, BurnClass }

    struct Class {                 // one slot; index classId - 1
        uint128 value;             // fixed redemption value owed on mint, paid on redeem; 0 = not redeemable
        uint128 reserve;           // backing locked from free while the item exists (6e18 per egg); 0 = none
    }                              // a class never has both value and reserve nonzero
    struct Split {                 // 80 bits; sums to 10_000; Currency input only
        uint16 freeBps; uint16 developerBps; uint16 operatorBps; uint16 burnBps; uint16 rewardsBps;
    }
    struct Action {                // one slot
        Input input;               // Currency | BurnClass; None = undefined
        uint16 inputClass;         // BurnClass only
        uint8 inputCount;          // BurnClass only: items burned per unit (1 for every launch action)
        uint128 price;             // Currency only: price per unit
        uint8 draws;               // outcomes per unit, 1..MAX_DRAWS (egg 1, pack 2, kick 1)
        uint8 maxUnits;            // 1..MAX_UNITS: quantity ceiling per commit (bounds settle gas)
        bool perGeneration;        // tables indexed 1..6 by generation, else a single table at index 0
    }
    struct Row {                   // one slot
        uint16 weightBps;          // nonzero; a table's weights sum to 10_000
        uint16 classId;            // nonzero => mint one of this class
        uint128 value;             // nonzero => pay this much of the game currency to the wallet
    }                              // both zero = "nothing" (saved); both nonzero is invalid

    error InvalidTable();          // see validate

    /// Reverts unless rows is well formed; returns the table's maximum backing per draw:
    /// max over rows of (value + (classId != 0 ? classes[classId-1].value + classes[classId-1].reserve : 0)).
    function validate(Row[] calldata rows, Class[] storage classes) internal view returns (uint128 maxPayable);
}
```

`validate` rules: `1 <= rows.length <= MAX_ROWS`; every `weightBps != 0`; `Σ weightBps == 10_000`;
every `classId <= classes.length`; never `classId != 0 && value != 0`.

### 2.6 `GameRegistry.sol`

`contract GameRegistry is Ownable2Step, IGameRegistry` (the `Status`, `Binding` and `Game` types are
declared in the interface; `owner()` is overridden once because both bases declare it). The owner is
the Rare Friends multisig.

```solidity
enum Status { None, Draft, Active, Retired }
enum Binding { None, Active, Draining }     // Draining: may settle, redeem, refund; may not commit

struct Game {
    address module;      // current committing module
    Status status;
    address currency;    // RF or USDG
    address items;       // GameItems or zero when classCount == 0
    address funder;      // only recipient of free stake
    address developer;   // fee recipient; zero allowed when no term routes to it
    address operator;    // fee recipient; zero allowed when no term routes to it
    address settler;     // Round lineage only; zero otherwise
    bytes32 termsHash;   // fixed at activation; equal on every bound module
}

bytes32 public constant ROUND_LINEAGE = keccak256("Round");
address public immutable generations;
address public immutable rf;
address public immutable usdg;
address public immutable custody;                       // FriendCustody
address public custodyExecutor;                         // rotatable platform key; zero disables custody paths
mapping(bytes32 actionId => bool) public custodyActionUsed;    // one replay namespace across modules, games and succession
uint256 public gameCount;
mapping(address module => bytes32 lineage) public lineageOf;   // nonzero = allowlisted
mapping(uint256 gameId => Game) private _games;
mapping(uint256 gameId => mapping(address module => Binding)) public bindingOf;
```

Constructor `(address owner_, address generations_, address rf_, address usdg_, address custody_, address executor_)`:
`Ownable(owner_)`; every address except `executor_` must have code; `IGenerations(generations_).token() == rf_`
else `InvalidConfiguration`.

Errors: `OwnershipRequired, InvalidConfiguration, ModuleNotAllowed, ModuleAlreadyAllowed, UnknownGame,
WrongStatus, LineageMismatch, AlreadyBound, TermsMismatch, SettlerRule, NoItems, NotBoundModule,
InvalidCustodyAction, ModuleBusy`.

Events:

```solidity
event ModuleAllowed(address indexed module, bytes32 indexed lineage);
event GameCreated(uint256 indexed gameId, address indexed module, address indexed currency,
    address items, address funder, address developer, address operator, address settler);
event GameActivated(uint256 indexed gameId, bytes32 termsHash);
event GameRetired(uint256 indexed gameId);
event ModuleSucceeded(uint256 indexed gameId, address indexed previous, address indexed successor);
event SettlerSet(uint256 indexed gameId, address indexed settler);
event CustodyExecutorSet(address indexed executor);
event CustodyActionConsumed(bytes32 indexed actionId, uint256 indexed gameId, address indexed module);
```

| Signature | Caller | Preconditions → effects |
| --- | --- | --- |
| `renounceOwnership() public view override onlyOwner` | owner | always `revert OwnershipRequired()` |
| `allowModule(address module) external onlyOwner` | owner | `module.code.length != 0`; `lineageOf[module] == 0` else `ModuleAlreadyAllowed`; `lineage = IGameModule(module).LINEAGE()` nonzero; store; `ModuleAllowed`. No revocation. |
| `createGame(address module, address currency, address funder, address developer, address operator, address settler, uint256 classCount, string calldata uri) external onlyOwner returns (uint256 gameId)` | owner | `lineageOf[module] != 0` else `ModuleNotAllowed`; `currency == rf \|\| currency == usdg` else `InvalidConfiguration`; `funder != 0`; `settler != 0` iff `lineageOf[module] == ROUND_LINEAGE` else `SettlerRule`; `gameId = ++gameCount`; `items = classCount == 0 ? address(0) : address(new GameItems(address(this), gameId, classCount, uri))`; store `Game(module, Draft, currency, items, funder, developer, operator, settler, 0)`; `bindingOf[gameId][module] = Active`; `GameCreated`. |
| `activateGame(uint256 gameId) external onlyOwner` | owner | status `Draft` else `WrongStatus`; `hash = IGameModule(module).seal(gameId)`; `hash != 0` else `TermsMismatch`; `termsHash = hash`; status `Active`; `GameActivated`. |
| `retireGame(uint256 gameId) external onlyOwner` | owner | status `Active` else `WrongStatus`; status `Retired`; `GameRetired`. Stops new purchases, deposits, round opens and entries only (modules read `isActive`). |
| `succeedModule(uint256 gameId, address successor) external onlyOwner` | owner | status `Active` or `Retired`; `lineageOf[successor] == lineageOf[module]` else `LineageMismatch` (the game's module is always allowlisted, so equality implies the successor is too); `bindingOf[gameId][successor] == None` else `AlreadyBound`; `IGameModule(module).succeedable(gameId)` else `ModuleBusy`; `IGameModule(successor).seal(gameId) == termsHash` else `TermsMismatch`; `bindingOf[gameId][module] = Draining`; `bindingOf[gameId][successor] = Active`; `module = successor`; `ModuleSucceeded`. No "pending == 0" requirement: the predecessor keeps settling its own commits (section 7.5). |
| `setSettler(uint256 gameId, address settler) external onlyOwner` | owner | game exists; `lineageOf[module] == ROUND_LINEAGE` else `SettlerRule`; `settler != 0`; `SettlerSet`. |
| `setItemsURI(uint256 gameId, string calldata uri) external onlyOwner` | owner | `items != 0` else `NoItems`; `IGameItems(items).setURI(uri)`. |
| `setCustodyExecutor(address executor) external onlyOwner` | owner | sets (zero allowed, disables custody paths); `CustodyExecutorSet`. |
| `consumeCustodyAction(bytes32 actionId, uint256 gameId) external` | bound module of `gameId` (`bindingOf[gameId][msg.sender] != None` else `NotBoundModule`) | `actionId != 0 && !custodyActionUsed[actionId]` else `InvalidCustodyAction`; mark used; `CustodyActionConsumed`. One namespace for every module and game, so an order fulfilled on a predecessor module can never be replayed on its successor and the executor service keeps one table. |
| `game(uint256 gameId) external view returns (Game memory)` | any | `UnknownGame` if status `None`. |
| `currentModule(uint256 gameId) external view returns (address)` | any | `_games[gameId].module` (zero for unknown). |
| `isActive(uint256 gameId) external view returns (bool)` | any | `status == Active`. |
| `isBound(uint256 gameId, address module) external view returns (bool)` | any | `bindingOf[gameId][module] != None`. |
| `canCommit(uint256 gameId, address module) external view returns (bool)` | any | `status == Active && _games[gameId].module == module`. |
| `currencyOf(uint256 gameId) external view returns (address)` | any | zero for unknown. |
| `itemsOf(uint256 gameId) external view returns (address)` | any | zero when none. |
| `settlerOf(uint256 gameId) external view returns (address)` | any | zero for Draw games. |
| `recipientsOf(uint256 gameId) external view returns (address funder, address developer, address operator)` | any | — |

`createGame` is the only place `new GameItems` appears; the registry's runtime therefore embeds the
GameItems creation code (section 8). The registry never calls the Treasury or the Coordinator; both
read the registry. Deployment order is Registry → Treasury → Coordinator → modules, with no
circular constructor dependency.

### 2.7 `Treasury.sol`

`contract Treasury is ReentrancyGuard`. Holds every RF and USDG balance. Knows nothing about
Friends, randomness or terms. Trusts the registry to say which module is bound to a game and
trusts a bound module to compute legs from its immutable terms; enforces conservation itself.

```solidity
struct Ledger {                    // per game, in the game's currency
    uint256 free;                  // bankroll; withdrawable to the funder; feeds reservations
    uint256 reserved;              // max payable value of pending commits, held item reserves, open round pots
    uint256 owed;                  // fixed redemption liability of minted valued items
    uint256 credit;                // Σ creditOf[gameId][*]
}
struct Totals {                    // per currency
    uint256 free; uint256 reserved; uint256 owed; uint256 credit; uint256 fees;
}
struct Legs {                      // destinations of one collect; total = Σ fields
    uint256 toFree; uint256 toReserved;
    uint256 developer; uint256 operator;     // accrue to feesOwed (never transferred inline)
    uint256 burn; uint256 rewards;           // RF only: RF.burn now; rewardsPending accrual
}

IGameRegistry public immutable registry;
IRareFriends  public immutable rf;
IERC20        public immutable usdg;
IGenerations  public immutable generations;             // for activationManager()
mapping(uint256 gameId => Ledger) public ledgers;
mapping(uint256 gameId => mapping(uint256 friendId => uint256)) public creditOf;
mapping(address currency => Totals) public totals;
mapping(address currency => mapping(address recipient => uint256)) public feesOwed;
uint256 public rewardsPending;                           // RF only
```

Constructor `(address registry_, address rf_, address usdg_, address generations_)`: all have code;
`IGameRegistry(registry_).rf() == rf_ && IGameRegistry(registry_).usdg() == usdg_ && IGameRegistry(registry_).generations() == generations_` else `InvalidConfiguration`.

Authorization helpers (private): `_currency(gameId)` = `registry.currencyOf(gameId)`, reverts
`UnknownGame` when zero. `onlyCommitting(gameId)`: `registry.canCommit(gameId, msg.sender)` else
`NotCommittingModule`. `onlyBound(gameId)`: `registry.isBound(gameId, msg.sender)` else `NotBoundModule`.
A single private `_move(gameId, currency, int256 dFree, int256 dReserved, int256 dOwed, int256 dCredit)`
is the only writer of both `ledgers[gameId]` and `totals[currency]`; it reverts on any negative
result (`InsufficientFree`, `InsufficientReserved`, `InsufficientOwed`, `InsufficientCredit`).

Errors: `InvalidConfiguration, UnknownGame, NotCommittingModule, NotBoundModule, NotRegistryOwner,
ZeroAmount, UnsupportedLeg, NoRecipient, UnbalancedSpend, InsufficientFree, InsufficientReserved,
InsufficientOwed, InsufficientCredit, InvalidResolution, NothingOwed, ManagerUnavailable`.

Events (`gameId` always indexed):

```solidity
event Funded(uint256 indexed gameId, address indexed from, uint256 amount);
event Collected(uint256 indexed gameId, address indexed payer, Legs legs);
event Reserved(uint256 indexed gameId, uint256 amount);
event Released(uint256 indexed gameId, uint256 amount);
event Resolved(uint256 indexed gameId, uint256 amount, uint256 toOwed, uint256 toKeep, address indexed payTo, uint256 paid);
event ReservedRouted(uint256 indexed gameId, uint256 burned, uint256 rewards);
event OwedPaid(uint256 indexed gameId, address indexed to, uint256 amount);
event CreditDeposited(uint256 indexed gameId, uint256 indexed friendId, address indexed payer, uint256 amount);
event CreditWithdrawn(uint256 indexed gameId, uint256 indexed friendId, address indexed to, uint256 amount);
event CreditSpent(uint256 indexed gameId, uint256 indexed friendId, uint256 amount, uint256 burned, uint256 rewards);
event FeesPaid(address indexed currency, address indexed recipient, uint256 amount);
event RewardsForwarded(address indexed manager, uint256 amount);
event FreeWithdrawn(uint256 indexed gameId, address indexed funder, uint256 amount);
```

| Signature | Caller | Preconditions → effects |
| --- | --- | --- |
| `fund(uint256 gameId, uint256 amount) external nonReentrant` | anyone | `amount != 0`; `c = _currency(gameId)`; `safeTransferFrom(msg.sender, this, amount)`; `_move(+free)`; `Funded`. |
| `collect(uint256 gameId, address payer, Legs calldata l) external` | committing module | `total = Σ legs != 0` else `ZeroAmount`; if `c != rf` then `l.burn == 0 && l.rewards == 0` else `UnsupportedLeg`; `(, dev, op) = registry.recipientsOf(gameId)`; `l.developer != 0` requires `dev != 0`, same for operator (`NoRecipient`); `safeTransferFrom(payer, this, total)`; `_move(+toFree, +toReserved)`; `feesOwed[c][dev] += l.developer; feesOwed[c][op] += l.operator; totals[c].fees += l.developer + l.operator`; if `l.burn != 0` `rf.burn(l.burn)`; `rewardsPending += l.rewards`; `Collected`. |
| `reserve(uint256 gameId, uint256 amount) external` | bound module | `amount != 0`; `_move(-free, +reserved)` (reverts `InsufficientFree`); `Reserved`. |
| `release(uint256 gameId, uint256 amount) external` | bound module | `amount != 0`; `_move(+free, -reserved)`; `Released`. |
| `resolve(uint256 gameId, uint256 amount, uint256 toOwed, uint256 toKeep, address payTo, uint256 pay) external nonReentrant` | bound module | `amount >= toOwed + toKeep + pay` else `InvalidResolution`; `_move(dFree = amount - toOwed - toKeep - pay, dReserved = toKeep - amount, dOwed = +toOwed)`; if `pay != 0` `safeTransfer(payTo, pay)`; `Resolved`. A reverting transfer reverts the whole call: the reservation stays and the module's commit stays pending and retryable. |
| `routeReserved(uint256 gameId, uint256 burned, uint256 rewards) external` | bound module | `c == rf` else `UnsupportedLeg`; `_move(-reserved: burned + rewards)`; `rf.burn(burned)` if nonzero; `rewardsPending += rewards`; `ReservedRouted`. |
| `payOwed(uint256 gameId, address to, uint256 amount) external nonReentrant` | bound module | `amount != 0`; `_move(-owed)`; `safeTransfer(to, amount)`; `OwedPaid`. |
| `creditDeposit(uint256 gameId, uint256 friendId, address payer, uint256 amount) external` | committing module | `amount != 0`; `safeTransferFrom(payer, this, amount)`; `creditOf += amount`; `_move(+credit)`; `CreditDeposited`. |
| `creditWithdraw(uint256 gameId, uint256 friendId, address to, uint256 amount) external nonReentrant` | bound module | `amount != 0`; `creditOf -= amount` (underflow reverts `InsufficientCredit`); `_move(-credit)`; `safeTransfer(to, amount)`; `CreditWithdrawn`. |
| `creditSpend(uint256 gameId, uint256 friendId, uint256 amount, uint256 burned, uint256 rewards) external` | bound module | `c == rf` else `UnsupportedLeg`; `burned + rewards == amount` else `UnbalancedSpend`; `creditOf -= amount`; `_move(-credit)`; `rf.burn(burned)` if nonzero; `rewardsPending += rewards`; `CreditSpent`. A spend never reaches free, reserved or owed. |
| `payFees(address currency, address recipient) external nonReentrant` | anyone | `amount = feesOwed[currency][recipient] != 0` else `NothingOwed`; zero it; `totals[currency].fees -= amount`; `safeTransfer(recipient, amount)`; `FeesPaid`. A frozen USDG fee recipient keeps its ledger and never blocks a purchase. |
| `forwardRewards() external nonReentrant` | anyone | `amount = rewardsPending != 0` else `NothingOwed`; `manager = generations.activationManager()`; `manager.code.length != 0 && !IActivationManager(manager).retired()` else `ManagerUnavailable`; `rewardsPending = 0`; `rf.forceApprove(manager, amount)`; `manager.fund(address(rf), amount)`; `RewardsForwarded`. Never on a player path. |
| `withdrawFree(uint256 gameId, uint256 amount) external nonReentrant` | `registry.owner()` else `NotRegistryOwner` | `amount != 0`; `(funder,,) = registry.recipientsOf(gameId)`; `_move(-free)`; `safeTransfer(funder, amount)`; `FreeWithdrawn`. No recipient parameter. |
| `solvent(address currency) external view returns (bool)` | any | `IERC20(currency).balanceOf(this) >= totals.reserved + totals.owed + totals.credit + totals.fees + (currency == rf ? rewardsPending : 0)`. |
| `backed(address currency) external view returns (uint256)` | any | `totals.free + totals.reserved + totals.owed + totals.credit + totals.fees + (currency == rf ? rewardsPending : 0)`. |

Design notes. Developer and operator fees accrue instead of being transferred at collect time so
that a USDG issuer freezing a fee address can never make a purchase revert (named failure: PK's
inline `safeTransferFrom(payer, developer)` would brick the game). `collect` and `creditDeposit`
require the committing module because they open new positions; every other primitive accepts a
Draining module so predecessors can finish their own commits, redemptions, refunds and credit
withdrawals. The Treasury holds RF, so Generations mints it one generation-0 temporary Friend; it
is never used and `FriendAccess` rejects generation 0 everywhere.

### 2.8 `RandomnessCoordinator.sol`

`contract RandomnessCoordinator is ReentrancyGuard`. The only contract that calls Dice. Holds
platform ETH only; no module function is payable and players never send value.

```solidity
enum State { None, Requested, Fulfilled }
struct Request {
    address module; uint256 gameId; bytes32 actionKey;
    uint64 sequence; uint32 attempt; State state; bytes32 word;
}

uint32 public constant CALLBACK_GAS_LIMIT = 200_000;
IGameRegistry public immutable registry;
IDiceEntropy  public immutable dice;        // 0xd8a0…0a0c
address       public immutable provider;    // 0x8741…F2b6
uint128 public maxFee;                      // platform cap on the quoted fee; 0 disables requests
uint256 public requestCount;
mapping(uint256 requestId => Request) public requests;
mapping(uint64 sequence => uint256 requestId) public requestOfSequence;   // live sequences only
mapping(bytes32 bindingKey => uint256 requestId) public boundRequest;     // keccak(module, gameId, actionKey)
mapping(uint256 gameId => uint256) public budget;                         // wei the game may still spend
```

Constructor `(address registry_, address dice_, address provider_)`: registry and dice have code;
provider nonzero.

Errors: `InvalidConfiguration, NotBoundModule, NotRegistryOwner, AlreadyBound, FeeAboveCap,
BudgetExceeded, InsufficientBalance, SequenceReused, UnauthorizedRandomness, InvalidRandomness,
RetryUnavailable, TransferFailed`.

Events:

```solidity
event Requested(uint256 indexed requestId, uint256 indexed gameId, address indexed module,
    bytes32 actionKey, uint64 sequence, uint128 fee);
event Fulfilled(uint256 indexed requestId, uint64 indexed sequence, bytes32 word);
event Retried(uint256 indexed requestId, uint64 indexed staleSequence, uint64 indexed sequence,
    uint32 attempt, uint256 reclaimed, uint128 fee);
event MaxFeeSet(uint128 fee);
event BudgetSet(uint256 indexed gameId, uint256 budget);
event Deposited(address indexed from, uint256 amount);
event Withdrawn(address indexed to, uint256 amount);
```

| Signature | Caller | Preconditions → effects |
| --- | --- | --- |
| `receive() external payable` | anyone, Dice refunds | `Deposited(msg.sender, msg.value)` unless `msg.sender == dice` (refunds are reported by `Retried`). |
| `request(uint256 gameId, bytes32 actionKey) external nonReentrant returns (uint256 requestId)` | bound module (`registry.isBound(gameId, msg.sender)`) | `key = keccak256(abi.encode(msg.sender, gameId, actionKey))`; `boundRequest[key] == 0` else `AlreadyBound`; `requestId = ++requestCount`; store `Request(msg.sender, gameId, actionKey, 0, 0, Requested, 0)`; `boundRequest[key] = requestId`; `_send(requestId, gameId, 0, maxFee)` writes `sequence`; `Requested`. `module` and `actionKey` are stored so a keeper can map a request id back to its action from public state alone. |
| `_entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external` | Dice | `msg.sender == address(dice) && provider == provider` else `UnauthorizedRandomness`; `id = requestOfSequence[sequence]`, `id != 0 && requests[id].state == Requested && requests[id].sequence == sequence` else `InvalidRandomness`; `word = randomNumber; state = Fulfilled; delete requestOfSequence[sequence]`; `Fulfilled`. Store-only; a zero word is valid. |
| `word(uint256 requestId) external view returns (bool fulfilled, bytes32 value)` | any | `(state == Fulfilled, word)`. |
| `retry(uint256 requestId) external nonReentrant` | anyone | `r.state == Requested` else `RetryUnavailable`; `d = dice.getRequestV2(provider, r.sequence)`; `d.sequenceNumber == r.sequence && d.callbackStatus == 1` else `RetryUnavailable` (status 3 means the word is public: refused forever; a cleared request was already refunded or revealed); `before = address(this).balance`; `dice.refundRequest(provider, r.sequence)` (Dice's `RefundNotAvailable` before `blockNumber + 6` and `Unauthorized` propagate); `reclaimed = balance - before`; `budget[gameId] += reclaimed`; `delete requestOfSequence[r.sequence]`; `attempt += 1`; `_send(requestId, gameId, attempt, cap)` with `cap = max(maxFee, reclaimed)`, so a retry the reclaimed fee pays for in full is never blocked by the cap while a dearer quote still is; `Retried`. Module state is untouched. |
| `setMaxFee(uint128 fee) external` | `registry.owner()` | `MaxFeeSet`. |
| `setBudget(uint256 gameId, uint256 amount) external` | `registry.owner()` | absolute set; `BudgetSet`. |
| `withdraw(address to, uint256 amount) external nonReentrant` | `registry.owner()` | `to != 0`; plain call; `TransferFailed` on failure; `Withdrawn`. Platform ETH only. |

```solidity
function _send(uint256 requestId, uint256 gameId, uint32 attempt, uint128 cap) private returns (uint64 seq) {
    uint128 fee = dice.getFeeV2(provider, CALLBACK_GAS_LIMIT);
    if (fee > cap) revert FeeAboveCap();
    if (fee > budget[gameId]) revert BudgetExceeded();
    if (address(this).balance < fee) revert InsufficientBalance();
    budget[gameId] -= fee;
    seq = dice.requestV2{ value: fee }(
        provider, keccak256(abi.encode(address(this), block.chainid, requestId, attempt)), CALLBACK_GAS_LIMIT);
    if (requestOfSequence[seq] != 0) revert SequenceReused();
    requestOfSequence[seq] = requestId;
    requests[requestId].sequence = seq;
}
```

Retry is permissionless. Named attacker: a griefer calling `retry` on a stuck request. Dice's own
delay is the only clock, a retry needs a request Dice itself reports unrevealed, and the net cost
is `fee − reclaimed` (zero at a stable fee) bounded by the game's budget. Owner-only retry would
make the owner a liveness dependency for settlement for no security gain.

### 2.9 `GameItems.sol`

`contract GameItems is ERC1155`. One collection per game, deployed by the registry. Every id is
Friend-bound: `_update` reverts `FriendBoundInventory()` when `from != 0 && to != 0`, including
transfers through approved operators.

```solidity
IGameRegistry public immutable registry;
uint256 public immutable gameId;
uint256 public immutable classCount;      // valid ids are 1..classCount
```

plus OpenZeppelin's `_uri` with the standard `{id}` substitution. No controller slot: authority is
`registry.isBound(gameId, msg.sender)` read live, so succession needs no write here and a
Draining module can still burn for redemption and mint for its pending settlements. No per-class
caps, no supply counters, no `Free` policy (no launch game needs them).

Errors: `InvalidConfiguration, NotBoundModule, OnlyRegistry, UnknownClass, FriendBoundInventory`.

| Signature | Caller | Preconditions → effects |
| --- | --- | --- |
| `constructor(address registry_, uint256 gameId_, uint256 classCount_, string memory uri_)` | registry | `1 <= classCount_ <= 64`. |
| `mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external` | bound module | each id valid; `_mintBatch`. |
| `burn(address from, uint256 id, uint256 amount) external` | bound module | id valid; `_burn` without approval (gameplay consumption). |
| `setURI(string calldata newuri) external` | `address(registry)` else `OnlyRegistry` | `_setURI`. OpenZeppelin's `{id}` template setter emits no event; indexers refresh metadata on the registry's `setItemsURI` transaction. |

Events: OZ `TransferSingle` and `TransferBatch` only (`mintBatch` with one id emits `TransferSingle`). There is no single-id `mint`: every module mints through `mintBatch`.

### 2.10 `DrawModule.sol`

`contract DrawModule is ReentrancyGuard` implementing `IGameModule`. `LINEAGE = keccak256("Draw")`.
Holds no funds; serves every Draw game by `gameId`. Uses `DrawTables`, `Rolls`, `FriendAccess`.

```solidity
struct Commit {                       // four slots
    uint256 gameId;
    uint256 friendId;
    uint8   actionId;
    uint8   quantity;
    uint8   generation;               // snapshotted at commit; drives the table and the split
    bool    settled;
    uint128 reservedTotal;            // maxPayable × draws × quantity, locked at commit; resolved at settlement
    uint256 requestId;                // 0 when the table had one row (settled inline)
}

IGameRegistry           public immutable registry;
ITreasury               public immutable treasury;
IRandomnessCoordinator  public immutable coordinator;
IGenerations            public immutable generations;

// terms, per game; immutable once sealed
mapping(uint256 gameId => bool)    public isSealed;   // `sealed` is a reserved word
mapping(uint256 gameId => bytes32) public runningHash;
mapping(uint256 gameId => uint8)   public actionCount;
mapping(uint256 gameId => DrawTables.Class[]) private _classes;                               // index classId - 1
mapping(uint256 gameId => mapping(uint8 actionId => DrawTables.Action)) public actions;
mapping(uint256 gameId => mapping(uint8 actionId => mapping(uint8 generation => DrawTables.Split))) public splits;   // 1..6
mapping(uint256 gameId => mapping(uint8 actionId => mapping(uint8 tableIndex => DrawTables.Row[]))) private _rows;  // 0 or 1..6
mapping(uint256 gameId => mapping(uint8 actionId => mapping(uint8 tableIndex => uint128))) public maxPayable;
// play state
uint256 public commitCount;
mapping(uint256 commitId => Commit) public commits;
```

The custody replay guard is the registry's `custodyActionUsed` table (2.6), not module storage.

Constructor `(address registry_, address treasury_, address coordinator_, address generations_)`:
all have code and `IGameRegistry(registry_).generations() == generations_`, else `InvalidConfiguration`.

Errors: `InvalidConfiguration, NotRegistryOwner, OnlyRegistry, Sealed, NotSealed, ClassesAlreadyDefined, ClassCountMismatch,
TooManyActions, InvalidAction, InvalidSplit, InvalidClass, NotCurrentModule, GameNotActive,
UnknownAction, InvalidQuantity, OnlyCustodyExecutor, UnknownCommit,
AlreadySettled, RandomnessPending, NotRedeemable, ZeroQuantity, NoTerms`, plus the
`FriendAccess`, `Rolls` and `DrawTables` errors.

Events:

```solidity
event ClassesDefined(uint256 indexed gameId, DrawTables.Class[] classes);
event ActionDefined(uint256 indexed gameId, uint8 indexed actionId, DrawTables.Action action,
    DrawTables.Split[6] splits, DrawTables.Row[][] tables, uint128[] maxPayable);
event TermsSealed(uint256 indexed gameId, bytes32 termsHash);
event Committed(uint256 indexed commitId, uint256 indexed gameId, uint256 indexed friendId,
    address wallet, uint8 actionId, uint8 quantity, uint8 generation, uint256 reservedTotal,
    uint256 requestId, bytes32 context, bytes32 custodyActionId);
event Settled(uint256 indexed commitId, uint256 indexed gameId, uint256 indexed friendId,
    address wallet, uint8[] rows, uint256 paid, uint256 owed);
event Redeemed(uint256 indexed gameId, uint256 indexed friendId, address indexed wallet,
    uint16 classId, uint256 quantity, uint256 amount, bytes32 custodyActionId);
```

`Committed.requestId == 0` means the commit settled inline (one-row table), so the keeper knows
exactly which commits need a word. `Settled.rows[i]` is the chosen row index for draw `i` in order
`unit * draws + draw`. `ActionDefined` carries the full tables so an indexer reconstructs terms
from logs alone and can recompute `termsHash`.

**Terms functions** (caller `registry.owner()` else `NotRegistryOwner`; `!isSealed[gameId]` else `Sealed`).

| Signature | Effects |
| --- | --- |
| `defineClasses(uint256 gameId, DrawTables.Class[] calldata classes) external` | `_classes[gameId].length == 0` else `ClassesAlreadyDefined` (the event keeps the name `ClassesDefined`); `items = registry.itemsOf(gameId)`, `items != 0 && classes.length == IGameItems(items).classCount()` else `ClassCountMismatch`; each class: not both `value` and `reserve` nonzero else `InvalidClass`; copy; `runningHash = keccak256(abi.encode(runningHash, uint8(1), classes))`; `ClassesDefined`. |
| `defineAction(uint256 gameId, DrawTables.Action calldata a, DrawTables.Split[6] calldata s, DrawTables.Row[][] calldata tables) external` | classes defined (`_classes.length != 0`) else `InvalidAction`; `actionId = actionCount + 1 <= MAX_ACTIONS` else `TooManyActions`; `a.input ∈ {Currency, BurnClass}`, `1 <= a.draws <= MAX_DRAWS`, `1 <= a.maxUnits <= MAX_UNITS` else `InvalidAction`; `tables.length == (a.perGeneration ? 6 : 1)` else `InvalidAction`; Currency: `a.price != 0`; `c = registry.currencyOf(gameId)`, `(, dev, op) = registry.recipientsOf(gameId)`; each of the six splits sums to `10_000`, `burnBps == 0 && rewardsBps == 0` when `c != registry.rf()`, `developerBps == 0` when `dev == 0`, `operatorBps == 0` when `op == 0`, else `InvalidSplit`; BurnClass: `1 <= a.inputClass <= classes.length`, `a.inputCount != 0`, the input class has `value == 0` (burning a valued class would strand its liability in `owed`), every split field zero (`InvalidSplit`); for each table `t`: `maxPayable[gameId][actionId][index] = DrawTables.validate(tables[t], _classes[gameId])` with `index = a.perGeneration ? t + 1 : 0`, `uint256(maxPayable) * a.draws * a.maxUnits <= type(uint128).max` else `InvalidAction` (keeps `Commit.reservedTotal` in uint128), rows copied to `_rows`; store `actions`, `splits[gen] = s[gen-1]` for gen 1..6; `actionCount = actionId`; `runningHash = keccak256(abi.encode(runningHash, uint8(2), actionId, a, s, tables))`; `ActionDefined`. |
| `seal(uint256 gameId) external returns (bytes32)` | caller `address(registry)` else `OnlyRegistry`; if `isSealed` return `runningHash` (idempotent, used by succession); else `actionCount != 0` else `NoTerms`; `isSealed = true`; `TermsSealed`; return `runningHash`. |
| `termsHash(uint256 gameId) external view returns (bytes32)` | `isSealed ? runningHash : 0`. |

Validation lives entirely in `defineAction`; `commit` and `settle` never re-check terms.

**Play functions.**

| Signature | Caller |
| --- | --- |
| `commit(uint256 gameId, uint8 actionId, uint256 friendId, uint8 quantity, bytes32 context, bytes32 custodyActionId) external nonReentrant returns (uint256 commitId)` | Friend owner, canonical wallet, or the custody executor |
| `settle(uint256 commitId) external nonReentrant` | anyone |
| `redeem(uint256 gameId, uint256 friendId, uint16 classId, uint256 quantity, bytes32 custodyActionId) external nonReentrant` | Friend owner, canonical wallet, or the custody executor |
| `rollFor(uint256 commitId, uint256 index) external view returns (uint16)` | anyone; reverts `RandomnessPending` until the word exists |
| `classes(uint256 gameId) external view returns (DrawTables.Class[] memory)`; `rows(uint256 gameId, uint8 actionId, uint8 tableIndex) external view returns (DrawTables.Row[] memory)` | anyone |

**`commit` — ordered effects**

1. `registry.currentModule(gameId) == address(this)` else `NotCurrentModule`; `isSealed[gameId]` else `NotSealed`.
2. `a = actions[gameId][actionId]`; `a.input != None` else `UnknownAction`; `1 <= quantity <= a.maxUnits` else `InvalidQuantity`.
3. Access. `custodyActionId == 0`: `(wallet, gen) = FriendAccess.controlled(generations, friendId, msg.sender)`; payer is `msg.sender` (an owner pays from its own address; paying from the Friend wallet means calling through `wallet.execute`, which makes the wallet the caller — there is no `payer` parameter). `custodyActionId != 0`: `executor = registry.custodyExecutor()`, `msg.sender == executor && executor != 0` else `OnlyCustodyExecutor`; `registry.consumeCustodyAction(custodyActionId, gameId)` (reverts `InvalidCustodyAction` on reuse) before any other external call; `(wallet, gen) = FriendAccess.custodied(generations, friendId, registry.custody())`; payer is the executor.
4. `tableIndex = a.perGeneration ? gen : 0`; `need = uint256(maxPayable[gameId][actionId][tableIndex]) * a.draws * quantity` (every one of the `quantity × draws` outcomes can realise the table maximum); `items = IGameItems(registry.itemsOf(gameId))`.
5. Input.
   - Currency: `registry.isActive(gameId)` else `GameNotActive` (retire stops purchases only). `amount = a.price * quantity`; `s = splits[gameId][actionId][gen]`; `developer = amount * s.developerBps / 10_000`, `operator = amount * s.operatorBps / 10_000`, `burn = amount * s.burnBps / 10_000`, `rewards = amount * s.rewardsBps / 10_000`, `toFree = amount − developer − operator − burn − rewards` (rounding dust stays as stake); `treasury.collect(gameId, payer, Legs(toFree, 0, developer, operator, burn, rewards))`.
   - BurnClass: `items.burn(wallet, a.inputClass, a.inputCount * quantity)`; `inputReserve = _classes[gameId][a.inputClass − 1].reserve * a.inputCount * quantity`; if nonzero `treasury.release(gameId, inputReserve)` (the egg's backing returns to free before the play re-reserves it, so a play works even when free is otherwise zero).
6. If `need != 0`: `treasury.reserve(gameId, need)` — reverts `InsufficientFree` when the bankroll cannot cover the maximum. This is the "kick needs free bankroll ≥ its maximum" rule and the egg purchase backing rule.
7. `commitId = ++commitCount`; `commits[commitId] = Commit(gameId, friendId, actionId, quantity, gen, false, uint128(need), 0)`.
8. If `_rows[gameId][actionId][tableIndex].length == 1`: emit `Committed(..., requestId 0, ...)` then `_settle(commitId, bytes32(0))` inline. Otherwise `requestId = coordinator.request(gameId, bytes32(commitId))`; store; emit `Committed(...)`.

**`settle(commitId)`**: `c.gameId != 0` else `UnknownCommit`; `!c.settled` else `AlreadySettled`
(an inline-settled commit is already settled, so no separate check for `requestId == 0` is
needed); `(ok, word) = coordinator.word(c.requestId)`; `ok` else `RandomnessPending`;
`_settle(commitId, word)`.

**`_settle(commitId, word)` — ordered effects**

1. `c.settled = true`. `wallet = generations.tokenBoundAccount(c.friendId)` (resolved, never stored, so a transferred Friend's new owner controls the result). `rows = _rows[gameId][actionId][tableIndex]`.
2. `n = quantity * draws`; for `i` in `0..n`: `idx = rows.length == 1 ? 0 : Rolls.pick(rows, Rolls.roll(word, address(this), block.chainid, commitId, i))`; `rowsOut[i] = idx`; `row = rows[idx]`; if `row.classId != 0`: accumulate one unit of `classId` into the mint arrays (aggregate per class), `owed += class.value`, `keep += class.reserve`; if `row.value != 0`: `paid += row.value`.
3. If `c.reservedTotal != 0 || paid != 0 || owed != 0 || keep != 0`: `treasury.resolve(gameId, c.reservedTotal, owed, keep, wallet, paid)`. By construction `reservedTotal = maxPayable × draws × quantity ≥ paid + owed + keep`, so `resolve` cannot revert on arithmetic; a reverting USDG transfer reverts the whole call, the reservation stays, and `settle` is retryable.
4. If any mints: `items.mintBatch(wallet, ids, amounts)` (last, after all ledgers are final).
5. Emit `Settled(commitId, gameId, friendId, wallet, rowsOut, paid, owed)`.

**`redeem`**: access exactly as `commit` step 3 (the custody path consumes `custodyActionId`);
`quantity != 0` else `ZeroQuantity`; `1 <= classId <= classes.length` and `class.value != 0` else
`NotRedeemable`; `items.burn(wallet, classId, quantity)`; `treasury.payOwed(gameId, wallet, class.value * quantity)`;
`Redeemed`. No status or current-module check: redemption works on retired games forever and on a
Draining module (both `burn` and `payOwed` accept any bound module).

**`rollFor(commitId, index)`**: `(ok, word) = coordinator.word(c.requestId)`; `ok` else
`RandomnessPending`; returns `Rolls.roll(word, address(this), block.chainid, commitId, index)`. Lets
verifiers and the keeper reproduce every outcome from public state.

Keeper contract: a commit is pending iff `commits[id].settled == false && requestId != 0`; it is
settleable iff `coordinator.word(requestId)` is fulfilled. The keeper indexes `Committed` with
`requestId != 0`, joins `Fulfilled(requestId)`, calls `settle`, confirms `Settled`. A `Fulfilled`
commit with no `Settled` after retries is a USDG recipient restriction; the keeper alerts. A
`Requested` request that Dice shows as status 1 after 6 L1 blocks is retried through
`coordinator.retry(requestId)`.

### 2.11 `RoundModule.sol`

`contract RoundModule is ReentrancyGuard` implementing `IGameModule`. `LINEAGE = keccak256("Round")`.
Holds no funds. Rare Royale is the only launch game; the module has no custody path (not
required at launch) and no Friend items (`classCount == 0` at registration).

```solidity
uint256 public constant ABANDON_AFTER = 1 days;    // from openedAt; permissionless refund of a stuck round
uint8   public constant MAX_KINDS = 32;

enum Status { None, Open, Closed, Settled, Refunded }

struct Terms {                                     // one slot
    uint128 entryPrice;      // 1e18
    uint16  potBps;          // 8000: ladder + bounty pool, paid by the settler's list
    uint16  burnBps;         // 1000
    uint16  rewardsBps;      // 1000   (potBps + burnBps + rewardsBps == 10_000)
    uint16  spendBurnBps;    // 5000   (spendBurnBps + spendRewardsBps == 10_000)
    uint16  spendRewardsBps; // 5000
    uint16  minEntries;      // 5
    uint16  maxEntries;      // 50
}
struct Round {                                     // four slots
    uint256 gameId;
    bytes32 secretHash;      // keccak256(abi.encode(secret)), committed before entries open
    uint64  openedAt;
    Status  status;
    uint256 requestId;       // 0 until closed with enough entries
}

IGameRegistry           public immutable registry;
ITreasury               public immutable treasury;
IRandomnessCoordinator  public immutable coordinator;
IGenerations            public immutable generations;

mapping(uint256 gameId => Terms)      public terms;
mapping(uint256 gameId => uint128[])  private _kindPrices;   // index = kind - 1
mapping(uint256 gameId => bool)       public isSealed;   // `sealed` is a reserved word
uint256 public roundCount;
mapping(uint256 roundId => Round)     public rounds;
mapping(uint256 roundId => uint256[]) private _entrants;    // friendIds in entry order
mapping(uint256 gameId => mapping(uint256 friendId => uint256)) public roundOf;   // latest round entered
mapping(uint256 gameId => uint256) public liveRounds;                              // rounds Open or Closed
```

Constructor `(address registry_, address treasury_, address coordinator_, address generations_)`:
all have code and `IGameRegistry(registry_).generations() == generations_`, else `InvalidConfiguration`.

Pot and entry count are derived (`_entrants.length`, terms), never stored. `roundOf` is the one
lookup that restricts spends and payouts to entrants and blocks credit withdrawal while a round
is using the Friend. It records the latest round only, so a Friend may be in at most one unsettled
round at a time: `enter` refuses while the Friend's latest round is `Open` or `Closed`. Without
that rule an overlapping entry would overwrite `roundOf` and make the earlier round's payout to
that Friend fail `NotEntrant`, reverting its whole settlement.

Errors: `InvalidConfiguration, NotRegistryOwner, OnlyRegistry, Sealed, InvalidTerms, NotCurrentModule,
GameNotActive, OnlySettler, WrongStatus, RoundFull, NotEntrant, UnknownKind,
BadSecret, RandomnessPending, LengthMismatch, PotMismatch, ZeroAmount, RoundInProgress,
NotAbandonable, NoTerms`, plus `FriendAccess` errors.

Events:

```solidity
event TermsDefined(uint256 indexed gameId, Terms terms, uint128[] kindPrices);
event TermsSealed(uint256 indexed gameId, bytes32 termsHash);
event RoundOpened(uint256 indexed roundId, uint256 indexed gameId, bytes32 secretHash, uint64 openedAt);
event Entered(uint256 indexed roundId, uint256 indexed friendId, address indexed wallet, address payer, uint16 seat);
event RoundClosed(uint256 indexed roundId, uint16 entries, uint256 pot, uint256 requestId);
event Spent(uint256 indexed roundId, uint256 indexed payerFriendId, uint256 indexed targetFriendId, uint8 kind, uint256 price);
event RoundSettled(uint256 indexed roundId, bytes32 word, bytes32 secret, uint256[] friendIds, uint256[] amounts);
event RoundRefunded(uint256 indexed roundId, uint16 entries, bool abandoned);
```

Credit events are the Treasury's (`CreditDeposited`, `CreditWithdrawn`, `CreditSpent`).

**Terms functions**

| Signature | Caller | Preconditions → effects |
| --- | --- | --- |
| `defineTerms(uint256 gameId, Terms calldata t, uint128[] calldata prices) external` | `registry.owner()` | `!isSealed` else `Sealed`; `terms[gameId].entryPrice == 0` (define once, else `InvalidTerms`); `registry.currencyOf(gameId) == registry.rf()`; `t.entryPrice != 0`; `t.potBps != 0` (a zero pot would make every full round unsettleable); `t.potBps + t.burnBps + t.rewardsBps == 10_000`; `t.spendBurnBps + t.spendRewardsBps == 10_000`; `1 <= t.minEntries <= t.maxEntries`; `1 <= prices.length <= MAX_KINDS`, every price nonzero; else `InvalidTerms`. Store; `TermsDefined`. |
| `seal(uint256 gameId) external returns (bytes32)` | `address(registry)` | if `isSealed` return the hash (idempotent); `terms[gameId].entryPrice != 0` else `NoTerms`; `isSealed = true`; `TermsSealed`; return `keccak256(abi.encode(terms[gameId], _kindPrices[gameId]))`. |
| `termsHash(uint256 gameId) external view returns (bytes32)` | any | `isSealed ? keccak256(abi.encode(terms[gameId], _kindPrices[gameId])) : 0`. |

**Settler functions** (`msg.sender == registry.settlerOf(gameId)` else `OnlySettler`; `gameId` is
read from the round for round-scoped calls).

| Signature | Preconditions → effects |
| --- | --- |
| `openRound(uint256 gameId, bytes32 secretHash) external nonReentrant returns (uint256 roundId)` | `registry.currentModule(gameId) == address(this)` else `NotCurrentModule`; `registry.isActive(gameId)` else `GameNotActive` (an active, current game is always sealed, so no separate check); `secretHash != 0` else `BadSecret`; `roundId = ++roundCount`; `++liveRounds[gameId]`; `rounds[roundId] = Round(gameId, secretHash, uint64(block.timestamp), Open, 0)`; `RoundOpened`. Several rounds may be open at once. |
| `closeRound(uint256 roundId) external nonReentrant` | status `Open` else `WrongStatus`; `n = _entrants.length`; if `n < minEntries`: `_refund(roundId, false)`; else `requestId = coordinator.request(gameId, bytes32(roundId))`; status `Closed`; `RoundClosed(roundId, n, potOf(roundId), requestId)`. |
| `spend(uint256 roundId, uint256 payerFriendId, uint256 targetFriendId, uint8 kind) external nonReentrant` | status `Open` or `Closed` else `WrongStatus`; `roundOf[gameId][payerFriendId] == roundId` else `NotEntrant`; `1 <= kind <= _kindPrices.length` else `UnknownKind`; `p = _kindPrices[kind − 1]`; `burned = p * spendBurnBps / 10_000`; `treasury.creditSpend(gameId, payerFriendId, p, burned, p − burned)`; `Spent`. The target is informational for the replayable simulation (sponsoring any fighter, including wild Friends that never entered); per-round caps are the settler simulation's job. |
| `settleRound(uint256 roundId, bytes32 secret, uint256[] calldata friendIds, uint256[] calldata amounts) external nonReentrant` | status `Closed`; `keccak256(abi.encode(secret)) == secretHash` else `BadSecret`; `(ok, word) = coordinator.word(requestId)`, `ok` else `RandomnessPending`; `friendIds.length == amounts.length && != 0` else `LengthMismatch`; `n = _entrants.length`; `gross = n * entryPrice`; `burned = gross * burnBps / 10_000`; `rewards = gross * rewardsBps / 10_000`; `pot = gross − burned − rewards`; for each `i` (while summing): `roundOf[gameId][friendIds[i]] == roundId` else `NotEntrant`, `amounts[i] != 0` else `ZeroAmount`; then `Σ amounts == pot` else `PotMismatch`; status `Settled`; `--liveRounds[gameId]`; `treasury.routeReserved(gameId, burned, rewards)`; for each `i`: `treasury.resolve(gameId, amounts[i], 0, 0, generations.tokenBoundAccount(friendIds[i]), amounts[i])`; `RoundSettled(roundId, word, secret, friendIds, amounts)`. Duplicate recipients are allowed (the sum check is what matters). Reserved for the round goes to exactly zero. |

**Permissionless and controller functions**

| Signature | Caller | Preconditions → effects |
| --- | --- | --- |
| `enter(uint256 roundId, uint256 friendId) external nonReentrant` | Friend owner or canonical wallet | status `Open` else `WrongStatus`; `registry.isActive(gameId)` else `GameNotActive` (retire stops entries); `_entrants.length < maxEntries` else `RoundFull`; `r = roundOf[gameId][friendId]`, `r == 0 \|\| rounds[r].status >= Settled` else `RoundInProgress` (a Friend is in at most one unsettled round, which also rejects double entry); `(wallet,) = FriendAccess.controlled(generations, friendId, msg.sender)`; `treasury.collect(gameId, msg.sender, Legs(0, entryPrice, 0, 0, 0, 0))` — the whole entry is reserved; burn and rewards are routed at settlement; push; `roundOf = roundId`; `Entered(roundId, friendId, wallet, msg.sender, seat)` with `seat` 1-based. |
| `abandonRound(uint256 roundId) external nonReentrant` | anyone | status `Open` or `Closed` and `block.timestamp >= openedAt + ABANDON_AFTER` else `NotAbandonable`; `_refund(roundId, true)`. Player protection against a settler that never closes or never reveals; the owner cannot block it. A word requested for an abandoned round is never read. |
| `depositCredit(uint256 gameId, uint256 friendId, uint256 amount) external nonReentrant` | Friend owner or canonical wallet | `registry.currentModule(gameId) == address(this)` else `NotCurrentModule`; `registry.isActive(gameId)` else `GameNotActive`; `FriendAccess.controlled(...)`; `treasury.creditDeposit(gameId, friendId, msg.sender, amount)`. |
| `withdrawCredit(uint256 gameId, uint256 friendId, uint256 amount) external nonReentrant` | Friend owner or canonical wallet | `(wallet,) = FriendAccess.controlled(...)`; `r = roundOf[gameId][friendId]`; `r == 0 \|\| rounds[r].status >= Settled` else `RoundInProgress`; `treasury.creditWithdraw(gameId, friendId, wallet, amount)`. Credit always returns to the canonical wallet, never to the caller. Works when retired or Draining. |
| `entrants(uint256 roundId) external view returns (uint256[] memory)`; `kindPrices(uint256 gameId) external view returns (uint128[] memory)`; `potOf(uint256 roundId) external view returns (uint256)`; `succeedable(uint256 gameId) external view returns (bool)` | any | `potOf = gross − burned − rewards` as computed in `settleRound`; `succeedable = liveRounds[gameId] == 0`. |

`_refund(roundId, abandoned)`: status `Refunded`; `--liveRounds[gameId]`; for each entrant
`treasury.resolve(gameId, entryPrice, 0, 0, generations.tokenBoundAccount(friendId), entryPrice)`;
`RoundRefunded(roundId, n, abandoned)`. Single transaction for at most `maxEntries` entrants; RF
transfers to canonical wallets cannot revert. Credit spent during the round is not refunded (those
items were delivered in play).

Routing decision (brief 4.3): burn and rewards are taken at settlement, not at entry or close. A
round with fewer than `minEntries` entries, or an abandoned round, must return every entry whole,
which is only possible if nothing has left the pot; taking the legs at settlement keeps
`reserved == entries × entryPrice` until the round is known to settle and makes both refund paths
trivially exact.

Trust boundary stated plainly: during a round the settler debits a payer Friend's prefunded credit
for term-listed kinds without a per-spend signature. The player bounds that exposure by the amount
deposited and can withdraw between rounds. A malicious settler cannot pay itself from credit
(spends go only to burn and rewards) and can only move the pot to entrants' wallets whose sum is
exact; the deterministic simulation from `(word, secret)` makes any wrong payout list provable.

### 2.12 Interfaces

`IGameRegistry`, `ITreasury`, `IRandomnessCoordinator`, `IGameItems` declare exactly the external
surfaces written in 2.6–2.9 (plus `rf()`, `usdg()` and `custody()` views on the registry) so modules compile without
importing implementations.

## 3. Terms model

### 3.1 What is stored where

| Game | Registry record | Module storage |
| --- | --- | --- |
| Rare Breeds | `module = DrawModule`, `currency = RF`, `items = GameItems(5 classes)`, `settler = 0`, `funder`, `developer = 0`, `operator = 0`, `termsHash` | 5 classes, 2 actions, 2 tables, 12 splits (all `10_000/0/0/0/0`) |
| Penalty Kings | `module = DrawModule`, `currency = USDG`, `items = GameItems(7 classes)`, `settler = 0`, `funder`, `developer = 0xd0BB…e36F`, `operator = 0x1EcB…B6d2`, `termsHash` | 7 classes, 8 actions, 1 + 42 tables, 48 splits |
| Rare Royale | `module = RoundModule`, `currency = RF`, `items = 0`, `settler = platform key`, `funder`, `termsHash` | one `Terms`, 13 kind prices |

### 3.2 Rare Breeds as Draw terms (RF, 18 decimals)

Classes (ids 1..5), `Class(value, reserve)`:

| id | name | value (owed on mint) | reserve (locked while held) |
| --- | --- | --- | --- |
| 1 | Egg | 0 | `6e18` |
| 2 | Common | `5e17` | 0 |
| 3 | Spotted | `1e18` | 0 |
| 4 | Mutant | `15e17` | 0 |
| 5 | Prismatic | `6e18` | 0 |

Action 1 `buyEggs`: `Action(Currency, 0, 0, price 1e18, draws 1, maxUnits 10, perGeneration false)`;
six splits `Split(10_000, 0, 0, 0, 0)` (the edge stays as game stake); one table with one row
`Row(10_000, classId 1, 0)`. `maxPayable = value + reserve of class 1 = 6e18`. One row ⇒ settles
inline at commit, no word. Buying N eggs collects N RF into free and reserves 6N RF; it needs
`free_before + N ≥ 6N` or the whole purchase reverts.

Action 2 `playEgg`: `Action(BurnClass, inputClass 1, inputCount 1, 0, draws 1, maxUnits 10, perGeneration false)`;
six zero splits; one table:

| row | weightBps | classId | value |
| --- | --- | --- | --- |
| 0 | 6000 | 2 Common | 0 |
| 1 | 2500 | 3 Spotted | 0 |
| 2 | 1250 | 4 Mutant | 0 |
| 3 | 250 | 5 Prismatic | 0 |

`maxPayable = 6e18` (Prismatic). Expected owed per play `0.6·0.5 + 0.25·1 + 0.125·1.5 + 0.025·6 = 0.8875 RF`.
Burning the egg releases its `6e18` reserve, the commit re-reserves `6e18`, so the pending play
holds exactly 6 RF. At settlement `owed += value`, `free += 6e18 − value`. "Trade in" is
`redeem(gameId, friendId, classId ∈ 2..5, qty, 0)` paid from `owed` forever. The baby's `context`
(`keccak256(parentA, parentB)`) is caller-supplied, emitted in `Committed`, never interpreted.
Operational consequence of the brief's backing rule: every unplayed egg locks 5 RF of the game's
free stake net of its price, so a hoarder holding 2,000 eggs against a 10,000 RF bankroll stops
egg sales until eggs are played or the funder tops up. Monitor `ledgers[gameId].free`; a per-Friend
egg cap, if wanted, belongs in the SDK, not on chain.

### 3.3 Penalty Kings as Draw terms (USDG, 6 decimals)

Classes ids 1..7 (Scuffed, Training, Match, Pro, Silver, Gold, Golden Boot), all `Class(0, 0)`.

Action 1 `buyPack`: `Action(Currency, 0, 0, price 2_000_000, draws 2, maxUnits 10, perGeneration false)`.
Splits by generation (`edge = 400 + 100·gen` bps; operator `edge / 4`, developer the rest):

| gen | freeBps | developerBps | operatorBps | burnBps | rewardsBps |
| --- | --- | --- | --- | --- | --- |
| 1 | 9500 | 375 | 125 | 0 | 0 |
| 2 | 9400 | 450 | 150 | 0 | 0 |
| 3 | 9300 | 525 | 175 | 0 | 0 |
| 4 | 9200 | 600 | 200 | 0 | 0 |
| 5 | 9100 | 675 | 225 | 0 | 0 |
| 6 | 9000 | 750 | 250 | 0 | 0 |

Check, gen 6, 10 packs: amount `20_000_000` → developer `1_500_000`, operator `500_000`, free
`18_000_000`; identical to the deployed `feeTotal / 4` arithmetic for every quantity because
`2e6 · q · bps` divides `10_000` exactly. One table (rarity):
`Row(3150, 1, 0) Row(2700, 2, 0) Row(2000, 3, 0) Row(1100, 4, 0) Row(700, 5, 0) Row(250, 6, 0) Row(100, 7, 0)`.
`maxPayable = 0`: packs reserve nothing (brief: unused balls reserve nothing).

Actions 2..8 `kickBall b` (`b = actionId − 1`): `Action(BurnClass, inputClass b, inputCount 1, 0, draws 1, maxUnits 1, perGeneration true)`;
six tables (gen 1..6). Rows are ordered highest prize first so the sampler reproduces the deployed
`prizeForRoll` boundaries; the saved row is `Row(saved, 0, 0)` with `saved = 10_000 − Σ paying`;
zero-weight rows are omitted. With `bonus = (6 − gen) · 50`:

| ball | 64e6 | 32e6 | 16e6 | 8e6 | 4e6 | 2e6 | saved (gen 6 … gen 1) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 Scuffed | — | — | — | — | — | 3300 + bonus | 6700 … 6450 |
| 2 Training | — | — | — | — | — | 4000 + bonus | 6000 … 5750 |
| 3 Match | — | — | — | — | — | 4500 + bonus | 5500 … 5250 |
| 4 Pro | — | — | — | — | — | 4800 + bonus | 5200 … 4950 |
| 5 Silver | — | — | 100 | 500 | 800 | 3600 + bonus | 5000 … 4750 |
| 6 Gold | — | 100 | 200 | 400 | 800 | 3900 + bonus | 4600 … 4350 |
| 7 Golden Boot | 100 | 100 | 200 | 400 | 800 | 3900 + bonus | 4500 … 4250 |

`maxPayable` per kick table: `2e6` for balls 1..4, `16e6` Silver, `32e6` Gold, `64e6` Golden Boot.
A kick reserves exactly that and reverts `InsufficientFree` otherwise. Row count: pack 7 + kicks
`(2+2+2+2+5+6+7) × 6 = 156` → 163 rows, one slot each.

### 3.4 Rare Royale as Round terms (RF)

`Terms(entryPrice 1e18, potBps 8000, burnBps 1000, rewardsBps 1000, spendBurnBps 5000, spendRewardsBps 5000, minEntries 5, maxEntries 50)`.
Kind prices (`kind → price`): 1 shield `1e18`; 2 medkit `1e18`; 3 second life I `2e18`; 4 second
life II `4e18`; 5 second life III `8e18`; 6 paid call `1e18`; 7 shout `1e18`; 8 aura I `2e18`;
9 aura II `2e18`; 10 aura III `5e18`; 11 title I `1e18`; 12 title II `3e18`; 13 title III `5e18`.
Pot for 50 entries = 40 RF (example ladder 8, 5, 4, 3, 2.5, 1.5 × 5 = 30 RF plus bounties summing
to 10 RF). The settler's payout list must sum to exactly `40e18`.

### 3.5 Hashing

Draw: a running hash over owner definition calls in canonical order:
`h₀ = 0`; `defineClasses`: `h = keccak256(abi.encode(h, uint8(1), classes))`;
`defineAction`: `h = keccak256(abi.encode(h, uint8(2), actionId, action, splits, tables))`.
Round: `keccak256(abi.encode(terms, kindPrices))`. The SDK compiler reproduces both offline from
the manifest with the standard ABI encoder; `activateGame` copies `module.seal(gameId)` into the
record and `succeedModule` requires the successor to return the same hash, which forces
byte-identical terms.

### 3.6 Registration transaction plan and rough gas (Cancun, cold SSTORE ≈ 22k)

| Game | Transactions | Rough gas |
| --- | --- | --- |
| Rare Breeds | `createGame` (deploys GameItems) ≈ 1.6M; `defineClasses` ≈ 0.15M; `defineAction` × 2 ≈ 0.3M + 0.4M; `activateGame` ≈ 0.1M; `fund`; `setBudget` | ≈ 2.6M over 5 owner transactions |
| Penalty Kings | `createGame` ≈ 1.7M; `defineClasses` ≈ 0.18M; `defineAction(1)` pack ≈ 0.45M; `defineAction(2..5)` balls 1..4 ≈ 0.4M each; `defineAction(6)` Silver ≈ 0.8M; `(7)` Gold ≈ 0.95M; `(8)` Golden Boot ≈ 1.1M; `activateGame` | ≈ 7.5M over 11 transactions, none above 2M |
| Rare Royale | `createGame` (no items) ≈ 0.3M; `defineTerms` ≈ 0.4M; `activateGame`; `setBudget` | ≈ 0.8M |

Terms are written only while `isSealed == false` (Draw terms are appended action by action;
Round terms are defined once), and the registry status is `Draft` throughout, so no commit can
observe partial terms. Splitting across transactions is a property of the owner's
tooling, not of the contract: every call is independently hashed into the running hash.

## 4. Accounting model

All `reserved` accounting lives in the Treasury. Modules hold only the numbers they need to issue
the matching resolution (`Commit.reservedTotal`, a round's `entries × entryPrice`), never a second
ledger. The invariant is checkable from Treasury storage alone.

### 4.1 Ledgers

Per game `Ledger {free, reserved, owed, credit}`; per currency `Totals {free, reserved, owed, credit, fees}`;
per `(currency, recipient)` `feesOwed`; RF only `rewardsPending`.

| Ledger | Meaning | Increases on | Decreases on |
| --- | --- | --- | --- |
| `free` | unencumbered game stake | `fund`; `collect.toFree`; `release`; `resolve` remainder | `reserve`; owner `withdrawFree` |
| `reserved` | locked backing: pending max prizes, held item reserves, round pots | `collect.toReserved` (round entry); `reserve`; `resolve.toKeep` | `release`; `resolve`; `routeReserved` |
| `owed` | fixed redemption liability of minted tier tokens | `resolve.toOwed` | `payOwed` |
| `credit` / `creditOf` | prefunded Round balances per Friend | `creditDeposit` | `creditWithdraw`; `creditSpend` |
| `fees` / `feesOwed` | developer and operator fees not yet paid out | `collect.developer/operator` | `payFees` |
| `rewardsPending` | RF accrued for the activation manager | rewards legs of `collect`, `routeReserved`, `creditSpend` | `forwardRewards` |

### 4.2 Which call moves which ledger

| Treasury call | caller | free | reserved | owed | credit | fees | rewards | token balance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `fund(a)` | anyone | +a | | | | | | +a |
| `collect(l)` | committing | +toFree | +toReserved | | | +dev+op | +rewards | +(total − burn) then burn |
| `reserve(a)` | bound | −a | +a | | | | | |
| `release(a)` | bound | +a | −a | | | | | |
| `resolve(a, o, k, to, p)` | bound | +(a−o−k−p) | −(a−k) | +o | | | | −p |
| `routeReserved(b, w)` | bound | | −(b+w) | | | | +w | −b |
| `payOwed(to, a)` | bound | | | −a | | | | −a |
| `creditDeposit(a)` | committing | | | | +a | | | +a |
| `creditWithdraw(a)` | bound | | | | −a | | | −a |
| `creditSpend(a = b + w)` | bound | | | | −a | | +w | −b |
| `payFees` | anyone | | | | | −a | | −a |
| `forwardRewards` | anyone | | | | | | −all | −all |
| `withdrawFree(a)` | registry owner | −a | | | | | | −a |

Reading any row: `Δbalance = Δfree + Δreserved + Δowed + Δcredit + Δfees + ΔrewardsPending`. That is
the whole proof. Game-ledger and totals deltas are written by the single private `_move`, so they
cannot drift from each other.

Module sequences:

- **Breeds buy N eggs**: `collect{toFree: N·1e18}` → `reserve(N·6e18)` → inline `resolve(6N, 0, keep 6N, wallet, 0)` (reserve stays with the minted eggs) → mint N eggs. Net: free `+N − 6N`, reserved `+6N`.
- **Breeds play N eggs**: burn N eggs → `release(N·6e18)` → `reserve(N·6e18)`; net zero. Settle with values `v_i`: `resolve(6N, Σv_i, 0, wallet, 0)` → reserved `−6N`, owed `+Σv_i`, free `+(6N − Σv_i)`; mint tier tokens.
- **Breeds redeem**: burn tokens → `payOwed(wallet, Σ value)`.
- **PK buy n packs (gen g)**: `collect{toFree: bankroll share, developer, operator}`; no reserve. Settle: no Treasury call (nothing reserved, nothing paid); mint balls.
- **PK kick (ball b)**: burn ball → `reserve(maxPayable_b)`. Settle with prize `p`: `resolve(maxPayable_b, 0, 0, wallet, p)`. A USDG transfer that returns false reverts through `SafeERC20`; the reservation stays, the commit stays unsettled, anyone retries later; the ball is already burned and its prize stays backed.
- **Royale enter**: `collect{toReserved: 1e18}`. **Settle (E entries)**: `routeReserved(E·0.1e18, E·0.1e18)` then `resolve(a_k, 0, 0, wallet_k, a_k)` for each payout with `Σ a_k = E·0.8e18`; reserved goes from `E·1e18` to exactly 0. **Refund / abandon**: `resolve(1e18, 0, 0, wallet_k, 1e18)` × E.
- **Royale credit**: deposit, withdraw and spend as in the table; a spend burns half and accrues half and never reaches free, reserved or owed, so credit cannot be laundered into withdrawable stake.
- **Owner withdraw**: `withdrawFree` reduces `free` only; it has no recipient parameter and never reads reserved, owed, credit, fees or rewardsPending.

### 4.3 The invariant and how a test checks it from Treasury state alone

For each currency `c ∈ {RF, USDG}`:

```
I1 (solvency):     balanceOf(treasury) ≥ totals[c].reserved + owed + credit + fees + (c == rf ? rewardsPending : 0)
I2 (conservation): balanceOf(treasury) == totals[c].free + reserved + owed + credit + fees + rewardsPending + donations[c]
I3 (consistency):  Σ_g ledgers[g].x == totals[c].x for x ∈ {free, reserved, owed, credit} over games with currency c
I4 (credit):       Σ_f creditOf[g][f] == ledgers[g].credit for every game g
```

`I1` is `Treasury.solvent(c)` and the stateful invariant suite asserts it after every handler call
with no knowledge of modules. `I2` is asserted with equality using a ghost `donations` counter
the handler increments only when it transfers tokens directly to the Treasury. `I3` and `I4` catch a
`_move` that updates one side only. The checker needs no module calls, no events and no off-chain
data: `totals`, `ledgers`, `creditOf`, `feesOwed` and `rewardsPending` are public.

### 4.4 Failure paths keep obligations backed

- Any revert inside `collect` (allowance, USDG issuer block, RF side effect) reverts the module's whole commit: no reservation, no request, no item burned.
- Any revert in `resolve`'s transfer leaves `reserved` unchanged and the commit or round unsettled; `settle` and `settleRound` are retryable with the same inputs.
- `forwardRewards` reverting (manager retired or replaced) leaves `rewardsPending` intact; no player transaction depends on it.
- A Dice request that is never revealed leaves `reserved` locked; `retry` restores liveness without touching ledgers. If Dice never delivers for a Breeds play, the egg's 6 RF stays reserved rather than released: the position stays backed and no owner power can release it.
- A reverted mint (receiver hook) reverts settlement; ledgers roll back with it because `resolve` and `mintBatch` are in the same transaction and the mint runs last.
- Succession changes who may call `collect`/`creditDeposit`, never the ledgers: the predecessor keeps every other primitive, so everything it reserved can still be settled, redeemed or refunded.
- Retiring flips `isActive`; the Treasury has no notion of retirement and keeps serving settlements, redemptions, refunds, fee payouts and credit withdrawals.

## 5. Randomness

- **Binding.** `request(gameId, actionKey)` with `actionKey = bytes32(commitId)` (Draw) or
  `bytes32(roundId)` (Round). `bindingKey = keccak256(abi.encode(module, gameId, actionKey))` is
  bound once for its lifetime (`AlreadyBound`), including across retries (a retry reuses the
  `requestId`). Only a module the registry reports as bound for `gameId` may request for it, so no
  module can bind another game's actions, and a Draining module can still close its own rounds.
- **User random number.** `keccak256(abi.encode(coordinator, block.chainid, requestId, attempt))`:
  unique per attempt, never derived from player input.
- **Callback.** `_entropyCallback(uint64, address, bytes32)`: authenticate Dice and the provider,
  look up the live sequence, require `Requested` and a matching stored sequence, store the word,
  flip to `Fulfilled`, delete the sequence mapping, emit. No token movement, no mint, no external
  call. Gas limit `200_000`; the body uses well under 60k, so status 3 is unreachable in practice
  and treated as a bug signal by the keeper. A zero word is valid.
- **Word read.** `word(requestId)` at settlement; modules revert `RandomnessPending` until fulfilled.
  The word is never consumed; settlement is idempotent through `Commit.settled` / `Round.status`.
- **Rolls.** `Rolls.roll(word, module, chainid, commitId, index)`, rejection-sampled to
  `[0, 10_000)`, then `Rolls.pick` over the table in declared order. Round games do not roll on
  chain: the settler's simulation consumes `(word, secret)` and anyone can replay it.
- **Retry.** Permissionless `retry(requestId)`, allowed only while the coordinator state is
  `Requested`, Dice's `getRequestV2` shows the stored sequence with `callbackStatus == 1`, and Dice's
  own `refundRequest` accepts (`blockNumber + 6`). Status 2 and 3 and cleared requests are refused
  forever. Reclaimed ETH is measured by balance delta and credited to `budget[gameId]`; the stale
  sequence mapping is deleted so a late callback reverts `InvalidRandomness`; the new request is
  charged to the same budget, and the fee cap is lifted to the reclaimed amount so a retry that
  spends no new platform ETH is never blocked. Griefing bound: one fee delta per 6 L1 blocks per
  genuinely stuck request, capped by the game's budget. Stated assumption: permissionless retry
  is fair only while the provider reveals well inside Dice's refund delay and pending reveals are
  not observable before inclusion; otherwise the party that benefits from a re-roll could time
  retries. The keeper alerts when a request ages past the delay and drives retries itself.
- **Budget and cap.** `maxFee` (owner, platform-wide; deploy value `25_000_000_000_000` wei, the
  quote verified on 2026-10-02) and `budget[gameId]` (owner, absolute wei). `_send` requires
  `fee ≤ maxFee`, `fee ≤ budget`, `fee ≤ balance`. Players never send ETH; no module function is
  payable; only `requestV2` is ever called with value.
- **Not built.** Rerolls, cancellation, fallback entropy, provider changes, timers, batching
  windows: no code path produces a word other than Dice's callback for the currently bound sequence.

## 6. Access

### 6.1 The FriendAccess rule

For Friend `f` with `o = ownerOf(f)`, `w = tokenBoundAccount(f)`, `gen = generation(f)`:

1. `gen ∈ [1, 6]` and `w.code.length != 0`, else `InvalidFriend`. Generation-0 temporary Friends
   (including the Treasury's own) and un-hardwired tokens never play.
2. Owned path: `msg.sender ∈ {o, w}`, else `NotFriendController`. Payment is pulled from
   `msg.sender`; items, prizes, refunds, credit withdrawals and redemptions always land in `w`. A
   third party holding an allowance can never be charged (named attacker: a dApp with a stale
   approval).
3. Custody path (Draw module only at launch): `msg.sender == registry.custodyExecutor()` and
   nonzero, `o == FriendCustody`, `custodyActionId != 0` and unused in the registry's global
   `custodyActionUsed` table; consumed through `registry.consumeCustodyAction` before any call
   outside the registry, so one order id is spent once across every module, game and succession
   and a later revert leaves it unused. The executor pays; everything still
   lands in `w`. The executor's only capabilities are `commit` and `redeem` for custodied Friends;
   it has no wallet execution and no settlement authority. A reverted custody call leaves the id
   unused so the same order can be retried.
4. Generation is snapshotted into the commit at step 1 and never re-read at settlement; a
   promotion after commit changes nothing already committed.

Transferring a Friend mid-flight changes `o` only; `w` is fixed per token, so pending commits,
items, owed tokens and credit follow the Friend to its new owner with no code.

### 6.2 Controller resolution for Round credit

- `depositCredit`: owned path; payer is `msg.sender`; requires the game to be active and the module
  current. Credit is recorded against `(gameId, friendId)`, never an address, so a transferred
  Friend carries its credit, still only withdrawable to its wallet.
- `withdrawCredit`: owned path; recipient fixed to `w`; refused with `RoundInProgress` while
  `roundOf[g][f]` is `Open` or `Closed`. "The game is not using it" is exactly that predicate. Never
  blocked by retirement, succession or the owner.
- `spend`: the settler, not the controller, debits credit, permitted only while the payer Friend is
  an entrant of a live round. The player's consent is the deposit plus the entry into a round
  whose terms are immutable and published. The settler cannot move credit anywhere except burn
  and rewards.
- `enter`: owned path; `msg.sender` pays `entryPrice`; refused while the Friend's latest round is
  still `Open` or `Closed` (one unsettled round per Friend).
- Settler identity: `registry.settlerOf(gameId)`, settable by the owner for Round games only.
  Changing the settler cannot change a round's `secretHash`, the pot-equality check, the entrant
  restriction or the abandonment clock.

## 7. End-to-end flows

Setup assumed: Registry (owner multisig), Treasury, Coordinator, DrawModule, RoundModule deployed;
`allowModule` for both modules; `coordinator.setMaxFee(25e12)`; coordinator funded with ETH; games
1 (Breeds, RF), 2 (Penalty Kings, USDG), 3 (Royale, RF) created, defined, activated and budgeted;
`treasury.fund(1, 10_000e18)`, `treasury.fund(2, 5_000e6)`. Friend 1234 (gen 3) owned by `O`
with wallet `W`.

### 7.1 Rare Breeds: buy 5 eggs, play one

1. `O` approves the Treasury for `5e18` RF (or `W.execute(rf.approve)` to pay from the wallet and then calls through `W.execute`).
2. `O` calls `draw.commit(1, 1, 1234, 5, 0, 0)`.
3. Module: current module and sealed; action 1 is Currency, `quantity 5 ≤ maxUnits 10`; `FriendAccess.controlled` → `(W, 3)`; `isActive(1)`; `treasury.collect(1, O, Legs(5e18, 0, 0, 0, 0, 0))` → `free 10_005e18`; `need = 6e18 × 5 = 30e18`; `treasury.reserve(1, 30e18)` → `free 9_975e18`, `reserved 30e18`.
4. `commitId 1` stored; one row ⇒ emit `Committed(1, 1, 1234, W, 1, 5, 3, 30e18, 0, 0, 0)` then inline `_settle(1, 0)`: five class-1 mints, `keep = 30e18`, `paid = owed = 0`; `treasury.resolve(1, 30e18, 0, 30e18, W, 0)` (reserved unchanged, now attributed to the held eggs); `items.mintBatch(W, [1], [5])`; `Settled(1, 1, 1234, W, [0,0,0,0,0], 0, 0)`.
5. `O` calls `draw.commit(1, 2, 1234, 1, keccak256(parentA, parentB), 0)`.
6. Module: action 2 is BurnClass class 1: `items.burn(W, 1, 1)`; `treasury.release(1, 6e18)`; `need = 6e18`; `treasury.reserve(1, 6e18)` (works even when free was zero because the release precedes the reserve); `commitId 2`; four rows ⇒ `requestId = coordinator.request(1, bytes32(2))`: fee `25e12 ≤ maxFee`, within budget; `requestV2` → sequence `s`; `Committed(2, 1, 1234, W, 2, 1, 3, 6e18, requestId, context, 0)`.
7. Dice calls `_entropyCallback(s, provider, word)`; `Fulfilled(requestId, s, word)`.
8. Anyone calls `draw.settle(2)`: `roll = Rolls.roll(word, draw, 4663, 2, 0)`; say `7_100` → cumulative 6000, 8500 → row 1 Spotted (class 3, `1e18`); `treasury.resolve(1, 6e18, 1e18, 0, W, 0)` → `reserved 24e18`, `owed 1e18`, `free 9_980e18`; `items.mintBatch(W, [3], [1])`; `Settled(2, 1, 1234, W, [1], 0, 1e18)`. The baby's look is derived off chain from `(1234, context, 2, class 3)`.
9. Later `O` calls `draw.redeem(1, 1234, 3, 1, 0)`: `items.burn(W, 3, 1)`; `treasury.payOwed(1, W, 1e18)`; `owed 0`. Works after retirement and after succession.
10. Invariant trace: after step 4 balance 10_005 = free 9_975 + reserved 30 ✓; after 8: 10_005 = 9_980 + 24 + 1 ✓; after 9: 10_004 = 9_980 + 24 + 0 ✓.

### 7.2 Penalty Kings, owned path: buy a 2-pack, settle, kick Golden Boot, settle

1. `O` approves the Treasury for `4_000_000` USDG; calls `draw.commit(2, 1, 1234, 2, 0, 0)`.
2. Module: gen 3 → `splits[2][1][3] = (9300, 525, 175, 0, 0)`: amount `4_000_000` → developer `210_000`, operator `70_000`, free `3_720_000`; `treasury.collect(2, O, Legs(3_720_000, 0, 210_000, 70_000, 0, 0))` pulls `4_000_000` and accrues `feesOwed[USDG][0xd0BB…] += 210_000`, `feesOwed[USDG][0x1EcB…] += 70_000`. `maxPayable 0` ⇒ no reserve. `commitId 3`; one request bound to `bytes32(3)`; `Committed(3, 2, 1234, W, 1, 2, 3, 0, requestId, 0, 0)`.
3. Callback stores the word. Anyone calls `settle(3)`: four rolls (`index 0..3`), e.g. rows `[0, 2, 6, 1]` → balls 1, 3, 7, 2; no Treasury call; `items.mintBatch(W, [1, 3, 7, 2], [1, 1, 1, 1])`; `Settled(3, …, [0, 2, 6, 1], 0, 0)`.
4. `O` calls `draw.commit(2, 8, 1234, 1, 0, 0)` (action 8 = kick Golden Boot).
5. Module: BurnClass class 7: `items.burn(W, 7, 1)`; class reserve 0, no release; gen 3 table for Golden Boot has `maxPayable 64e6`; `treasury.reserve(2, 64e6)` — reverts `InsufficientFree` if the bankroll cannot cover it; `commitId 4`; request; `Committed(4, 2, 1234, W, 8, 1, 3, 64e6, requestId, 0, 0)`.
6. Callback; anyone calls `settle(4)`: `roll` against `[100 → 64e6, 100 → 32e6, 200 → 16e6, 400 → 8e6, 800 → 4e6, 4050 → 2e6, 4350 saved]`; say `roll 150` → row 1 → `paid 32e6`; `treasury.resolve(2, 64e6, 0, 0, W, 32e6)` → `reserved 0`, `free + 32e6`; `Settled(4, 2, 1234, W, [1], 32e6, 0)`.
7. If USDG rejects `W` at step 6, `SafeERC20` reverts, `reserved` stays `64e6`, commit 4 stays open, anyone retries `settle(4)` later with the same deterministic result.
8. Anyone calls `treasury.payFees(USDG, 0xd0BB…)` at any cadence.

### 7.3 Penalty Kings, custody path

1. Friend 777 (gen 5) is held by FriendCustody; the grant service has verified the Privy wallet off chain and the backend picks `orderId A1`.
2. The executor `X` approves the Treasury for USDG and calls `draw.commit(2, 1, 777, 2, 0, A1)`: `msg.sender == registry.custodyExecutor()`; `registry.consumeCustodyAction(A1, 2)`; `FriendAccess.custodied` checks `ownerOf(777) == FriendCustody` and eligibility → `(W777, 5)`; split gen 5 `(9100, 675, 225)`: developer `270_000`, operator `90_000`, free `3_640_000`, pulled from `X`. Balls mint to `W777`. `Committed(…, custodyActionId A1)`.
3. Replaying `A1` reverts `InvalidCustodyAction`; `A1` is also unusable for `redeem`. A reverted call (for example `InsufficientFree`) leaves the id unused.
4. Kick: `X` calls `draw.commit(2, 8, 777, 1, 0, A2)`; the prize at settlement pays `W777`. If the Friend has left custody meanwhile, the commit reverts `NotCustodied` and the new owner kicks through the owned path.

### 7.4 Rare Royale: open, enter, spend, close, settle; refund; abandonment

1. Before the round `O` deposits credit: approve `10e18` RF; `round.depositCredit(3, 1234, 10e18)` → `creditOf[3][1234] = 10e18`, `ledgers[3].credit = 10e18`.
2. Settler `S` calls `round.openRound(3, keccak256(abi.encode(secret)))` → `roundId 9`, `Open`.
3. Each entrant's controller approves `1e18` RF and calls `round.enter(9, friendId)`: `collect(3, msg.sender, Legs(0, 1e18, 0, 0, 0, 0))`; `roundOf[3][friendId] = 9`; `Entered`. Say 12 Friends enter: `reserved = 12e18`.
4. `S` calls `round.closeRound(9)`: `12 ≥ 5` → `request(3, bytes32(9))`; `Closed`; `RoundClosed(9, 12, 9.6e18, requestId)`.
5. Dice delivers the word. The settler's simulation runs from `(word, secret)`. During the 5-second windows `S` calls `round.spend(9, 1234, target, 3)` (second life I, 2 RF): payer is an entrant of a live round; `creditSpend(3, 1234, 2e18, 1e18, 1e18)` → 1 RF burned, `rewardsPending += 1e18`, `creditOf = 8e18`; `Spent`.
6. `S` calls `round.settleRound(9, secret, friendIds[10], amounts[10])` with the ladder and bounties for 12 entries: secret preimage, word fulfilled, `Σ amounts == 12e18 − 1.2e18 − 1.2e18 = 9.6e18`, every recipient has `roundOf == 9`; `Settled`; `routeReserved(3, 1.2e18, 1.2e18)` (1.2 RF burned, `rewardsPending += 1.2e18`); ten `resolve(3, a_i, 0, 0, wallet_i, a_i)`; `reserved 0`; `RoundSettled(9, word, secret, friendIds, amounts)`. Anyone recomputes the simulation and compares.
7. `O` withdraws unspent credit: `round.withdrawCredit(3, 1234, 8e18)` → round 9 is `Settled` → `creditWithdraw(3, 1234, W, 8e18)`.
8. Anyone calls `treasury.forwardRewards()` → `forceApprove(manager, 2.2e18)`; `manager.fund(rf, 2.2e18)`. If the manager is retired, it reverts and the pending balance waits.
9. Refund: round 10 gets 3 entries. `S` calls `closeRound(10)`: `3 < 5` → three `resolve(3, 1e18, 0, 0, wallet_i, 1e18)`; `Refunded`; `RoundRefunded(10, 3, false)`. Nothing was burned or routed.
10. Abandonment: round 11 is `Closed` but `S` never reveals. After `openedAt + 1 day` anyone calls `round.abandonRound(11)` → every entry returns whole; `RoundRefunded(11, n, true)`. The requested word is never read; spent credit stays spent.
11. Invariant trace at the end of step 6: balance `12 + 10 − 1 − 1.2 − 9.6 = 10.2`; ledgers `free 0 + reserved 0 + owed 0 + credit 8 + fees 0 + rewardsPending 2.2 = 10.2` ✓.

### 7.5 Inventory succession to DrawModule v2

1. Deploy `DrawModule v2` (same `LINEAGE`, same terms ABI); owner calls `registry.allowModule(v2)`.
2. Owner replays the exact Rare Breeds terms into `v2` for game 1: `v2.defineClasses(1, …)`, `v2.defineAction(1, …)` × 2. `v2` is not bound yet: `Treasury`, `GameItems` and `Coordinator` all report `isBound(1, v2) == false`, so it cannot act.
3. Owner calls `registry.succeedModule(1, v2)`: same lineage; `v2.seal(1)` returns the recorded `termsHash` (else `TermsMismatch`); `bindingOf[1][v1] = Draining`; `bindingOf[1][v2] = Active`; `module = v2`; `ModuleSucceeded(1, v1, v2)`.
4. A play committed on `v1` before succession (commit 2 pending): Dice fulfils; anyone calls `v1.settle(2)`: `v1` reads its own commit, calls `treasury.resolve` (bound) and `items.mintBatch` (bound). Settles exactly as before. A stuck `v1` request is still retryable by anyone because `retry` is keyed by `requestId`.
5. New plays: `v1.commit` reverts `NotCurrentModule`; `v2.commit(1, 2, 1234, 1, ctx, 0)` burns the egg (bound), releases and reserves (bound), requests a word (bound). Eggs minted by `v1` are played through `v2`; their 6 RF reserve is still in `ledgers[1].reserved`.
6. Redeeming a tier token minted by `v1`: `v2.redeem(1, 1234, 3, 1, 0)` and `v1.redeem(...)` both work (same class values from the same terms; `burn` and `payOwed` accept any bound module). Nothing is migrated because nothing lived in the module.
7. A Round game is succeeded only between rounds: `succeedModule` reverts `ModuleBusy` while `liveRounds(gameId) != 0`, because the per-Friend credit lock is the predecessor's `roundOf` and a successor could not see it. Rounds end within a day at most through `abandonRound`.

### 7.6 Retire a game

1. Owner calls `registry.retireGame(2)`; `Retired`; `GameRetired(2)`.
2. `draw.commit` with a Currency action (pack purchase) reverts `GameNotActive`. BurnClass actions (kicks, egg plays), `settle`, `redeem` and `treasury.fund` keep working.
3. Owner may `treasury.withdrawFree(2, amount)` down to `free == 0`. Kicks then revert `InsufficientFree` until someone funds again, which is acceptable because balls carry no payout promise; eggs are unaffected because their 6 RF sits in `reserved`, and tier tokens are in `owed`. No pending or kept position with a value promise is stranded.
4. For a Round game, `retire` blocks `openRound`, `enter` and `depositCredit` only; open rounds close, settle, refund or abandon as usual; credit withdrawal is unaffected.

## 8. Size and gas plan

Estimates at `optimizer_runs = 200`, no `via_ir`, from comparable shipped code (ChanceGame with
ERC-1155 inlined ≈ 10 KB; PenaltyKingsPark ≈ 11.5 KB; GameERC1155 ≈ 5 KB).

Measured runtime sizes after implementation (optimizer 200, no `via_ir`): `DrawModule` 17,361 B,
`GameRegistry` 13,480 B (including the embedded `GameItems` creation code), `RoundModule` 12,070 B,
`Treasury` 9,423 B, `GameItems` 6,113 B, `RandomnessCoordinator` 5,552 B. No split was needed; the
estimates and fallbacks below are kept for the next revision.

| Contract | Estimate | Risk | Mitigation if over |
| --- | --- | --- | --- |
| `DrawModule` | 15–19 KB | **medium-high** | (1) Promote `DrawTables` to a linked external library with `public` `validate` (storage-pointer argument works through `DELEGATECALL`), ≈ −2.5 KB. (2) Move the `defineAction` validation body into that library as well. (3) Last resort: pack `Settled.rows` as `bytes`. Measure after the first compile; apply (1) and (2) before writing more code if above 22 KB. |
| `GameRegistry` | 7–9 KB logic + ≈ 6–7 KB embedded `GameItems` creation code | medium | If above 22 KB, move `new GameItems` into a one-function `ItemsDeployer` contract called by the registry (justified by the size limit only). |
| `Treasury` | 9–11 KB | low | Fifteen small functions and one `_move`. |
| `RoundModule` | 10–12 KB | low | Settle and refund loops share `_payEntrant`. |
| `RandomnessCoordinator` | 6–7 KB | none | — |
| `GameItems` | 6–7 KB | none | — |

`test/Sizes.t.sol` asserts every runtime is at most `24_576 − 512` bytes via `vm.getDeployedCode`
so the split is applied before it bites.

Hot-path gas targets (Cancun, cold storage; the suite asserts upper bounds at 1.5× these): Breeds
`commit(buyEggs, 5)` ≈ 240k; `commit(playEgg)` ≈ 190k + Dice `requestV2` ≈ 90k; `settle` ≈ 150k;
PK `commit(buyPack, 2)` ≈ 180k + Dice; PK kick ≈ 170k + Dice; kick settle ≈ 120k; Royale `enter`
≈ 110k; `closeRound` ≈ 60k + Dice; `settleRound` with 50 entrants and 10 payouts ≈ 650k (each RF
transfer triggers two `syncPreview` calls); refund of 50 ≈ 2.5M in one transaction; `spend` ≈ 75k.
Registry lookups through external views add ≈ 3k per core-contract call.

## 9. Test plan

Doubles exist in `test/doubles/ExternalDoubles.sol` (`MockRF` with the `syncPreview` side effect,
`MockUSDG` with a blockable recipient, `MockGenerations`, `MockFriendWallet`, `MockCustody`,
`MockDice` with the live request struct, status codes, reveal and refund, `MockActivationManager`).
`test/Fixture.sol` deploys the hub, allowlists both modules and registers the three launch games
with the exact terms of section 3; every test file and the simulation script share it.

| File | Named invariants and key tests |
| --- | --- |
| `GameRegistry.t.sol` | `testOwnerSurfaceIsExactlyEnumerated` (every non-view selector reverts for a non-owner and is listed in 10.1); `renounceOwnership` reverts; `createGame` deploys items and records the game; `SettlerRule` both ways; `activateGame` requires a nonzero seal; `retireGame` from `Active` only; `succeedModule` lineage, `AlreadyBound`, `TermsMismatch`, bindings flip; `setSettler` Round-only; executor rotation; `consumeCustodyAction` only by a bound module of that game, never twice, zero id rejected. |
| `Treasury.t.sol` | role gating (`NotCommittingModule`, `NotBoundModule`, `NotRegistryOwner`); `UnsupportedLeg` for USDG burn/rewards; `NoRecipient`; `_move` keeps `I3` (`INV_LEDGER_TOTALS`); `withdrawFree` bounded by `free` and paid to the funder only (`INV_FREE_ONLY`); `resolve` reverts whole on a blocked USDG recipient and keeps `reserved`; `payFees` with a blocked recipient keeps its ledger; `forwardRewards` with retired or replaced manager; `fund` by anyone; fuzz over random primitive sequences keeps `I1`. |
| `RandomnessCoordinator.t.sol` | bound-module-only request; `AlreadyBound`; `FeeAboveCap`; budget exhaustion and accounting across retry; callback authentication (sender, provider, unknown sequence, duplicate, stale sequence); zero word valid; `retry`: too early (Dice `RefundNotAvailable`), status 2 and 3 refused, cleared refused, success rebinding, late callback for the stale sequence rejected, reclaimed fee credited (`INV_RETRY_LEDGER_NEUTRAL`: module and Treasury state unchanged); `withdraw` and setters owner-only; `receive` from anyone. |
| `GameItems.t.sol` | Bound transfers revert directly and through `execute` and approved operators; mint/burn only by bound modules (flips with succession); `UnknownClass`; `setURI` registry-only. |
| `DrawModule.t.sol`, `GameItems.t.sol`, `GameRegistry.t.sol`, `Treasury.t.sol`, `RandomnessCoordinator.t.sol`, `RoundModule.t.sol` | per-contract unit suites against stubs of the sibling contracts: FriendAccess matrix (generation 0 and 7, wallet without code, owner, wallet, stranger, custody executor paths), DrawTables validation and hash determinism, Treasury `_move` conservation per primitive, coordinator binding and retry rules, registry owner surface and bindings, Round state machine. |
| `LaunchTerms.t.sol`, `Smoke.t.sol`, `ReviewFixes.t.sol` | the launch terms reproduce the deployed Penalty Kings odds for all 42 tables with exact 90%–95% returns; an end-to-end smoke of both Draw games; regressions for the review findings (multi-draw reservation, valued burn inputs, zero pot, Round succession gate, retry cap bypass, quiet Dice refunds). |
| `RoyaleFlows.t.sol` | Rare Royale through the real Treasury and coordinator: flow 7.4 with twelve entrants and the exact invariant trace, refund, abandonment from Open and Closed, one unsettled round per Friend, retire semantics, settler rotation. |
| `RareBreeds.t.sol` | exact table boundaries (rolls 0, 5999, 6000, 8499, 8500, 9749, 9750, 9999); expected value `0.8875e18`; every egg reserves 6 RF and a pending play holds 6 RF; settlement moves reserve to owed and free; `redeem` pays exactly after years; `context` emitted; purchase needs `free_before + N ≥ 6N`; NFT transfer carries eggs, pending plays and tier tokens; `maxUnits` bounds `quantity`. |
| `PenaltyKings.t.sol` | rarity table exact; all 42 kick tables equal `PenaltyKingsPark.payoutOdds`/`prizeForRoll` for every roll (`testKickTablesMatchDeployedForEveryBallAndGeneration`); overall return per generation exactly 90%..95% (`testGenerationReturns`); splits reproduce the deployed fee arithmetic for quantities 1, 2, 5, 10 × gens 1..6; kick reserves max and releases the remainder; blocked USDG payout stays reserved and retryable; custody replay protection (reuse, zero id, non-executor, non-custodied, left custody, revert leaves id unused); fees accrue and `payFees` pays. |
| `RoundModule.t.sol` | entry routes nothing until settlement; settle burns and accrues 10% each and pays the exact list; `PotMismatch` at ±1 wei; `NotEntrant`, `BadSecret`, `RandomnessPending`, `RoundFull`, `UnknownKind`; a Friend cannot enter a second round while its first is unsettled (`RoundInProgress`) and can once it is settled, refunded or abandoned; close with fewer than `minEntries` refunds exactly; `abandonRound` refuses before the clock and refunds whole after it, from `Open` and from `Closed`; `spend` only by the settler, only for entrants, only in live rounds; `withdrawCredit` blocked while the round is live and always pays the wallet; settler rotation unblocks a stuck round that still has its secret. |
| `Succession.t.sol` | section 7.5 end to end: pending v1 commit settles after succession, `v1.commit` refused, v2 burns v1-minted eggs and redeems v1-minted tiers, coordinator still retries v1's stuck request, mismatched terms and different lineage refused, ledgers unchanged (`INV_SUCCESSION_PRESERVES_INVENTORY`). |
| `OwnerSurface.t.sol` | for every owner function: non-owner reverts; the owner cannot alter sealed terms, move `reserved`/`owed`/`credit`/`fees`, mint, burn, settle or block settlement. |
| `Reentrancy.t.sol` | a malicious ERC-1155 receiver wallet re-entering `commit`, `settle`, `redeem`, `enter`, `withdrawCredit` reverts; RF `syncPreview` re-entry attempt into the Treasury reverts. |
| `invariant/Platform.invariant.t.sol` | handler drives fund, commit, settle, redeem, enter, close, spend, settle/refund/abandon rounds, deposit, withdraw, retry, `withdrawFree`, `payFees`, `forwardRewards`, donations and Dice reveals across all three games; asserts `invariant_solventPerCurrency` (I1), `invariant_conservation` (I2 with ghost donations), `invariant_ledgerTotals` (I3), `invariant_creditSums` (I4), `invariant_reservedMatchesPending` (Σ unsettled `reservedTotal` + egg supply × 6e18 + Σ live round entries == `reserved`), `invariant_owedMatchesSupply` (Σ class value × supply == `owed` for Breeds), `invariant_oneRequestPerAction`, `invariant_coordinatorHoldsNoPlayerMoney`. `fail_on_revert = false`, 64 runs × depth 32 as configured. |
| `Sizes.t.sol` | every runtime ≤ `24_576 − 512` bytes. |
| `Flows.t.sol` | the six numbered flows of section 7 as end-to-end tests with ordered event assertions (what the keeper and indexer rely on). |
| `MainnetFork.t.sol` | gated on `PLATFORM_FORK_RPC`: real RF transfer into the Treasury (temporary Friend appears), real Generations reads for a known hardwired token, real wallet `execute`, real `FriendCustody.beneficiary`, real `getFeeV2 == 25e12`, real `requestV2`, `getRequestV2` layout decode and `refundRequest` after `vm.roll(+6)`. Never broadcasts. |
| `script/Deploy.s.sol`, `script/RegisterLaunchGames.s.sol` | simulation only; print addresses, `termsHash` values and gas; no broadcast. |

## 10. Owner powers, deliberate omissions, deviations

### 10.1 Owner powers — the complete list

| Contract | Function | Bound |
| --- | --- | --- |
| GameRegistry | `allowModule(address)` | once per module; lineage read from the module; no revocation |
| GameRegistry | `createGame(…)` | creates a Draft record, its items collection and bindings |
| GameRegistry | `activateGame(gameId)` | Draft → Active after the module validates and freezes terms |
| GameRegistry | `retireGame(gameId)` | stops purchases, deposits, round opens and entries only |
| GameRegistry | `succeedModule(gameId, successor)` | same lineage, identical terms hash, predecessor keeps settling |
| GameRegistry | `setSettler(gameId, address)` | Round lineage only |
| GameRegistry | `setItemsURI(gameId, string)` | metadata only |
| GameRegistry | `setCustodyExecutor(address)` | rotatable key; zero disables custody paths |
| GameRegistry | `transferOwnership` / `acceptOwnership` | two-step; `renounceOwnership` reverts |
| DrawModule | `defineClasses`, `defineAction` | only while the game's terms are not sealed |
| RoundModule | `defineTerms` | only while not sealed |
| Treasury | `withdrawFree(gameId, amount)` | `free` ledger only, to the recorded funder |
| RandomnessCoordinator | `setMaxFee(uint128)`, `setBudget(gameId, uint256)`, `withdraw(to, amount)` | platform ETH only |

Nothing else has an owner check. The owner cannot change sealed terms, odds, prices or splits;
move `reserved`, `owed`, `credit`, `fees` or `rewardsPending`; mint, burn or move items; settle,
redeem, reroll, cancel or replace a request; replace Dice, the provider, the Treasury or the
Coordinator for an existing game; revoke a module; block any settlement, redemption, refund,
abandonment, fee payout, rewards forwarding or credit withdrawal; or renounce ownership.

### 10.2 Deliberately not built

| Omitted | Reason tied to the brief |
| --- | --- |
| Separate items factory, proxies, upgradeable logic, timelocks, pause switches, rescue functions | brief §1 non-goals, §5.1; succession plus sealed terms replaces upgrades; the multisig imposes delay operationally |
| `Free` transfer policy, per-class caps, supply counters, trading | §5.4: `Free` only if a launch game needs it (none does); no launch class is capped — Commandment V |
| Controller slot in `GameItems`, module list in the Treasury | both duplicate `registry.isBound`; succession needs one registry write instead of three — Commandment III |
| Treasury `openGame` or money fields duplicated in the Treasury | the registry record is the single source; the Treasury reads it |
| Module de-allowlisting | not in the owner list; a bad module is never given new games or is succeeded |
| Game-side randomness timer, cancel, reroll, fallback entropy, mutable provider | brief §3 and AGENTS.md forbid them; Dice's `refundRequest` is the only recovery |
| Owner-only retry | griefing cost is bounded by Dice's delay and the game budget; permissionless removes a liveness dependency |
| Per-round spend caps and recipient de-duplication on chain | §4.3: caps are the settler simulation's job; the pot sum is what matters |
| Permissionless Round settlement | the payout list is the settler's simulation; `setSettler` plus `abandonRound` are the recoveries |
| Custody path in `RoundModule` | §4 table: not required at launch; a later module version adds it with `FriendAccess.custodied` and a replay mapping |
| Stored wallet, stored context, stored pot or entry count, stored secret, per-round entrant maps | all derivable (`tokenBoundAccount`, events, `entrants.length × terms`); one `roundOf` slot plus the one-live-round rule replaces a per-round map — Commandment III |
| `payer` parameter on commit and entry | paying from the Friend wallet means calling through `wallet.execute`; one rule, no allowance-based third-party charging |
| Classes with both `value` and `reserve` | forbidden at definition so settlement arithmetic has one case per kind — Commandment I |
| ERC-20 and ERC-721 game assets, Crash (Slingshot), hearts, hats, wild Friends, the Royale simulation | §1 non-goals and §4: off chain or later modules; nothing in the core prepares for them |
| Any read of a client clock, client-authored save blobs, resource grants on request | SDK rules; every outcome is contract-computed from the word or settler-verified against the pot |

### 10.3 Deviations from the reference contracts, each to be accepted or rejected explicitly

1. **One Dice word per commit group.** A Draw commit of `quantity` units (up to `maxUnits`) and a
   Round close each request one word; rolls are domain-separated per unit and draw. The deployed
   PenaltyKingsPark requested one word per pack and per kick; the distribution is identical and the
   platform pays one fee per purchase instead of up to ten. The SDK can still submit one commit per
   pack if the team wants the literal behaviour.
2. **Quantity range instead of a whitelist.** `maxUnits` admits `1..maxUnits` (PK packs: 1..10, eggs
   1..10); the client offers 1/2/5/10 and 1/5. The ceiling exists to bound settlement gas so a
   player cannot create an unsettleable commit that locks bankroll (named attacker, 2.5).
3. **Egg purchase backing rule.** The generic rule is `free_before + payment ≥ quantity × maxPayable`;
   v1 ChanceGame additionally required `free_before ≥ maxPrize`. The game stays fully backed after
   every purchase either way; the stricter pre-check is not reproduced.
4. **Developer and operator fees accrue** in the Treasury and are paid permissionlessly through
   `payFees` instead of being transferred inline from the payer as PenaltyKingsPark does, so a frozen
   USDG fee address can never block a purchase.
5. **Round entry burn and rewards are routed at settlement**, not at entry, so refunds (fewer than
   `minEntries`, or abandonment) return every entry whole.
6. **Abandonment refund after one day** (`abandonRound`) protects entrants from a settler that
   never closes or never reveals its secret; the brief did not specify this recovery.
7. **Custody beneficiary is not read on chain**; the executor key plus `ownerOf == custody` plus a
   consumed action id is the deployed PenaltyKingsPark rule, kept as is. The replay table is
   global in the registry rather than per contract.
8. **A Dice request whose callback failed (status 3) is never re-requested** and its commit stays
   pending with its reservation locked. The store-only callback cannot realistically fail within
   200,000 gas, and the brief's Dice rules forbid any other word source; the team should confirm
   this consequence explicitly.
9. **One unsettled round per Friend** in Rare Royale: a Friend cannot enter the next lobby until
   its previous round is settled, refunded or abandoned. With a five-minute cadence and prompt
   settlement this is invisible; it exists so a single `roundOf` slot stays correct.
