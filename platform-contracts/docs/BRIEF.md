# Rare Friends platform contracts — requirements brief (v1)

This brief is the single source of requirements for the platform-owned game contracts.
Read it fully before designing, implementing or reviewing anything under `platform-contracts/`.
Paths are relative to the FriendSDK checkout root unless absolute.

## 0. Read first

- `contracts/COMMANDMENTS.md` and `contracts/AGENTS.md` (house style and scope rules). The
  production copy is `~/rarefriends-production/barebones-final/AGENT_COMMANDMENTS.md`.
- `contracts/src/ChanceGame.sol`, `contracts/src/Consumable.sol`, `contracts/test/ChanceGame.t.sol`
  (the shipped v1 single-game contract; its backing model and Dice flow are the reference).
- `~/penalty-kings-mvp/contracts/src/PenaltyKingsPark.sol` and its tests under
  `~/penalty-kings-mvp/contracts/test/` (the deployed USDG game; custody entry points; fee routing).
- `~/rarefriends-production/barebones-final/experiences/src/` (earlier platform prototypes:
  `ExperienceEngine.sol`, `randomness/RandomnessBatches.sol`, `economy/EconomyLaunchpad.sol`,
  `economy/GameERC1155.sol`, `economy/GameERC20.sol`, `economy/EconomyTypes.sol`) and their tests
  under `experiences/test/`. Reuse ideas and code where they fit; they are not the spec.
- `docs/oracle/plan-recovery.md` (the reviewed design for reclaiming an unrevealed Dice request).

## 1. Goal

One platform-owned contract system on Robinhood Chain (chain id 4663) that runs games published
by third-party developers on rarefriends.com. Developers never write Solidity: a game is a
registered record of an immutable **mechanic module** plus immutable **terms** compiled from the
developer's manifest. Rare Friends owns, deploys, funds and operates the contracts, manages the
game assets, pays on-chain randomness, and must be able to add new on-chain mechanics without
redeploying or re-funding what already exists.

Launch scope is exactly three games (section 4). Build what they need. Do not build for games
that do not exist yet; when a choice is free, prefer the one that leaves a clean seam for a later
module rather than code for it now.

Non-goals for v1: trading or transferable items, creator fee markets, Harberger or auction
mechanics, the Rare Breeds Moon Slingshot (crash game), ERC-20 or ERC-721 game assets, proxies
or upgradeable logic, timelocks, pause switches on settlement paths, any change to RF,
Generations, the canonical NFT wallets, FriendCustody, ActivationManager or Dice.

## 2. House style and the admin boundary

Apply the commandments as house style: custom errors never `require` strings; constants over
immutables over storage; `UPPER_SNAKE` constants; leading underscore for internal/private; no
wrapper that only forwards a call; no getter that duplicates public state; no event for a value
that cannot change; Solidity `^0.8.36`; OpenZeppelin imported from `lib/`; `forge fmt` clean with
the repository `foundry.toml`; every contract under the 24,576-byte runtime limit without
`via_ir`. Name the attacker before adding a check. Delete before you add.

The commandments forbid owner widening on Genesis. These are platform contracts, so a **minimal,
enumerated** owner surface is expected (the production economy already has approved owner
setters). The owner is one Rare Friends address (multisig), `Ownable2Step`, renounce disabled.
Everything not in this list is forbidden:

- Registry: allowlist a module contract; register a game instance (module, terms, assets, funder,
  settler); retire a game instance (stops new purchases or entries only); point an asset
  collection at a different allowlisted module instance of the same lineage (inventory
  succession); set an asset collection's metadata URI; set the custody executor; set a game's
  settler (Round module only).
- Treasury: withdraw **free** stake of a game to its recorded funder; nothing else. Anyone may
  fund any game.
- Randomness: set the maximum Dice fee the platform will pay; set a per-game request budget;
  withdraw the coordinator's own ETH (platform money, never player money).

The owner can never: change a live game's terms, odds, prices or splits; move reserved or owed
funds; mint, burn or move items; block settlement, redemption, claims or credit withdrawal;
replace Dice or the provider for an existing game; reroll, cancel or replace a revealed result.

Player protections that must hold as invariants: terms immutable per game instance; generation
snapshotted when an action commits; one randomness request bound once per committed action or
round; settlement permissionless; rolls domain-separated and bias-free (rejection sampling to the
10,000-outcome range as in PenaltyKingsPark); Treasury balance per currency ≥ Σ reserved + Σ owed
+ Σ player credit, with no admin bypass; retiring never strands a pending or kept position.

