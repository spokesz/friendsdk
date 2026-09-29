# Standalone FriendSDK v0.1.4 contracts

The package supplies immutable RF chance-game contracts and deployment tools.
RF, Generations, canonical NFT wallets and Dice are existing mainnet dependencies
accessed through interfaces.

Each supplied game contract supports one RF-priced consumable and one outcome
table. This is the current reference implementation, not a requirement that
every submission use that economy. Durable items, cosmetics, perks, upgrades and
additional currencies are welcome when backed by or integrated with
$RAREFRIENDS (RF); this package does not implement those additional actions.

## Two new contracts

| Contract | Responsibility |
| --- | --- |
| `ChanceGame` | Immutable RF price and outcome table, canonical-wallet purchases, reserved backing, permanent ERC-1155 rewards, Dice requests and settlement |
| `Consumable` | Whole prepaid plays held in the NFT wallet; only the game can mint or consume them; transfers are disabled |

Deploying `ChanceGame` creates its consumable in the same transaction. Its `team`
getter identifies the deploying developer, who alone can withdraw **free** RF
stake. Contract deployment and game publication are separate operations.

These reference contracts do not implement launchpads, submission payments,
additional currencies, tiers or activation gates. They have no proxies, upgrade
hooks, pause controls or configurable administrators. The existing RF token,
Generations collection, NFT-wallet implementation and Dice oracle are referenced
by interfaces only. Test doubles live exclusively in `test/`.

## Existing Robinhood mainnet dependencies

| Dependency | Address / value |
| --- | --- |
| Chain | Robinhood mainnet, `4663` |
| Public RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Generations | `0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D` |
| RF | `0x0779369854d3EcdEA927206718FFD7730C67B71f` |
| Dice Entropy | `0xd8a0680e7699526b57140ed4eafdcc7219dc0a0c` |
| Dice provider | `0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6` |

Generations' `token()` must match RF. Deployment requires ETH for gas and the
selected RF prize stake in the deploying account. The deployment script prompts
for the stake and that account's private key.

For real play, the selected NFT must have generation ≥ 1 and be owned by the
signing account. Its wallet address comes from `tokenBoundAccount(tokenId)`; the
initial selection verifies ownership and hardwired eligibility and resolves that
canonical wallet for the session. Contracts enforce authorization and eligibility
when actions execute. No activation or tier is required.

The RF and Generations addresses are the existing project deployment and have been checked through public RPC. Dice's addresses and interface are published in its [mainnet deployment record](https://github.com/diceprotocol/dice-entropy/blob/main/docs/mainnet-deployment.md) and [integration guide](https://diceprotocol.world/). The CLI pins these addresses and checks chain and deployed code before deployment.

## Deploy and run a game

Use Node.js 22+, npm and Foundry with `forge` on your `PATH`. The deploying account
needs ETH for gas and RF for the chosen prize stake. Deployment does not require
an NFT ID. From the SDK root:

```sh
npm ci
npm run deploy:contracts -- examples/fishing/game.json
```

Enter the RF stake and deploying account's private key at the terminal prompts.
The private-key prompt is hidden. Review the immutable game terms and gas
estimate, then type `DEPLOY` to submit the deployment, exact RF approval and
stake-funding transactions. The command builds contracts and SDK bindings and
prints the saved public manifest path. Substitute your own `game.json` to deploy
different terms. Keep private keys out of source, shell arguments and manifests.

The manifest is saved at `contracts/deployments/4663-<game-address>.json` and
contains public addresses, game terms and transaction hashes. Replace
`contracts/deployments/YOUR_DEPLOYMENT.json` below with the actual printed path.
Run these commands in your Linux or Ubuntu/WSL terminal:

```sh
npm run dev:game -- examples/fishing --deployment contracts/deployments/YOUR_DEPLOYMENT.json --outdir examples/fishing/.friendsdk/my-live
```

To build static files for that deployment:

```sh
node scripts/dev-game.mjs build examples/fishing --deployment contracts/deployments/YOUR_DEPLOYMENT.json --outdir examples/fishing/.friendsdk/my-live
```

