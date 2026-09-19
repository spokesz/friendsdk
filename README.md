# FriendSDK v1

An isolated kit for building small RF chance games. Developers can deploy their own v1 game contracts on Robinhood mainnet using existing RF and Generations assets, then develop against that deployment.

The fishing reference runs locally from `examples/fishing` as a clearly labeled preview. The production `rarefriends-web` app has no FriendSDK integration, SDK content, or game demo. Keep SDK development, contracts, assets, and builds in this repository. No game deployment is bundled.

## Prerequisites

- Node.js 22+ and npm.
- [Foundry](https://getfoundry.sh/introduction/installation/) (`forge` and `anvil` on your `PATH`) to build and test contracts. Solidity 0.8.36 and the required third-party Solidity sources are pinned by this repo.
- Your own **hardwired Generations NFT on Robinhood mainnet**, chain ID **4663**. Generation must be at least 1; activation and tier do not matter.
- The private key of the wallet that owns that NFT, entered only at the script's hidden terminal prompt.
- ETH in that wallet for deployment, transactions and Dice randomness fees. The script reads Dice's current fee before requesting randomness.
- Existing `$RAREFRIENDS` (RF): the default fishing deployment starts with **10 RF of prize stake** from your signing wallet. Keep another **1 RF per purchased bait** in your NFT's canonical wallet, or in your signing wallet for the play script to transfer there. Larger stakes are optional.

No new RF token, Generations NFT, NFT-wallet implementation or Dice oracle is deployed. The SDK does not use `$DICE` tokens.

## 1. Install, build and test

```sh
cd ~/friendsdk
npm ci
npm run build:contracts
npm run sync:contracts
npm test
npm run typecheck
npm run test:contracts
npm run verify:contracts
npm run check:games
```

`npm test` also builds the SDK and browser example. These checks use local test contracts; no mainnet transaction is sent. The optional fork check below reads existing mainnet contracts and executes locally, with simulated Dice delivery:

```sh
FRIENDSDK_FORK_RPC=https://rpc.mainnet.chain.robinhood.com \
  forge test --root contracts --match-contract MainnetForkTest -vv
```

## 2. Deploy your game to mainnet

```sh
npm run deploy:contracts
```

Enter your NFT ID, the RF prize stake, and your private key at the prompts. The script checks ownership, the canonical NFT wallet, RF and ETH balances, and the existing mainnet dependencies. Review the displayed terms and gas estimate, then type `DEPLOY` to send the deployment, exact RF approval and stake-funding transactions.

The command builds contracts and SDK bindings first. It defaults to `examples/fishing/game.json`; pass your game's JSON to deploy other immutable terms:

```sh
npm run deploy:contracts -- games/my-game/game.json
```

It prints and saves `contracts/deployments/4663-<game-address>.json` after confirmation. The manifest contains addresses, terms and transaction hashes; **no private key**. Set the shell variable below to the actual printed path:

```sh
FRIENDSDK_DEPLOYMENT='contracts/deployments/4663-0xYOUR_GAME_ADDRESS.json'
```

Keep that file to resume a partially completed deployment:

```sh
npm run deploy:contracts -- --resume "$FRIENDSDK_DEPLOYMENT"
```

If confirmation was interrupted before the game address was known, use the transaction-hash manifest path printed by the script instead. Resume observes recorded transactions before sending anything again.

## 3. Run a real play with your Generations NFT

```sh
npm run play:contracts -- "$FRIENDSDK_DEPLOYMENT"
```

The command uses the NFT ID recorded at deployment. To use another hardwired NFT you own, append its token ID:

```sh
npm run play:contracts -- "$FRIENDSDK_DEPLOYMENT" YOUR_TOKEN_ID
```

Enter the owner wallet's private key at the hidden prompt. Review the amounts, then type `PLAY`. The command tops up the canonical NFT wallet only if needed, buys one consumable if none is available, consumes it, pays Dice's quoted ETH fee, and waits for settlement. Every transaction uses real mainnet assets. You can then type `REDEEM` to sell the reward for RF paid back into your NFT wallet, or press Enter to keep it.

If Dice is still pending or you interrupted the process after a committed play, use its printed play ID to continue that same result:

```sh
npm run resolve:contracts -- "$FRIENDSDK_DEPLOYMENT" PLAY_ID
```

Resolution reuses the existing request; it does not buy another play or reroll. Oracle delivery depends on Dice's provider. Pending plays and kept rewards remain backed while waiting.

If the provider never reveals, Dice lets whoever made the request reclaim it after its own short delay of a few L1 blocks. The resolve command notices that state and offers a retry: one transaction reclaims the stuck request and sends a new one for the same play group. Only the Friend's owner can send it, and only through a typed `RETRY` confirmation. It costs Dice's current fee and returns the reclaimed one in the same transaction, so the ETH involved is the oracle fee moving, never a payout or an RF change. The play, its bait, its play IDs and its reserved backing do not change, and a result Dice has already delivered can never be requested again. There is no refund of bait or RF, no way to void a play, and no expiry. If Dice itself is paused or removed, no option here helps and the reserve stays locked. The retry is proven against Dice's deployed code on a local fork; no retry against a genuinely stuck request on mainnet has been observed yet, and this sentence stands until a developer reports one.

## 4. Run the local browser preview

This optional UI preview uses sample Friends and simulated balances. Your real NFT is used by the mainnet commands above.

```sh
python3 -m http.server 4178 --directory examples/fishing/dist
```

Open `http://localhost:4178` (Python 3 is needed only for this command). Read [AGENTS.md](AGENTS.md) and [API.md](API.md), and copy [the fishing example](examples/fishing/README.md) into `games/<name>` to start building.

The deployment creates only `ChanceGame` and its bound `Consumable`. Dice Protocol supplies randomness through its existing mainnet oracle. See [contract setup, resolution, and testing](contracts/README.md) for the complete flow. The browser fishing example stays a local preview; use the SDK host transport with the saved deployment to build a connected game.

## Game boundary

Every game uses the same **960 × 640** container, scaled to the available width. The SDK hosting boundary requires developer code to run in a sandboxed iframe; the standalone preview is a local host fixture. Menus, inventory, sound controls, Friend selection, NFT-wallet balance and action confirmations stay inside the container. Games cannot draw UI outside it.

For a future host, catalog metadata is limited to a thumbnail and title. Detail metadata adds “by dev,” About and linked Store items alongside the game container. Purchasing and redeeming happen inside the game. These are prototype requirements, not existing production pages.

The host owns Friend selection and the wallet connection. Games receive a limited action client for that selection; switching Friend or wallet cancels pending confirmations.

## V1 rules

- Players control a **hardwired Generations NFT**. No activation, tier, or weight requirement.
- RF only. Consumables, catches, and redemption proceeds belong to the Friend wallet and follow the NFT.
- One loop: **buy consumable → consume → await result → reveal → keep or redeem**. Game presentation never changes a paid result.
- **No redemption expiry.** Each kept reward retains its original RF value and full backing until sold.
- Stake is RF prize capital. The developer funds their own isolated deployment; there is no automated stake recommendation, paid submission, or fixed SDK minimum. Production publication and funding agreements are separate from developer testing.
- New purchases stop if free stake cannot cover the highest prize. Every purchased consumable reserves its maximum prize, so already purchased plays remain backed and usable.
- Defer new currencies, launchpads, markets, trading-fee projections, and custom developer contracts.

```text
free stake = game RF − unused/pending play reserves − kept reward liabilities

buy:      require free stake >= highest prize
          require free stake + purchase payment >= quantity × highest prize
          reserve quantity × highest prize atomically
settle:   replace one maximum reserve with the actual reward value
redeem:   burn the reward and pay its fixed RF value to the Friend wallet
withdraw: deploying developer can withdraw only free stake
```

For fishing, bait costs 1 RF and the highest prize is 10 RF. The first bait therefore needs at least 10 RF of free stake before payment. Its 10 RF reserve follows it through the cast. A kept 0.25 RF fish reserves 0.25 RF indefinitely; the remaining 9.75 RF becomes available again. See [the updated design](FISHING_GAME_DESIGN.md).

## What the SDK contains

| Part | Contents |
| --- | --- |
| Interface | Standard game frame, shared Friend picker, NFT-wallet and confirmation menus, HUD, item panels, keyboard/touch controls |
| World | Existing scene JSON, terrain, props, projection, collision and depth sorting |
| Movement and loading | Reusable directional/click movement, image/world loading and canonical Friend sprites |
| Sound and effects | Ten cues, mute, reward reveals, skip and reduced motion |
| Game rules | Validated outcome definitions, exact RF calculations, local preview and reservation accounting |
| Host transport | Isolated frame bridge; owner-signed actions through the selected NFT wallet; pinned deployment, exact approval, simulation and receipt checks |
| Developer kit | Typed package, runnable fishing reference, AI rules, PR template and deterministic build/configuration checks |

The contract implementation is [ChanceGame](contracts/src/ChanceGame.sol): configurable consumable and weighted outcomes, immutable terms, permanent rewards, full backing, and deployer-only surplus withdrawals. Each committed play group gets one Dice request. [Contract notes](contracts/README.md) describe deployment and operation.

## One source of truth

| Repo | Responsibility |
| --- | --- |
| `friendsdk/src`, `examples`, `games` | SDK source, examples, game definitions and submission checks |
| `friendsdk/contracts` | Standalone game Solidity, tests, vendored dependencies and local deployment records |
| `friendsdk/scripts/contracts` | Interactive deployment and Dice resolution tooling |

Generated modules, local example builds, and contract bindings are outputs. Edit their source. Bindings record the compiler/source hashes and are updated with `npm run sync:contracts` after `npm run build:contracts`. No sibling contract or web repository is required.

## Submit and launch

1. PR includes source/assets, run instructions, SDK version and `game.json` with exact RF cost, outcome probabilities and rewards.
2. CI builds the SDK/games and validates configuration. The reviewing AI follows `AGENTS.md`; Rare Friends approves. CI is not an automatic AI review or deployment service.
3. Production publication requires separate Rare Friends review and agreement. A developer's test deployment does not publish a game on the production web app.

Before public paid play: review the external Dice provider and its delivery assumptions, connect the deployed game through the trusted NFT-wallet transport, recover pending plays, and verify deployed terms and funding. The local preview, tests and a successful deployment do not establish unattended operation.
