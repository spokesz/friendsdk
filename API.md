# FriendSDK API

Run `npm ci && npm run build`. The package emits browser ESM and TypeScript
declarations in `dist/`; neither build nor runtime reads the website repository.
Import named modules from `@rarefriends/friendsdk/<module>`.

| Module | Exports and use |
| --- | --- |
| `world` | `WORLD_PRESETS`, `getWorldPreset`, `validateWorld`, `renderWorld`, `renderWorldLayers`, `renderProp`, `project`, `unproject`, `isWorldWalkable`. Scene geometry, props, collision and depth sorting. |
| `navigation` | `createWorldNavigator(world, radius?, spacing?)`: collision-checked `route(from, to)` and `segmentClear(from, to)`. |
| `movement` | `createWorldMovement(world, spawn, { speed?, radius? })`: `setKey(key, pressed)`, `moveTo(point)`, `update(deltaMs)`, `stop()`, `reset()`, and `state`. Arrows/WASD use screen directions; clicks use world coordinates. |
| `assets` | `loadImage(url, signal?)`, `loadSvg(svg, signal?)`, `loadWorldAssets(world, renderOptions?, signal?)`. World assets return `terrain` and ordered `objects` with `image` and `depth`. |
| `sprites` | `createFriendReader()` or `createGenerationSpriteReader(publicClient, manifest?)`; `read(tokenId)` loads canonical frames. `spriteFrame` selects direction/action/gait. Art is cached; ownership is not inferred. |
| `identity` | `readGenerationEligibility(publicClient, tokenId, player?, deployment?)`: reads owner and generation at one fresh block. Eligibility means player ownership and generation ≥ 1. No activation requirement. Contracts must check again when spending. |
| `sounds` | `createFriendSoundKit()`: `unlock()` from a user gesture, `play(cue)`, `setMuted`, `setVolume`, `stop`, `dispose`. Ten synthesized cues; `renderFriendSound` also produces PCM. |
| `items` | `GameItem`, `GameReward`, `GameShopOffer`, `GameItemQuantities`, `formatGameItemQuantity`. Presentation types and exact quantity formatting. |
| `ui` | React 19 `ExperiencePanel`, `GameHud`, `ActivityPrompt`, `ItemPicker`, `ItemArt`, `Keycap`, `formatGameAmount`. Caller supplies state and callbacks. |
| `reveal` | React 19 `RewardReveal`, `REWARD_REVEAL_TIMING`. Reveals an existing result with skip/reduced-motion support; never chooses rewards. |
| `game` | `parseChanceGame(json)`, `defineChanceGame`, `maximumPrize`, `expectedReward`, `outcomeForRoll`, `RF`. RF amounts are bigint base units; weights total 10,000 basis points. |
| `frame` | `GAME_VIEWPORT` (960 × 640), `GameFrame`, `GameMenu`. Host-owned Friend selection, NFT wallet and confirmation UI contained in the viewport. Import `frame.css`. |
| `bridge` | `bindGameFrame` (trusted host) and `createFrameGameClient` (game). Fixed actions over a private transferred `MessagePort`; no arbitrary transaction or page UI access. |
| `host` | `createChanceGameTransport`, `ChanceTransactionError`. Trusted-host transport for the fixed ChanceGame contract; keep it outside community frames. No production host is connected. |
| `examples/fishing` | `FishingGame({friendId,client,paused?})` is the developer viewport; `FishingPreview` wraps the standalone local sample in the shared frame. A separate compiled frame document supports sandboxed host integration experiments. |

React components require explicit styles:

```ts
import "@rarefriends/friendsdk/ui.css";
import "@rarefriends/friendsdk/reveal.css";
```

Movement does not attach events. A scene forwards keyboard/pointer input, calls
`update` from its animation loop, and calls `stop` on blur, pause, or hidden tabs.
Speeds are screen pixels per second; `state.position` is a world point. Convert
pointer coordinates through the host canvas scale/crop, then `unproject`.