## 3. External dependencies (exact, verified)

All are existing mainnet contracts accessed through interfaces typed in our code. Test doubles
live in `test/` only.

### RF — `0x0779369854d3EcdEA927206718FFD7730C67B71f`

`RareFriends is ERC20Burnable`: standard ERC-20 plus `burn(uint256)` and `burnFrom`. 18 decimals.
Side effect: every transfer calls `Generations.syncPreview(account, balance)` for `from` and `to`;
a contract holding ≥ 1 RF is minted a non-transferable generation-0 "temporary Friend" (plain
`_mint`, no receiver hook) and it is burned when the balance drops below 1 RF. Harmless, but any
contract that holds RF will own such a token. `Generations.token()` returns RF.

### USDG — `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`

Plain ERC-20 with 6 decimals. Conventional balances and transfers; fee-on-transfer or rebasing
tokens are unsupported. Issuer restrictions can make a transfer revert; a reverted payout must
keep its reservation and stay retryable (PenaltyKingsPark pattern).

### Generations — `0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D`

```solidity
function ownerOf(uint256 tokenId) external view returns (address);
function generation(uint256 tokenId) external view returns (uint8); // 0 = temporary, 1..6 hardwired
function tokenBoundAccount(uint256 tokenId) external view returns (address); // canonical ERC-6551
function token() external view returns (address); // RF
function activationManager() external view returns (address); // may change over time
```

Eligible Friend: `generation ∈ [1, 6]` and `tokenBoundAccount(id).code.length != 0` (the account
is created at hardwire). Generation 0 is never eligible. Promotion lowers the number toward 1.
Transferring a hardwired Friend calls `activationManager.clearActivation` (no try/catch).

### Canonical NFT wallet (ERC-6551 `TokenBoundAccount`)

`execute(address to, uint256 value, bytes data, uint8 operation)` callable only by the NFT's
current owner; `operation` must be 0; `owner()` resolves `ownerOf`. It accepts ERC-1155 via
`ERC1155Holder`. Inventory, prizes and credits belong to this wallet, never to the owner address.

### FriendCustody — `0x37702f6b25217e5ef34f6b3af589476cea35be3a`

Holds Friends issued to new accounts. `beneficiary(uint256 tokenId) view returns (address)`:
zero until the custody operator binds a payout wallet. Off chain, a grant service signs a custody
ticket naming the Privy wallet allowed to play a custodied Friend; Nakama and the website verify
`ownerOf == custody`, `generation ∈ [1,6]` and `beneficiary ∈ {0, wallet}`. On chain, a platform
**custody executor** key acts for custodied Friends. PenaltyKingsPark's rule, which we keep:
executor-only entry points, `ownerOf(friendId) == custody`, a nonzero unused `bytes32 actionId`
consumed on success (replay guard shared across its actions), the executor pays, and every item
or prize still lands in the Friend's canonical wallet. The executor has no arbitrary wallet
execution power. Current executor key: `0xd76a0393F3CE045E6f49f6e97AfD41EC98CcBd61` (rotatable).

### Dice Entropy — `0xd8a0680e7699526b57140ed4eafdcc7219dc0a0c`, provider `0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6`

Pyth-Entropy-derived commit-reveal oracle (source: github.com/diceprotocol/dice-entropy). Verified
on 2026-10-02 against the live contract: fee `getFeeV2(provider, 200000) = 25_000_000_000_000`
wei (0.000025 ETH); `getRefundDelayBlocks() = 6` (L1 blocks, roughly 72 s).

```solidity
function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128);
function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
    external payable returns (uint64 sequenceNumber); // msg.value must equal the fee exactly
function refundRequest(address provider, uint64 sequenceNumber) external;
    // requester only; reverts RefundNotAvailable before blockNumber + refundDelayBlocks;
    // clears the request, then sends feePaid to the requester with a plain call (requester
    // must accept ETH); reverts NoSuchRequest / Unauthorized otherwise.
function getRequestV2(address provider, uint64 sequenceNumber) external view
    returns (Request memory); // struct below; sequenceNumber == 0 means cleared/unknown
function getRefundDelayBlocks() external view returns (uint64);

struct Request { // storage layout, in order
    address provider; uint64 sequenceNumber; uint32 numHashes;
    bytes32 commitment;
    uint64 blockNumber; address requester; bool useBlockhash; uint8 callbackStatus; uint16 gasLimit10k;
    uint128 feePaid;
}
// callbackStatus: 1 = callback not started, 2 = in progress, 3 = callback failed (word is public!)
```