Host all files in `examples/fishing/.friendsdk/my-live/` as the static site root,
following the [serving requirements](../HOST_INTEGRATION.md#serving-and-sandbox).
Only public deployment fields enter the browser build. Omit `--deployment` for
simulated actions.

### Resume a deployment

Keep the saved manifest if deployment, approval or funding is interrupted:

```sh
npm run deploy:contracts -- --resume contracts/deployments/YOUR_DEPLOYMENT.json
```

If confirmation was interrupted before the game address was known, use the
transaction-hash manifest path printed by the script. Resume observes recorded
transactions before sending anything again.

### Play from the terminal

```sh
npm run play:contracts -- contracts/deployments/YOUR_DEPLOYMENT.json
```

The command prompts for an owned hardwired Generations NFT's token ID. You can
also pass the ID directly:

```sh
npm run play:contracts -- contracts/deployments/YOUR_DEPLOYMENT.json YOUR_TOKEN_ID
```

Enter the NFT owner's private key at the hidden prompt. Initial selection checks
ownership and eligibility and resolves the canonical wallet. Contracts enforce
authorization when actions execute. Review the amounts, then type `PLAY`. The
command tops up the canonical NFT wallet if needed, buys one consumable if none
is available, consumes it, pays the quoted Dice fee and waits for settlement.
These are real mainnet transactions. Type `REDEEM` to sell a settled reward for RF
paid to the Friend wallet, or press Enter to keep it.

For a committed play awaiting delivery, use its existing play ID with the
[oracle resolver](../docs/oracle/README.md#resolve-a-committed-play-from-the-terminal).
It resumes that result without another purchase.

## Paid loop

1. The developer approves exactly the selected RF stake and funds the game from their signing account.
2. The NFT wallet approves exactly the purchase cost and calls `buy(friendId, quantity)`. Direct owner-funded purchases are rejected.
3. `play(friendId, quantity)` burns prepaid consumables and commits play IDs. The first play ID is the group's `batchId`. It remains callable even when new purchases are unavailable.
4. A sponsor pays the quoted Dice fee for the play group. The authenticated oracle callback records one random word.
5. Anyone can settle a fulfilled play. Its reward is minted into the canonical NFT wallet.
6. The NFT's current owner or wallet can `redeem(friendId, outcomeId, quantity)`. The reward burns and its fixed RF value returns to that same NFT wallet.

No oracle token, subscription setup or separate keeper deployment is needed.
`npm run play:contracts -- <manifest> [friendId]` prompts for an NFT ID when the
argument is omitted, verifies the initial selection and pays for its committed play's RNG request.
`npm run resolve:contracts` can resume a pending play. Running only the browser
preview does not request oracle delivery. See [oracle operations and recovery](../docs/oracle/README.md)
for the resolver workflow, implemented limits and proposed retry work.

A Dice RNG request costs **0.000025 ETH**, excluding transaction gas. The browser
runtime rejects a quoted fee above that amount. Pending plays reuse their
existing request. Rare Friends plans to subsidize RNG costs for **all developers**
to improve the user experience and reduce costs. The demo does not implement this
subsidy; it demonstrates wallet-paid RNG.

## Backing and fishing terms

All RF amounts use 18-decimal base-unit integers. A new purchase requires free stake ≥ the highest prize before payment, and enough free stake plus payment to reserve every new consumable's maximum prize. Consuming a unit retains its reserve; settlement replaces it with the actual reward value. Redemption has no expiry. The developer cannot withdraw reserves for unused consumables, pending plays or kept rewards.

The default [fishing definition](../examples/fishing/game.json) charges 1 RF per bait, has a 10 RF maximum prize and a 0.90 RF expected reward. The exact outcome weights and redemption prices are in that JSON and [FISHING_GAME_DESIGN.md](../FISHING_GAME_DESIGN.md). Each purchased bait reserves 10 RF. Buying two bait therefore needs 18 RF of free stake before the 2 RF payment. Reward terms never change after deployment.

The stake is developer capital in the game. Player RF is separately held in the canonical NFT wallet. The play command can explicitly transfer a purchase shortfall from the owner's account to the NFT wallet before buying; the purchase itself always debits the NFT wallet.

## SDK integration

Pass the saved manifest to the SDK host transport as `deployment`; it supplies `chainId`, `game`, `rf` and `generations`. `scripts/contracts/play.mjs` is a working terminal example of the SDK's real transaction flow. Keep private keys and deployment tools outside browser game code.

```js
import { createChanceGameTransport } from '@rarefriends/friendsdk/host';

const game = createChanceGameTransport({
  deployment: manifest,
  account: ownerAddress,
  publicClient,
  walletClient,
});
await game.approvePurchase(friendId, 1n);
await game.buy(friendId, 1n);
const committed = await game.play(friendId, 1n);
// Sponsor Dice and settle with resolve:contracts using committed.plays[0].playId.
```

After Solidity changes, run `npm run build:contracts`, `npm run sync:contracts`, and `npm run build`. `npm run verify:contracts` checks that the generated ABI and compiler/source hashes match the local Forge artifact. Each new set of terms needs a new deployment; existing obligations remain with the old game.

## Tests and limits

`npm run test:contracts` checks backing, NFT-wallet payment, ownership transfers, permanent redemption, callbacks, request replay, and exact fishing odds, including fuzzed multi-player backing. The optional `MainnetForkTest` executes the actual RF, NFT wallet and Dice request code on a **local** mainnet fork. Oracle delivery is simulated because the live provider does not observe private fork transactions.

Dice uses commit-and-reveal and an external provider. That provider can delay or withhold delivery. Pending plays retain their RF backing, but this game does not expose Dice fee refunds, cancellation, rerolls or provider replacement. The deployment script does not prove live delivery or independently audit the external oracle.

The third-party OpenZeppelin and forge-std dependency subset, licenses and exact source hashes are included in `lib/`. The compiler is Solidity 0.8.36. Deployment manifests are ignored by Git and never contain a private key.
