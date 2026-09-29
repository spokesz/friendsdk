# FriendSDK API

SDK **v0.1.4** exports browser ESM and TypeScript declarations. Import modules from
`@rarefriends/friendsdk/<module>`. Build with Node.js 22+ using `npm ci` and
`npm run build`.

## Game component and runtime

For the CLI workflow, a game directory contains `index.tsx`, `game.json` and its
assets. Default-export a React component accepting `GameComponentProps` from
`@rarefriends/friendsdk/runtime`:

```ts
export type GameComponentProps = Readonly<{
  friendId: bigint;
  client: GameClient;
  paused: boolean;
}>;
```

`friendId` is the selected, freshly verified Generations NFT. `client` exposes
only supported game actions. `client.mode` and `GameSnapshot.mode` are `"preview"`
or `"chain"`; use them to label balances and outcomes. Pause gameplay interactions
while `paused` is true. Choose controls and UI for your genre and target devices.
The walkable world and menus in the starter are reference designs.

Run `npm run dev:game -- examples/starter` in the SDK or
`npx friendsdk dev ./games/my-game` in a project with the
[package archive installed](README.md#install-in-an-existing-project). The runner
builds the component, serves its assets and supplies the runtime and child
handshake. See [the runtime guide](HOST_INTEGRATION.md).

`GameHost({ definition, frameUrl })` provides wallet discovery/connection, owned
Friend selection, fresh eligibility verification, `GameFrame`, a simulated ledger,
in-frame confirmations and the sandboxed child. `definition` is a
`ChanceGameDefinition`; `frameUrl` points to the built child document. Optional
`deployment: LiveGameDeployment` enables live contract actions; omit it for preview.
Optional `walletProvider` reuses a browser wallet provider; optional `publicClient`
overrides the default read client and implements `OwnedFriendsClient`.

`ConnectedGameHost({ definition, frameUrl, selectedFriend, account, chainId,
publicClient })` uses supplied wallet and selection context. `selectedFriend` is
`GameFriend | null`, `account` is the connected address or null, `chainId` is the
connected chain or null, and `publicClient` implements `GenerationIdentityClient`
or is null. Both runtime components enforce the same fresh ownership gate.
Increment optional `revision` when the supplied connection invalidates its
identity without changing those values. Keep the definition object stable for a
session; replacing it resets the simulated ledgers. For live mode also supply
`deployment`, a configured `walletClient` and a public client supporting
`LiveGamePublicClient`. Use `assertActive` to reject invalidated connections
immediately before a wallet prompt.

For a manually built child, `GameSession` handles the bridge and renders the game
with its selected identity, client and pause state:

```tsx
import { GameSession } from "@rarefriends/friendsdk/runtime";
import "@rarefriends/friendsdk/runtime.css";

<GameSession definition={definition}>
  {props => <Game {...props} />}
</GameSession>
```

The runner supplies this session automatically. An existing project can keep its
own file structure, renderer and build tools: use a thin React adapter inside
`GameSession` to pass these props to the existing game and stop its input while
paused. Build the child as a separate document, point the trusted `GameHost` or
`ConnectedGameHost` at it, and preserve the sandbox CSP and bridge lifecycle.
The game renderer itself need not use React. Wallet providers, ownership reads
and transaction clients stay outside the game sandbox.
Initialize with `client.read()` to load the session snapshot and let the runtime
finish its loading state, even when your game does not use economy actions.

The current runtime takes a `ChanceGameDefinition` even for games that do not
use its economy actions. The schema requires a positive price, outcome weights
totaling 10,000 basis points and at least one positive prize. Do not present
unused reference terms as mechanics your game implements.

The default **960 × 640** frame and SDK menus are reference presentation. The
host stylesheet supports `--rf-game-max-width` (default `960px`) and
`--rf-game-aspect-ratio` (default `3 / 2`). Set them on the trusted wrapper around
the runtime, or in the CLI game's optional `host.css`; child styles cannot resize
the host. Customize game menus as needed while keeping trusted wallet and action
confirmations in the runtime. See [layout examples](HOST_INTEGRATION.md#react-runtime).

## Modules

| Module | Exports and use |
| --- | --- |
| `runtime` | `GameHost`, `ConnectedGameHost`, `GameSession`, `GameComponentProps`, `createLiveGameClient`, `LiveGameDeployment`, `LIVE_GAME_MAX_ORACLE_FEE`. Preview/live runtime and child session. |
| `world-view` | Optional `GameWorld` utility with canonical Friend sprites and keyboard/touch movement. Import `world-view.css` when using it. |
| `world` | Optional world utilities: `WORLD_PRESETS`, `getWorldPreset`, `validateWorld`, `renderWorld`, `renderWorldLayers`, `renderProp`, `project`, `unproject`, `isWorldWalkable`. Geometry, props, collision and depth sorting. |
| `navigation` | `createWorldNavigator(world, radius?, spacing?)`: collision-checked `route(from, to)` and `segmentClear(from, to)`. |
| `movement` | `createWorldMovement(world, spawn, { speed?, radius? })`: `setKey`, `moveTo`, `update`, `stop`, `reset`, `state`. |
| `assets` | `loadImage(url, signal?)`, `loadSvg(svg, signal?)`, `loadWorldAssets(world, renderOptions?, signal?)`. Terrain and ordered object images/depths. |
| `sprites` | `createFriendReader()`, `createGenerationSpriteReader(publicClient, manifest?)`, `spriteFrame`. Canonical artwork loading and frame selection. |
| `identity` | `readGenerationEligibility(publicClient, tokenId, player?, deployment?)`, `GenerationIdentityClient`. Fresh owner/generation checks. |
| `owned` | `readOwnedFriends(client, account, options?)`. Account-filtered Generations discovery for advanced runtime integrations. |
| `wallet` | `createFriendWalletSession(options?)`, `createFriendPublicClient(options?)`. Browser wallet lifecycle and public read client for advanced integrations. |
| `sounds` | `createFriendSoundKit()`: `unlock`, `play`, `setMuted`, `setVolume`, `stop`, `dispose`. Ten cues; `renderFriendSound` returns PCM. |
| `items` | `GameItem`, `GameReward`, `GameShopOffer`, `GameItemQuantities`, `formatGameItemQuantity`. Item types and quantity formatting. |
| `ui` | React 19 `ExperiencePanel`, `GameHud`, `ActivityPrompt`, `ItemPicker`, `ItemArt`, `Keycap`, `formatGameAmount`. Caller supplies state and callbacks. |
| `reveal` | `RewardReveal`, `REWARD_REVEAL_TIMING`. Present an existing result with skip/reduced-motion support. |
| `game` | `GameClient`, `PreviewGameClient`, `GameSnapshot`, `parseChanceGame`, `defineChanceGame`, `createGamePreview`, `maximumPrize`, `expectedReward`, `outcomeForRoll`, `RF`. Definitions, exact RF calculations and shared action types. |
| `frame` | `GAME_VIEWPORT` (960 × 640 reference size), `GameFrame`, `GameMenu`. In-frame identity, wallet and confirmation UI. |
| `bridge` | `bindGameFrame`, `createFrameGameClient`. Fixed actions over a private transferred `MessagePort`. |
| `host` | `createChanceGameTransport`, `ChanceTransactionError`. Optional fixed-contract transport for explicitly scoped on-chain work. |
| `examples/fishing` | `FishingGame`, a complete game component. `FishingPreview` is an internal sample fixture. |
| `examples/embedded` | `EmbeddedFishingPreview`, a fishing configuration of the generic runtime with supplied identity context. |

Import styles for the components you render; the development runner handles its
runtime styles:

```ts
import "@rarefriends/friendsdk/frame.css";
import "@rarefriends/friendsdk/runtime.css";
import "@rarefriends/friendsdk/world-view.css";
import "@rarefriends/friendsdk/ui.css";
import "@rarefriends/friendsdk/reveal.css";
```

## Node tooling

These supported exports run in Node.js 22+, outside the game sandbox:

| Module | API |
| --- | --- |
| `@rarefriends/friendsdk/build` | `buildGame(gameDirectory, { outdir?, watch?, deployment? })`, `readGameDeployment(input)` |
| `@rarefriends/friendsdk/serve` | `createGameServer(outdir)` |
| `@rarefriends/friendsdk/testing` | `testGame(gameDirectory, options?)` |

`buildGame` returns `{ outdir, close }`. The default output is the game's
`.friendsdk/` directory; `watch: true` rebuilds changed sources until `close()`.
`deployment` is an optional public deployment object; omit it for simulated play.
`createGameServer` returns a Node HTTP server serving only generated game files.
For example:

```js
import { buildGame } from "@rarefriends/friendsdk/build";
import { createGameServer } from "@rarefriends/friendsdk/serve";

const build = await buildGame("./games/my-game");
const server = createGameServer(build.outdir);
server.listen(4173, "127.0.0.1");
// At shutdown, close the server and await build.close().
```

The CLI exposes the same install → init → dev → build workflow, plus
`friendsdk check <game-directory>` for game validation and
`friendsdk test <game-directory>` for an automated browser smoke check.
Run `friendsdk --help` for options and `friendsdk --version` for the package version.

CLI builds load optional `host.css` into the trusted runtime document; styles
imported by `index.tsx` remain in the child. The checker requires `README.md` and
accepts game sources inside the checked directory, public SDK sources/assets and
dependencies. It rejects the host transaction transport and unrelated outside
sources. These are CLI conventions; custom builds can use existing entry points
and their own checks while retaining the runtime's identity and sandbox boundary.

### Automated game tests

Install `playwright` as a development dependency and install its Chromium browser
(`npx playwright install chromium`). `testGame` builds into a temporary directory,
launches headless Chromium and runs the ordinary runtime with a mock wallet,
mock Robinhood RPC responses and sample canonical sprites. It closes its browser
and server after the check. Mocks are limited to automated tests; normal previews
and builds retain the real ownership gate.

Options include `width`, `height`, `timeout`, a `screenshot` file path and an
async `check` callback. The callback receives `{ page, game, friendId, account,
friendWallet }`; `game` is a Playwright `FrameLocator` for the sandbox and `page`
is the runtime's page. Use a focused interaction check for your game's controls.
For a game copied from the starter:

```js
import { testGame } from "@rarefriends/friendsdk/testing";

await testGame("./games/my-game", {
  screenshot: "./artifacts/game.png",
  check: async ({ game }) => {
    await game.getByRole("button", { name: "Settings", exact: true }).click();
    await game.getByRole("button", { name: "Sound off", exact: true }).click();
  },
});
```

The smoke check detects browser errors and runtime startup failures. Game-specific
assertions remain your callback's responsibility; mock tests do not verify real
RPC availability or ownership. Check the real wallet flow before delivering play.

## World and artwork

Choose the game's setting, assets, visual style, palette, camera and rendering
approach. `GameWorld`, bundled world assets, presets and their illustration style
are optional utilities and example choices. Custom worlds use the same runtime,
sandbox and fixed action client; SDK game menus are available as references.

The optional renderer's 576 × 384 plane is not a platform bound. The default
960 × 640 frame is a customizable viewport; custom cameras and worlds of any
size are allowed. See `examples/scrolling-world` for a larger map with a following camera.

The SDK's low-level movement utility does not attach events. When using it,
forward keyboard/pointer input, call `update(deltaMs)` in the animation loop,
and `stop()` on blur, pause or hidden tabs.
Speeds are screen pixels per second; `state.position` is a world point. Convert
pointer coordinates through the viewport scale/crop, then `unproject`.

The optional sprite reader uses the SDK's pinned artwork deployment. Art may be
cached; ownership is verified separately. Choose character rendering, styling
and animation appropriate to the game; canonical pixels and animation frames
are not mandatory. SDK artwork may be used and adapted in projects, including
finished commercial projects, under [NOTICE.md](NOTICE.md).
Use controls and accessibility features appropriate to the genre and supported
devices. For moving worlds, keep input, collision and layering consistent with
the chosen camera. Provide mute controls when audio is present and support
reduced motion, loading and errors.
See [WORLD_RULES.md](WORLD_RULES.md).

## Identity and wallet lifecycle

Every playable prototype requires a connected account owning a hardwired
Generations NFT (generation ≥ 1) on Robinhood mainnet (4663). The runtime calls
`readGenerationEligibility` at a fresh block and requires `eligible === true`
before mounting the child. Account, network and Friend changes cancel pending
confirmations, close stale bridges and trigger a fresh check. Errors or missing
identity inputs cannot fall back to sample play. Internal tests may use mocks.

Advanced discovery with `readOwnedFriends` returns `{ friends, blockNumber, hiddenCount }`.
`hiddenCount` reports owned generation-0 Friends excluded from the playable list.
It reads the account's balance at a fresh block and queries `Transfer` logs
filtered by `to` and `from` account. It reconstructs currently held IDs and checks
owner, generation and canonical wallet at the same block. It does not scan every
token in the collection. Incomplete, inconsistent or unsupported RPC history is
an error. The canonical deployment starts at its first `Transfer` block and
paginates reads within the public RPC's ten-million-block limit. Custom
deployments may supply `transferStartBlock`; omitting it starts at block zero.
Selection results still require a fresh eligibility check before play. Options
accept a deployment and abort signal.

`createFriendWalletSession({ provider?, target? })` supports EIP-6963 discovery
and injected EIP-1193 wallets. A supplied provider reuses existing wallet context.
The session exposes `getSnapshot`, `subscribe`, `connect(walletId?)`, `switchNetwork`, `refresh`,
`disconnect`, `getProvider` and `dispose`. Discovery/restoration uses read-only requests;
`connect` requests accounts from a user gesture. Identity revisions invalidate
stale reads when the provider, account or chain changes. `disconnect` forgets the
local session. `switchNetwork()` requests Robinhood mainnet from a user gesture,
adding the official network configuration if the wallet reports an unknown chain.
The runtime shows a pending state, handles declined requests, and rechecks the
connection before loading Friends. These APIs do not sign, deploy or spend.
The picker distinguishes missing wallets, disconnected accounts, wrong networks,
failed discovery and successful empty results, and explains hidden generation-0 Friends.

`createFriendPublicClient({ rpcUrl? })` uses the package's public RPC by default.
No private API key or signer is required for wallet/ownership reads. Keep wallet
and discovery clients in trusted runtime code.

## Simulated actions

`createGamePreview(definition, { stake, rfBalance, friendId?, draw? })` returns
`client` plus preview-only `fund` and `withdraw` controls. Player methods are
async `read()`, `canBuy(quantity)`, `buy(quantity)`, `play(quantity = 1n)`,
`settle(playId)` and `redeem(outcomeId, quantity)`. IDs start at one; `outcomeId`
is a number, while Friend/play IDs and quantities are bigint.

The simulated balance belongs to the selected Friend wallet. Reads include
inventory, plays, free stake, maximum-prize reserves and kept-reward liabilities.
Weights total **10,000 basis points**; RF uses **18-decimal bigint base units**.
JSON amounts are decimal strings parsed by `parseChanceGame`. In this supplied
chance game, every purchased consumable reserves its maximum prize. Settlement
happens once with no reroll; kept rewards have no expiry. Preview ledgers live
only for the runtime session.

Durable items, cosmetics, perks, upgrades and additional currencies are welcome
when backed by or integrated with **$RAREFRIENDS (RF)**; document how. These
mechanics may need custom integration: the current
bridge has no upgrade, additional-currency or persistence API. Prize reserves
apply to the supplied chance game and promised RF redemption, not automatically
to non-redeemable cosmetics or upgrades.

The low-level preview client does not enforce ownership itself. Deliverable
prototypes use the runtime's ownership gate. Label simulated balances and
outcomes. Keep all economy actions simulated by default and defer on-chain
implementation/custom Solidity unless explicitly requested.

## Live browser actions

Run the simulated example with `npm run dev:fishing`. Explicitly select the live
example to use real RF and wallet transactions:

```sh
npm run dev:fishing:live
```

Use `npm run build:fishing` or `npm run build:fishing:live` for static output in
`examples/fishing/.friendsdk/preview/` or `examples/fishing/.friendsdk/live/`.
For a personal contract, pass `--deployment` with its public manifest to
`friendsdk dev` or `friendsdk build`; use `--outdir` to choose the output directory.
See [run, build and serving instructions](HOST_INTEGRATION.md#fishing-commands).

The public fishing configuration identifies game
`0x671a5080103cd44628d6725f8187aa2d2610f8b3` on chain **4663**, deployed at block
**67238313**. The CLI accepts only public deployment fields for the browser
bundle. In React, `LiveGameDeployment` contains `chainId`, `game`, `rf`,
`generations`, `entropy`, `provider` and optional bigint `deploymentBlock`.
Use the deployment block to bound play-history reads.

`createLiveGameClient({ definition, deployment, friendId, account, publicClient,
walletClient, friendWallet?, assertActive?, maxOracleFee?, waitMs? })` returns a
`GameClient` with `mode: "chain"`. Keep it in trusted runtime code. Supply the
canonical `friendWallet` resolved by initial selection. Initial state reads
verify the selected identity, pinned Dice dependencies and matching deployed
price, outcome weights and rewards. Contracts enforce ownership and eligibility
when actions execute. Wallet prompts retain account/network/session guards;
they do not repeat ownership reads or transaction simulations.

- `read()` reads RF, backing, consumables and inventory from the contract and
  recovers the Friend's play IDs from filtered `Played` events.
- `buy(quantity)` approves exactly the RF purchase cost when needed, then
  purchases from the canonical NFT wallet. Each write requires wallet confirmation.
- `play(quantity)` consumes purchased items and returns committed play IDs.
  Existing pending plays must be resumed before starting another.
- `settle(playId)` uses that existing play, requests Dice only if its batch has
  no request, waits for delivery and submits settlement when ready. The quoted
  oracle fee is capped at **0.000025 ETH**, excluding transaction gas. `maxOracleFee`
  may lower that cap; a higher quote stops the request. `waitMs` defaults to
  30,000 and cannot exceed it.
- If delivery is pending, `settle` returns `{ id, outcomeId: null }`. Show a pending
  state and **Resume cast** for that ID; do not reveal a reward or consume another
  item. Refresh state after action errors to recover a committed play.
- `redeem(outcomeId, quantity)` sends the fixed RF value to the canonical NFT
  wallet after verified settlement and redemption receipts.

Live transfers, approvals, purchases, plays, Dice requests, settlement and
redemption require wallet prompts and ETH gas. The runtime's wallet menu provides
**Transfer RF to Friend**, a separately confirmed transfer from the connected
account to the verified canonical wallet. This control is outside the game bridge.
Live balances and prize stake always come from contract reads.

A Dice RNG request costs **0.000025 ETH**, excluding gas. Rare Friends plans to
subsidize RNG costs for **all developers** to improve the user experience and
reduce costs. The demo does not implement this subsidy; it demonstrates
wallet-paid RNG. Pending casts reuse their existing request.

## Sandbox and bridge

The runtime places one developer iframe inside `GameFrame`, using
`sandbox="allow-scripts"` without same-origin, popup, form or navigation powers.
Only the exact child window receives the transferred `MessagePort`. The child
accepts initialization only from its parent. Use a child CSP restricting scripts,
assets and approved read endpoints. The runner supplies this serving policy.

`bindGameFrame(port, { client, authorize, onSnapshot })` binds the selected
Friend's client. `authorize(method, args)` confirms buy, play and redeem, plus
settlement in chain mode, inside the frame. Calls allow only `read`, `canBuy`, `buy`, `play`, `settle` and `redeem`,
with quantities 1–99. `setPaused` stops game input while runtime menus are open.
Close the bridge and pending approvals on identity changes, child reload or
unmount. Community code stays in the sandbox.

## Optional contract transport

On-chain implementation is a later phase with the Rare Friends team after
publishing requirements are met, unless explicitly requested. Funding, contract
deployment, signatures, transactions and official Rare Friends production
publication require their applicable explicit authorization. Public simulated
previews on GitHub Pages are allowed; see [hosting instructions](README.md#build-and-share-a-preview).
Contract tooling is described in [README.md](README.md#optional-contract-development)
and [contracts/README.md](contracts/README.md).

For explicitly approved real contract testing, deploy the standalone game with
`npm run deploy:contracts`. This is not needed for a simulated preview. Its deployment
manifest supplies `chainId`, `game`, `generations`, and `rf` for the host transport.
The player's RF must be in the canonical Friend wallet; deployment prize stake
is separately funded by the developer.

`createChanceGameTransport({ deployment: { chainId, game, generations, rf },
account, publicClient, walletClient?, confirmations?, selectedFriend? })` creates the host transport
without sending requests. Use verified deployment addresses, such as the public
[fishing configuration](examples/fishing/deployment.json). The viem wallet must be configured for the pinned chain and
selected `account`. Optional `selectedFriend: { friendId, recipient }` supplies the
canonical wallet resolved during initial selection. The host obtains player
confirmation before calling:

- `approvePurchase(friendId, quantity)`: approve exactly `price × quantity` RF;
  this is separate from `buy(friendId, quantity)`.
- `play(friendId, quantity = 1n)`, `settle(playId)`,
  `redeem(friendId, outcomeId, quantity)`: fixed contract actions. All IDs and
  quantities are bigint. This transport requires the connected Friend owner;
  contracts also enforce hardwired eligibility.
- `read(friendId)`: backing, inventory, ownership, and separate `payerRF` and
  `recipientRF` balances at one block. Both balances refer to the selected
  Friend wallet. `readPlay(playId)` recovers chain state.

The connected owner signs `execute` on the selected NFT’s canonical wallet. That
wallet approves and spends RF, owns consumables and catches, and receives RF
redemption. The selected canonical address is reused for the session. Contracts
enforce authorization and eligibility when executing each action. The transport
never substitutes the owner’s RF balance. Settlement is permissionless on-chain;
this player transport uses the selected Friend wallet.

Writes check the selected account and chain, then verify successful receipts,
matching events and block hashes. They do not add repeated ownership RPC reads
or transaction simulations before wallet prompts. `ChanceTransactionError` retains `transactionHash` and
a code: `unconfirmed`, `reverted`, `replaced`, `reorg`, or `unverified`. Inspect
the transaction before retrying; no optimistic result is returned. Confirmations
default to one and do not assert finality. The transport has no funding,
withdrawal, deployment or arbitrary transaction methods. `createLiveGameClient`
adapts this transport to the fixed browser bridge. `GameClient` and `GameSnapshot`
identify preview versus chain mode; `PreviewGameClient` remains preview-only.
The trusted runtime owns the separate RF-transfer control and all wallet prompts.
See [runtime capabilities](HOST_INTEGRATION.md#capabilities).

`play` commits the outcome inputs and returns play IDs plus their `batchId`.
In the standalone contract, that ID is the first play ID of the group. A sponsor
then calls `requestRandomness(batchId)` with Dice's exact quoted ETH fee. Dice's
authenticated callback records the result; `settle(playId)` mints each reward.
Use `npm run resolve:contracts -- <manifest> <playId>` for this sponsor/settlement
step during development. It can be rerun for a pending or already settled play.
The live runtime performs the same fixed request/settlement flow through
`settle(playId)` with in-frame authorization and wallet prompts. See
[oracle operations and recovery](docs/oracle/README.md) for the resolver workflow
and proposed recovery work.

## Unsupported actions

SDK v0.1.4 has no trading, listing, bidding, swap, creator-fee/revenue-share, wearable
NFT, upgrade, additional-currency or persistence APIs. Fixed-price vendor
redemption is the sale model supplied by the chance-game client. These are
implementation limits, not a ban on those ideas; document the custom integration
your design needs. The browser runtime supports preview and explicitly configured
live play. See the
[capability list](HOST_INTEGRATION.md#capabilities) for implemented functions and
remaining integration work.
