# Rare Friends platform contracts

Platform-owned, modular game contracts for games published by third-party developers on
rarefriends.com. Developers never write Solidity: a game is a registry record of an immutable
mechanic module plus immutable terms compiled from the developer's manifest. Rare Friends owns,
deploys, funds and operates the contracts, manages the game assets, pays Dice randomness, and
adds new mechanics by deploying one module without redeploying or re-funding what already exists.

Requirements live in [docs/BRIEF.md](docs/BRIEF.md); the implementation contract is
[docs/SPEC.md](docs/SPEC.md), including the complete owner surface (section 10.1), what is
deliberately not built (10.2) and every deviation from the deployed reference contracts that the
team must accept or reject explicitly (10.3). Apply the SDK's `contracts/COMMANDMENTS.md` as house
style when changing anything here.

**Status: local implementation, not deployed.** No contract has been broadcast and no mainnet
transaction is part of this work. Verified locally: 285 tests across 19 suites (unit, integration
flows, succession, owner surface, reentrancy, sizes and a stateful invariant suite) pass with zero
compiler or lint warnings, and the gated fork test passes against live Robinhood mainnet,
exercising the real RF, Generations, canonical wallet, FriendCustody and Dice code including Dice's
request struct and reclaim path. Runtime sizes: DrawModule 17,361 B, GameRegistry 13,480 B,
RoundModule 12,070 B, Treasury 9,423 B, GameItems 6,113 B, RandomnessCoordinator 5,552 B.

## Layout

| Path | Responsibility |
| --- | --- |
| `src/GameRegistry.sol` | The only owned contract (`Ownable2Step`, renounce disabled): module allowlist by lineage, game records, per-game module bindings (Active / Draining), deploys one `GameItems` per game, custody executor key, global custody replay table. |
| `src/Treasury.sol` | Custody of RF and USDG. Per-game ledgers `{free, reserved, owed, credit}`, per-currency totals, accrued fee ledger, RF rewards ledger forwarded permissionlessly to the current ActivationManager. One private `_move` writes every ledger. |
| `src/RandomnessCoordinator.sol` | The only Dice requester. Platform ETH, fee cap, per-game budgets, one request per (module, game, action), store-only callback, permissionless reclaim-and-retry through Dice's `refundRequest`. |
| `src/GameItems.sol` | Friend-bound ERC-1155 per game. Mint and burn by any module the registry reports as bound, so succession needs no write here. |
| `src/DrawModule.sol` | Declarative weighted-draw engine serving Rare Breeds and Penalty Kings: terms per game, commit with maximum-value reservation, inline settlement for one-row tables, randomness-bound settlement, redemption, custody path. |
| `src/RoundModule.sol` | Rare Royale: rounds with a settler secret hash, entries reserved whole, one word per round, settler payout list equal to the pot, refund and abandonment paths, prefunded Friend credit. |
| `src/libraries/` | `FriendAccess` (the one rule for who may act for a Friend), `Rolls` (bias-free rolls, the deployed Penalty Kings sampler), `DrawTables` (Draw term structs and table validation). |
| `src/interfaces/` | External dependencies typed (RF, Generations, ActivationManager, Dice) and the hub seams. |
| `script/LaunchTerms.sol` | The three launch games' terms exactly as SPEC section 3 states them; shared by tests and scripts so every consumer registers the same terms hash. |
| `script/Deploy.s.sol`, `script/RegisterLaunchGames.s.sol` | Simulation-only Foundry scripts against the verified mainnet addresses in `script/Mainnet.sol`. |
| `test/` | Unit suites per contract, the shared `Fixture.sol`, integration flows, succession, owner surface, sizes, reentrancy, a stateful invariant suite and a fork test gated on `PLATFORM_FORK_RPC`. Doubles for every external contract live in `test/doubles/`. |

## Build and test

Uses the SDK's vendored OpenZeppelin v5 subset and forge-std at `../contracts/lib`.

```sh
forge build --root platform-contracts --sizes
forge test --root platform-contracts -vv
forge fmt --root platform-contracts --check
```

Optional local mainnet fork (read-only, never broadcasts):

```sh
PLATFORM_FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --root platform-contracts --match-path test/MainnetFork.t.sol
```

Simulate deployment and registration (no `--broadcast`):

```sh
PLATFORM_OWNER=<multisig> forge script script/Deploy.s.sol --root platform-contracts --rpc-url https://rpc.mainnet.chain.robinhood.com
```

## How a game works

1. The owner allowlists a module once (`allowModule`), then `createGame` records the module,
   currency, funder, fee recipients, settler (Round games only) and deploys the game's item
   collection. The game is a Draft.
2. The owner writes the game's terms into the module (`defineClasses` / `defineAction`, or
   `defineTerms`), then `activateGame` has the module validate and freeze them and records their
   hash. Terms never change afterwards; a revised game is a new instance.
3. Players act through the module: a Friend's owner or canonical wallet pays, items and prizes
   always land in the Friend's canonical wallet. Every chance outcome is settled permissionlessly
   from the coordinator's Dice word with domain-separated, rejection-sampled rolls.
4. The Treasury holds all money and enforces `balance ≥ reserved + owed + credit + fees +
   rewardsPending` per currency with no admin bypass; the owner may withdraw free stake only, to
   the recorded funder.
5. `retireGame` stops purchases, deposits, round opens and entries only. `succeedModule` points a
   game at a new module of the same lineage holding the identical terms hash; the predecessor keeps
   settling, redeeming and refunding its own commits and inventory needs no migration. A Round game
   is succeeded only between rounds (`ModuleBusy` while any round is live).

## Launch games

| Game | Module | Currency | Terms |
| --- | --- | --- | --- |
| Rare Breeds | Draw | RF | 1 RF egg reserving 6 RF; tiers Common 60% / 0.5 RF, Spotted 25% / 1 RF, Mutant 12.5% / 1.5 RF, Prismatic 2.5% / 6 RF; redemption forever |
| Penalty Kings | Draw | USDG | 2 USDG pack of two balls (rarity weights 3150/2700/2000/1100/700/250/100); per-ball, per-generation kick tables paying 2 to 64 USDG; gross edge `400 + 100·gen` bps split 75/25 developer/operator, accrued and paid permissionlessly |
| Rare Royale | Round | RF | 1 RF entry, 50 seats, 5 minimum; 80% pot paid by the settler's list, 10% burn, 10% rewards at settlement; thirteen spend kinds at 50% burn / 50% rewards from prefunded credit |

`test/LaunchTerms.t.sol` proves the generated Penalty Kings tables equal the deployed
`PenaltyKingsPark.payoutOdds` for all 42 ball and generation pairs with exact 90%–95% returns.

## Operations

- **Keeper**: index `Committed` (`requestId != 0`) and `RoundClosed`, join `Fulfilled`, call
  `settle` / wait for the settler, confirm `Settled` / `RoundSettled`; retry a request Dice shows
  as status 1 after six L1 blocks with `coordinator.retry`; forward rewards and pay fees at any
  cadence.
- **Settler** (Rare Royale): commits `keccak256(abi.encode(secret))` at `openRound`, closes
  entries, runs the deterministic simulation from `(word, secret)` and submits the payout list.
  Anyone can refund a round left unfinished for one day.
- **Custody executor**: fulfils paid orders for Friends held by FriendCustody through the Draw
  module's custody path with a one-time action id consumed in the registry.
- **Owner** (multisig): the enumerated surface in SPEC 10.1 and nothing else.
