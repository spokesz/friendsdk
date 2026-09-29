# Fishing example · FriendSDK v0.1.4

Fishing demonstrates a playable world, keyboard/touch movement, vendors,
collection and reward reveals. Its world interactions, menus and project layout
are reference choices; other genres, interfaces and project setups are welcome.

The SDK runtime provides the 960 × 640 container, wallet connection, owned Friend
selection, fresh hardwired-NFT eligibility checks, sandbox and confirmations.
Every playable prototype requires the connected account to own an eligible
Generations NFT, including simulated previews. See the
[prototype requirements](../../README.md#required-prototype-identity-and-interface).

Keep purchases, rewards and redemption simulated by default. Read-only ownership
checks remain required. On-chain implementation is a later phase with the Rare
Friends team after publishing requirements are met, unless explicitly requested.
Transactions, contract deployment and official Rare Friends production publication
require their applicable authorization. You may host a public simulated preview
on GitHub Pages without separate Rare Friends approval; see the
[hosting instructions](../../README.md#build-and-share-a-preview).

## Run the example

From the SDK root, with Node.js 22+:

```sh
npm ci
npm run dev:fishing
```

Use the displayed local URL. Connect a wallet, select an owned eligible Friend,
walk to the bait vendor to buy bait, then walk to the lake to cast. Reel in and
keep or sell the catch. Collection, reveals, odds and settings stay in the frame.
The runtime labels the simulated balances and outcomes.

`index.tsx` exports the fishing game component. `world.tsx` uses shared projection,
collision, movement, assets and canonical Friend pixels. Arrows/WASD and click/tap
move the Friend. Sound, reduced motion, loading and error states are supported.
`game.json` defines the example's exact economy; `art.json` contains its eight
collectible bitmaps. `sample-sprites.ts` records the source of canonical artwork
samples. Artwork does not verify ownership.

The fishing scenery, assets, palette, projection and camera are choices for this
example. Creators may use their own world assets, character art, visual style,
renderer and menus; `GameWorld` and the shipped world utilities are optional.
Choose accessible controls suited to the genre. Custom artwork does not replace
the runtime's NFT ownership checks or change the supported action client.

The [embedded example](../embedded/README.md) demonstrates the same runtime with
a prebuilt sandbox child. [The runtime guide](../../HOST_INTEGRATION.md) documents
the generic component interface and supported capabilities.

## Live play

```sh
npm run dev:fishing:live
```

Open the displayed URL. To choose a listening interface and port, append
`-- --host 0.0.0.0 --port 4187`. `deployment.json` selects
Robinhood mainnet game `0x671a5080103cd44628d6725f8187aa2d2610f8b3`, deployed at
block **67238313**. Live RF, bait, catches and available prize stake come from
contract reads.

Connect the NFT owner's wallet on chain **4663**. Use **Transfer RF to Friend**
in the wallet menu to fund its canonical wallet, then buy bait at the vendor.
Buying approves exactly the purchase cost before the purchase. Confirm each real
transaction in your wallet and keep ETH available for gas. Resolving a cast may
pay Dice's RNG fee of **0.000025 ETH**, excluding gas. The runtime caps its quoted
fee at that amount and stops the request if the quote is higher.

Rare Friends plans to subsidize RNG costs for **all developers** to improve the
user experience and reduce costs. This demo does not implement that subsidy;
it demonstrates wallet-paid RNG requests.

Return to the lake and choose **Resume cast** for a pending play. This checks and
settles its existing result without consuming more bait. A pending oracle result
has no catch reveal. The runtime recovers pending plays after reload and refreshes
state when a later step fails after a cast has committed. Rewards appear only
after verified settlement; redemption returns RF to the same Friend wallet.

Use `npm run dev:fishing` for the simulated preview.

## Build and host

| Mode | Build | Static output |
| --- | --- | --- |
| Simulated | `npm run build:fishing` | `examples/fishing/.friendsdk/preview/` |
| Live | `npm run build:fishing:live` | `examples/fishing/.friendsdk/live/` |

Use the chosen output directory as the static site root. Include every generated
HTML, JavaScript, CSS and asset file and retain their relative paths. Upload the
folder to an HTTPS static host; no backend or host-side build is needed. Follow the
[static serving requirements](../../HOST_INTEGRATION.md#serving-and-sandbox).

To use your own contract, follow the [deployment workflow](../../README.md#deploy-your-game-to-mainnet),
then use the printed manifest:

```sh
npm run dev:game -- examples/fishing --deployment ./contracts/deployments/YOUR_DEPLOYMENT.json --outdir examples/fishing/.friendsdk/my-live
node scripts/dev-game.mjs build examples/fishing --deployment ./contracts/deployments/YOUR_DEPLOYMENT.json --outdir ./examples/fishing/.friendsdk/my-live
```

Host `examples/fishing/.friendsdk/my-live/` for that deployment. Only public
deployment fields enter the browser build. Omit `--deployment` for simulated
actions.

## Example economy

Each preview ledger starts with **20 RF** and **100 RF** of simulated prize stake.
Ledgers belong to the selected Friend and remain separate during a runtime
session. Unmounting the runtime clears its preview state. All amounts use bigint
RF base units.

One bait costs **1 RF**, creates exactly one cast and reserves **10 RF** immediately.
New purchases stop if free stake cannot cover the highest prize and the full
purchase. Purchased bait remains playable. Kept fish retain their backed RF value
until sold, with no expiry. Weights total **10,000 basis points**; expected reward
is **0.90 RF**. See the [catch table and consumable rules](../../FISHING_GAME_DESIGN.md#catch-economy).

Each cast settles once before its reveal. Reeling does not change the outcome.
This reference does not implement cosmetics, durable items, perks, upgrades,
additional currencies, trading or creator fees. Durable items, cosmetics, perks,
upgrades and additional currencies are welcome when backed by or integrated with
$RAREFRIENDS (RF). The supplied runtime and contracts still expose one RF-priced
consumable and outcome table, so document any capabilities your idea needs.

## Verify

```sh
npm test
npm run typecheck
npm run check:games
npm run check:browser
```

The browser checks exercise the game at desktop and phone sizes and verify the
runtime lifecycle. `npm run check:runtime` runs the generic runtime check alone.
`npm run check:live` checks live-mode controls and pending recovery with mocked transactions.
Mock accounts and sample Friends are automated test data only; playable
prototypes use the runtime's real wallet and fresh ownership checks.