Delivery: Dice calls `_entropyCallback(uint64 sequence, address provider, bytes32 randomNumber)`
on the requester. The callback must be store-only: authenticate `msg.sender == dice` and
`provider`, reject unknown or already-fulfilled sequences, record the word, emit. Never transfer
tokens or mint in the callback. If a callback reverts, Dice marks status 3 and the word is
already public, so a request in status 3 must never be re-requested. A zero word is valid.
Callback gas limit: 200,000. Never add rerolls, cancellation, fallback entropy or a mutable
provider. Reclaim-and-retry is allowed only through Dice's own `refundRequest` after its delay,
for a request whose `getRequestV2` shows `sequenceNumber == stored` and `callbackStatus == 1`
(see `docs/oracle/plan-recovery.md`). Dice fees are platform-paid in this architecture: players
send no ETH.

### ActivationManager (resolve via `generations.activationManager()`)

`fund(address asset, uint256 amount) external` pulls an approved amount of RF (or WETH) into the
pending reward stream for active Friends. It reverts when the manager is `retired()`. This is the
protocol's "rewards" destination: the protocol's gameplay rule is **50% burn, 50% fund rewards**.
Only RF can be routed there. Because the manager can be replaced or retired, never pay it inline
on a player's transaction path; accrue a rewards ledger and forward permissionlessly.

## 4. Launch games and exact economics

| Need | Rare Breeds (PR 81) | Rare Royale (PR 63) | Penalty Kings (`~/penalty-kings-mvp`) |
| --- | --- | --- | --- |
| Currency | RF | RF | USDG |
| Purchase | 1 RF egg, prepaid consumable, bulk 1 or 5 | 1 RF round entry into a shared pot; micro-payments mid-round | 2 USDG pack = 2 random balls; quantities 1, 2, 5, 10 |
| Randomness | one word per play group, 4-row table | one word per round shared by all entrants | one word per pack (2 draws), one word per kick |
| Outcome authority | contract | platform settler from (Dice word, revealed secret), replayable off chain | contract |
| Items | Friend-bound tier tokens with redemption value; parent pair recorded per play | none kept | Friend-bound balls, 7 classes, no value |
| Payout | fixed redemption value, no expiry | ladder and bounties from the pot; refund if < 5 paid entries | immediate USDG transfer at settlement |
| Backing | reserve max prize (6 RF) per unused egg and pending play | pot only | reserve the ball's max prize at kick; unused balls reserve nothing |
| Routing | edge stays as game stake | entry: 60% ladder, 20% bounty pool, 10% burn, 10% rewards; every other payment 50% burn, 50% rewards | gross edge `400 + 100·gen` bps split 75% developer / 25% operator; the rest stays as bankroll |
| Generation | none | none on chain | kick odds and purchase edge depend on generation |
| Custody | not required at launch | not required at launch | required (executor path) |

### 4.1 Rare Breeds egg loop

Egg price 1 RF. Outcomes (bps, redemption value): Common 6000 / 0.5 RF; Spotted 2500 / 1 RF;
Mutant 1250 / 1.5 RF; Prismatic 250 / 6 RF. Expected 0.8875 RF. Every unused egg and pending
play reserves 6 RF; a settled tier token owes its fixed value forever until redeemed. Buying N
eggs is one transaction. Playing one egg commits one play; the baby's look is deterministic from
(friendId, parent pair, playId, tier), so the module must accept and record a caller-supplied
`bytes32 context` per play and expose it in the event. Kept babies are simply held tier tokens;
"trade in" is `redeem`. Hearts, hats and the Slingshot stay off chain in v1.

### 4.2 Penalty Kings

USDG has 6 decimals; pack price `2e6`. Quantities 1, 2, 5, 10, paid by the Friend owner from the
owner address or the Friend wallet, or by the custody executor for a custodied Friend. Each pack
requests its own word and settles two independent draws from rarity weights (ball ids 1..7:
Scuffed 3150, Training 2700, Match 2000, Pro 1100, Silver 700, Gold 250, Golden Boot 100).
Purchase routing uses the generation at purchase: `edgeBps = 400 + 100 * generation`,
`feeTotal = price * edgeBps / 10_000`, `operator = feeTotal / 4`, `developer = feeTotal − operator`,
bankroll keeps the rest. Developer `0xd0BB5CC938dA89E0d7129F1eE01C2cfc61C2e36F`, operator
`0x1EcBF27dC1F809179B9ef2d382cd76ccBa21B6d2`.