The default sprite manifest pins the SDK's artwork deployment independently.
It is not a verified game deployment. Eligibility observation may change after a
transfer; no SDK read grants transaction permission.

`createGamePreview(definition, { stake, rfBalance, friendId?, draw? })` returns
`client` plus separate preview-only `fund` and `withdraw` controls. Player methods
are async `read()`, `canBuy(quantity)`, `buy(quantity)`, `play(quantity = 1n)`,
`settle(playId)`, and `redeem(outcomeId, quantity)`. IDs start at one. The balance
represents a simulated Friend wallet paying and receiving RF. Reads include
inventory, plays, free stake, maximum-prize reserves, and kept-reward liabilities.
There is no clock or expiry. Browser draws and preview state never authorize
chain payouts; repeated settlement fails without rerolling.

Deploy the standalone game with `npm run deploy:contracts`. Its deployment
manifest supplies `chainId`, `game`, `generations`, and `rf` for the host transport.
The player's RF must be in the canonical Friend wallet; deployment prize stake
is separately funded by the developer.

`createChanceGameTransport({ deployment: { chainId, game, generations, rf },
account, publicClient, walletClient?, confirmations? })` creates the host transport
without sending requests. Use verified deployment addresses; none are supplied
for a live game. The viem wallet must be configured for the pinned chain and
selected `account`. The host obtains player confirmation before calling:

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
redemption. The adapter verifies the wallet’s owner and token binding, then checks
ownership and wallet identity again after simulation. It never substitutes the
owner’s RF balance. Settlement is permissionless on-chain; this player transport
limits it to the Friend controller.

Writes simulate, check wallet/chain, and verify successful receipts, matching
events and block hashes. `ChanceTransactionError` retains `transactionHash` and
a code: `unconfirmed`, `reverted`, `replaced`, `reorg`, or `unverified`. Inspect
the transaction before retrying; no optimistic result is returned. Confirmations
default to one and do not assert finality. The transport has no funding,
withdrawal, deployment, or arbitrary transaction methods. The bridge and local
preview clients belong to this prototype; the production web app does not use
them. They are not a ready-made live browser host.

`play` commits the outcome inputs and returns play IDs plus their `batchId`.
In the standalone contract, that ID is the first play ID of the group. A sponsor
then calls `requestRandomness(batchId)` with Dice's exact quoted ETH fee. Dice's
authenticated callback records the result; `settle(playId)` mints each reward.
Use `npm run resolve:contracts -- <manifest> <playId>` for this sponsor/settlement
step during development. It can be rerun for a pending or already settled play.
If Dice never reveals, that command is also where the Friend's owner retries the
stuck request after Dice's own delay; the transport and the frame bridge expose
no retry and no oracle action at all.
Sponsorship belongs to developer tooling, not the game's limited action client.

## Hosting boundary

These are SDK host requirements for isolated integration work. There is no
production game host or catalog.

Render `GameFrame` in the trusted host and its developer iframe inside the frame.
Use `sandbox="allow-scripts"` without same-origin, popup, form or navigation
permissions. Only the exact child window’s ready message receives a transferred
MessagePort. The child accepts initialization only from its parent. Serve a
separate CSP restricting its script, assets and approved read endpoints; the
reference document is `dist/embed/fishing-frame.html`.

The host binds the selected Friend’s client with `bindGameFrame(port, {client,
authorize, onSnapshot})`. `authorize(method,args)` obtains shared in-frame
confirmation for buy, play and redeem. Calls allow only read, canBuy, buy, play,
settle and redeem, with quantities 1–99. The current bridge is explicitly preview;
it does not claim a live deployment. Close it and remount the child whenever the
Friend, connected account or network changes. An old pending approval cannot
spend after closure. `setPaused` stops game input while host menus are open.

The standalone local example demonstrates menus and local state. Any future
community-game host must load developer code through the sandbox rather than
rendering it as a React child of its page.
