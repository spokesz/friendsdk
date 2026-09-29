# Embedded fishing example · FriendSDK v0.1.4

This example configures the reusable `GameHost` runtime with the fishing game.
`GameHost` provides wallet connection, owned Friend discovery and selection,
fresh ownership/eligibility checks, the 960 × 640 frame, sandbox, simulated
ledger and in-frame confirmations. Fishing supplies the playable world and
its economy definition.

The fishing reference uses a world where the player moves their owned Rare
Friend to activity locations with keyboard and touch controls. Other project
setups, genres and interfaces can use the same runtime.

The runtime accepts games with their own setting, assets, visual style, camera
and renderer. Fishing's scenery and the SDK's `GameWorld`, world assets and presets
are optional example choices. Custom character art and menus are welcome; use
accessible controls suited to the genre while keeping the real NFT eligibility
gate, sandbox boundary and supported action client.

## Use the runtime

For component development, use the package runner:

```sh
npm ci
npm run dev:game -- examples/fishing
```

The runner handles the game bundle, child handshake, static serving and runtime
mount. A game directory contains `index.tsx` with a default-exported component
accepting `GameComponentProps`, plus `game.json` and its assets. The SDK's
`GameSession` handles the sandbox child session. See
[the getting-started guide](../../README.md#build-your-game-with-an-ai-agent) for the generic starter and package CLI.

For an existing React mount with a built child document:

```tsx
import { GameHost } from "@rarefriends/friendsdk/runtime";
import { parseChanceGame } from "@rarefriends/friendsdk/game";
import fishingDefinition from "@rarefriends/friendsdk/examples/fishing/game.json";
import "@rarefriends/friendsdk/frame.css";
import "@rarefriends/friendsdk/runtime.css";

const definition = parseChanceGame(fishingDefinition);

<GameHost
  definition={definition}
  frameUrl="/sdk-games/fishing/fishing-frame.html"
/>
```

Use one runtime frame for the game. To supply existing wallet and Friend
selection context, use `ConnectedGameHost` with the definition, frame URL,
selected Friend, account, chain ID and read-only public client. It retains the
same eligibility gate and sandbox. See the
[runtime guide](../../HOST_INTEGRATION.md) for the supported props and serving
requirements.

## Identity and isolation

Every playable prototype, including simulated previews, requires a connected
account that owns a hardwired Generations NFT (generation ≥ 1). `GameHost` calls
`readGenerationEligibility` at a fresh block before mounting the playable child.
Wallet connection, discovery results and artwork do not replace that eligibility
check. Loading, connection, selection, ineligible, failed-read and retry states
stay inside the container.

The child runs with `sandbox="allow-scripts"` and a restricted CSP. A private
`MessagePort` exposes only `read`, `canBuy`, `buy`, `play`, `settle` and `redeem`.
The runtime confirms actions inside the frame and pauses game input while its
menus are open. Account, network or Friend changes cancel pending confirmations,
close the old bridge and require a fresh eligibility check. Child reload closes
the old session before a new handshake.

Wallet connection and eligibility reads require no signing transaction. The
runtime simulates RF balances and game actions. Keep on-chain game implementation
and custom Solidity deferred unless explicitly requested; the later phase is
undertaken with the Rare Friends team after publishing requirements are met.
Contract deployment, transactions and official Rare Friends production publication
require their applicable authorization. Public simulated previews on GitHub Pages
are allowed without separate Rare Friends approval; see the
[hosting instructions](../../README.md#build-and-share-a-preview).
See the [prototype requirements](../../README.md#required-prototype-identity-and-interface).

## Fishing configuration

The example starts each preview ledger with **20 RF** and **100 RF** prize stake.
Bait costs **1 RF**; each purchased bait reserves **10 RF** and yields one result.
The expected return is **0.90 RF**; kept rewards have no redemption expiry. Amounts
use bigint RF base units. Exact outcome weights, rewards and consumable rules
are in [game.json](../fishing/game.json) and
[the fishing design](../../FISHING_GAME_DESIGN.md).

The component includes a vendor, fishing location, inventory, reveals, odds,
sound and reduced motion. This reference does not implement cosmetics, trading
or creator fees; other ideas may need capabilities beyond the current runtime.

## Verify

```sh
npm test
npm run typecheck
npm run check:games
npm run check:browser
```

`npm run check:runtime` runs the generic runtime browser check alone. The
internal fixtures supply mock ownership reads and sample Friends for automated
lifecycle checks. Playable prototypes use real wallet connection and the
runtime's fresh ownership gate.