Kick: burn one ball, snapshot generation, reserve that ball's maximum prize, request a fresh word.
Prize ladder `2, 4, 8, 16, 32, 64` USDG (`2e6 << (i−1)`). Per-kick odds in bps, indexed
[saved, 2, 4, 8, 16, 32, 64]:

- balls 1..4: only the 2 USDG outcome, at 3300 / 4000 / 4500 / 4800 for ball 1..4;
- Silver (5): `[_, 3600, 800, 500, 100, 0, 0]`; Gold (6): `[_, 3900, 800, 400, 200, 100, 0]`;
  Golden Boot (7): `[_, 3900, 800, 400, 200, 100, 100]`;
- then `odds[1] += (6 − generation) * 50` and `saved = 10_000 − Σ odds[1..6]`.

Maximum prize per ball: 2 USDG for balls 1..4, 16 Silver, 32 Gold, 64 Golden Boot. A kick needs
free bankroll ≥ that maximum. Settlement pays the exact prize to the Friend wallet and releases
the reservation; a failed transfer reverts and stays retryable. Overall return by generation is
exactly 90% (gen 6) through 95% (gen 1); tests must reproduce these tables exactly.

### 4.3 Rare Royale

Entry 1 RF per paid seat; up to 50 seats, empties filled by wild Friends off chain. Rounds run
on a shared clock off chain; the contract only needs: open a round with the settler's secret
hash; accept entries while open; close entries and request one Dice word; settle with the
revealed secret and an explicit payout list to Friend wallets whose sum equals the pot
(ladder + bounty pool = 80% of entries); refund every entry if fewer than 5 paid entries; nothing
else is kept. Example ladder for 50 entries: 8, 5, 4, 3, 2.5, then 1.5 × 5 (30 RF = 50 × 0.6).
Bounties are pot-internal. Entry routing: 10% burn, 10% rewards at entry (or at settlement; the
designer decides, state why). All other payments burn 50% and send 50% to rewards immediately
and are consumed at once: shield 1 RF, medkit 1 RF, second life 2 / 4 / 8 RF (max 3 per Friend
per round), paid call 1 RF (max 4 per round), shout 1 RF, auras 2 / 2 / 5 RF, titles 1 / 3 / 5 RF.
The payer may target any Friend (sponsoring). These happen inside 5-second windows, so they must
debit a **prefunded credit balance** per (game, Friend) with no wallet prompt; the controller
deposits before a round and can withdraw unspent credit at any time the game is not using it.
Prices and kinds are terms; per-round caps are enforced by the settler's simulation, not on
chain. Anyone can verify a round by recomputing the deterministic simulation from the word and
the revealed secret.

## 5. Architecture decisions already made

Hub-and-spoke. Four long-lived core contracts hold money, the Dice relationship, the inventory
and the registry. Immutable mechanic modules hold no funds and each serve many games, keyed by
`gameId`. Terms are stored on registration and hashed into the registry record.

1. **GameRegistry** (owner surface in section 2). Maps `gameId → {module, termsHash, currency,
   funder, settler, status}`; module allowlist; asset collections with their current controller.
   Registration deploys the game's asset collection(s) through the registry (no separate factory
   in v1). Retiring an instance stops new purchases or entries only.
2. **Treasury**. Custody of RF and USDG with per-game ledgers: `reserved`, `owed` (fixed
   redemption liability), `credit` (player prefunded balances, per Friend), `free`. Only the
   game's registered module may `reserve / release / settle / pay / collect`. Every collect
   carries the game's fixed split (bankroll, developer, operator, burn, rewards); burn calls
   `RF.burn`; rewards accrue to a ledger forwarded permissionlessly to the current activation
   manager. USDG has no burn or rewards leg. Only free stake is withdrawable, to the recorded
   funder. Treasury invariant: per currency `balance ≥ reserved + owed + credit + rewardsPending`
   summed over games.
3. **RandomnessCoordinator**. The only Dice requester. Holds platform ETH. Modules request a word
   bound to `(gameId, actionId)`; it pays the quoted fee if ≤ the cap and within the game's
   budget, stores the word on the authenticated callback, exposes `word(requestId)`, and
   implements reclaim-and-retry through Dice's `refundRequest` for a request that Dice shows as
   unrevealed after its delay. Players never pay ETH. A game binds to the coordinator at
   registration.
4. **GameItems** (ERC-1155), one collection per game, deployed by the registry. Classes declared
   at deployment with URI, optional cap and `Bound` transfer policy (transfers disabled except
   mint and burn; a `Free` policy exists only if a launch game needs it, and none does). Mint
   and burn only by the collection's current controller; the controller is set by the registry
   so a successor module instance can inherit inventory. Base URI per collection settable by the
   registry owner. Start from `GameERC1155.sol` in the production prototypes.
5. **FriendAccess** (library). The one rule for who may act for a Friend: current owner, its
   canonical wallet, or the custody executor for a Friend held by FriendCustody with a fresh
   `actionId`. Returns the wallet and generation and rejects generation 0 and wallets without
   code. Both v1 ChanceGame and PenaltyKingsPark implement this rule slightly differently today;
   this library ends that.
6. **Draw module**. A declarative chance engine serving Rare Breeds and Penalty Kings. A game
   declares actions; each action has an input (currency payment or burning N of an item class),
   a draw count, and a weighted outcome table (per generation when needed) whose rows mint an
   item class or pay a currency value. A one-row table settles without randomness (that is how a
   prepaid consumable is bought). Classes may carry a fixed redemption value (owed liability on
   mint) and a per-class reserve that minting locks (6 RF per egg, 0 per ball). Commit reserves
   the maximum payable value for the committed generation; settlement replaces it with the actual
   result. Supports the custody executor path and a `bytes32 context` per commit.
7. **Round module**. Rare Royale as described in 4.3, with the credit ledger in the Treasury and
   a per-game settler role in the registry.
8. Crash (Slingshot), ERC-20 and ERC-721 assets are later modules or implementations, each added
   by deployment and allowlisting without touching the core.

## 6. Open design questions the spec must settle

- Terms encoding: ABI-encoded structs per module stored in module storage keyed by gameId, hashed
  into the registry. Registration gas for Penalty Kings (7 ball classes × 6 generations × 7 rows
  plus pack tables) must be feasible, splitting registration across transactions if needed while
  keeping terms immutable once activated.
- Whether `reserved` accounting lives entirely in the Treasury or partly in modules; the invariant
  must be checkable from the Treasury alone.
- Round settlement checks: exact pot equality, payout recipients restricted to entrants' wallets,
  secret preimage check, word required, refund path, and what happens if a payout transfer
  reverts (RF transfers do not revert for ordinary recipients; wallets are contracts that accept
  ERC-20 balances without hooks).
- Whether randomness retry is permissionless (Dice's delay bounds griefing cost to one fee per
  delay per stuck request) or owner-only.
- Event design for the keeper and indexers: every committed action must be discoverable and
  settleable from events plus public state, as the Penalty Kings keeper does today.
- Contract size: the Draw module is the largest; keep it under 24,576 bytes without `via_ir`,
  splitting pure table math into a library if necessary.

## 7. Deliverables and build

Foundry project `platform-contracts/` with `src/`, `test/`, `script/`, `docs/`. Libraries are
the SDK's vendored subset at `contracts/lib` (OpenZeppelin v5: ERC20, ERC1155, SafeERC20,
ReentrancyGuard, Ownable, Math, SafeCast; forge-std). `Ownable2Step` is vendored at
`src/access/Ownable2Step.sol`. Imports use `lib/openzeppelin-contracts/contracts/...` and
`forge-std/...`.

```sh
forge build --root platform-contracts --sizes
forge test --root platform-contracts -vv
forge fmt --root platform-contracts --check
```

Tests use local doubles for RF (with the syncPreview side effect modeled only where relevant),
USDG (6 decimals), Generations, canonical wallets (`execute` by owner), FriendCustody
(`beneficiary`), Dice (fee, request, callback, refund after 6 blocks, request struct, status 3)
and ActivationManager (`fund`, `retired`). Required coverage: backing invariants under fuzzing
and stateful invariant tests; exact Rare Breeds and Penalty Kings tables; all Penalty Kings
generation returns; custody replay protection; Round settlement rules; coordinator budget, cap,
authentication, replay, status-3 refusal and retry; inventory succession; owner surface limits;
reentrancy. A `MainnetFork.t.sol` gated on `PLATFORM_FORK_RPC` may exercise the real RF,
Generations, wallet, custody and Dice request code on a local fork.

No deployment, broadcast or mainnet transaction is part of this work. Scripts simulate only.
