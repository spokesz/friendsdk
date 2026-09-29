# FriendSDK v0.1.4

Build a playable Rare Friends game with your AI coding agent. You create the
experience and game rules; the SDK supplies wallet connection, owned Friend
selection, a reference inventory and action flow, and a sandboxed game container.
The reference layout is **960 × 640** and can be customized. Purchases and rewards
are simulated by default.

Start in this repository or install the package in your current project. The SDK
includes the runtime, optional world assets and examples to get started. Choose
the world's artwork and visual style to suit your game.

**World size is yours to choose.** The 576 × 384 plane belongs to the optional
renderer; custom cameras and worlds of any size are allowed. The container is
the viewing window, not a world boundary. See the
[scrolling-world example](examples/scrolling-world) for a larger map and camera.

## Is FriendSDK right for your idea?

FriendSDK fits games that use its Friend identity, sandboxed viewport and game
actions. Before building, check the [current capabilities](HOST_INTEGRATION.md#capabilities)
against your idea. Coding agents should make this check before scaffolding a project.

Durable items, cosmetics, perks, upgrades and additional currencies are welcome
when backed by or integrated with **$RAREFRIENDS (RF)**. Document that relationship
in your submission. The supplied chance-game client
currently supports one consumable and one weighted outcome table. Other mechanics
may need custom integration; persistent saves, upgrade actions and additional
currency APIs are not supplied. These API limits do not define which ideas you
may submit.

**FriendSDK is optional for vibeathon submissions.** If you're building a launchpad,
tool, agent or another experience that doesn't fit the SDK, use the stack and
interface that suit it. Follow the
[Rare Friends Vibeathon submission guidelines](https://github.com/spokesz/rarefriends-vibeathon#how-to-submit)
for the non-SDK path, including source, run instructions and a demo. The SDK's
container and game-specific rules apply to SDK games; consult the vibeathon
guidelines for other submissions.

For build or submission help, join [Vibeathon support on Telegram](https://t.me/RFVibeathon).

## What you need

- A Linux or Windows computer and an AI coding agent that can edit files and run
  terminal commands in your project.
- **Node.js 22 or newer**, npm and Git. The setup below uses Node.js 22.
- A browser wallet connected to **Robinhood mainnet (chain 4663)**, holding a
  hardwired Rare Friends Generations NFT (generation ≥ 1).

The wallet and NFT are required to play, including simulated previews. Preview
balances and outcomes are simulated; preview play requires no RF funding,
private key or transaction signature. Foundry is needed only for contract work.

## Set up your machine

### Linux

Install Git with your distribution's package manager. On Ubuntu or Debian:

```sh
sudo apt update
sudo apt install -y git curl ca-certificates
```

Install [Node.js](https://nodejs.org/en/download) 22+ with npm. If you use
[nvm](https://github.com/nvm-sh/nvm#installing-and-updating), install it using its
official instructions, reopen your terminal, then run:

```sh
nvm install 22
nvm use 22
```

Check that the tools are available in the terminal your agent uses:

```sh
node --version
npm --version
git --version
```

### Windows

Use **Ubuntu in WSL2** for this workflow. Open PowerShell as Administrator:

```powershell
wsl --install -d Ubuntu
```

Restart if prompted, open **Ubuntu** from the Start menu, and finish creating
its Linux username and password. See [Microsoft's WSL installation guide](https://learn.microsoft.com/en-us/windows/wsl/install)
for prerequisites and installation help.

Complete the Linux setup above **inside Ubuntu**, including Node.js, npm and Git.
Run the remaining commands in Ubuntu. Keep the project in your Linux home
folder, and open that folder with an agent/editor connected to WSL so its tools
use the same environment. Native PowerShell builds and checks are not yet a
verified SDK workflow.

Your browser and wallet extension run on Windows. Open `http://localhost:4173`
to reach the game running in WSL, as described in [Microsoft's networking guide](https://learn.microsoft.com/en-us/windows/wsl/networking#accessing-linux-networking-apps-from-windows-localhost).

## Run your first game

In your Linux or Ubuntu terminal, choose a folder for your projects and run:

```sh
git clone https://github.com/spokesz/friendsdk.git
cd friendsdk
npm ci
npm run dev:game -- examples/starter
```

If you downloaded a ZIP, extract it and open a terminal in the folder containing
`package.json`; start with `npm ci`.

Open the displayed URL, normally `http://localhost:4173`. Choose **Connect
wallet**. If your wallet is on Ethereum or another network, choose **Switch to
Robinhood** and approve the network change in your wallet. The runtime can add
Robinhood mainnet if needed, using the [official network settings](https://docs.robinhood.com/chain/connecting/).
Then select your owned Friend and enter the garden. Move with WASD, arrow
keys or a tap/click destination. Walk to the pack dispenser to buy a simulated
pack, then to the opening station to reveal it.

The picker explains missing wallets and connection or discovery failures, with
retry controls. It reports generation-0 Friends as hidden because play requires
a hardwired Friend (generation 1 or higher).

Keep the terminal running while you play. Source changes rebuild automatically;
refresh the browser to see them. Press **Ctrl+C** to stop the server.

## Build your game with an AI agent

Open this project folder in your agent. After trying the starter, stop its server
and give your agent a brief such as this, replacing the bracketed description:

> Read AGENTS.md, README.md, API.md and WORLD_RULES.md. Read
> FISHING_GAME_DESIGN.md if using its economy.
> Build [describe the game and its activities] in games/my-game, starting from
> examples/starter. Work in this project and deliver the game component, assets
> and rules. Choose assets, rendering, layout and controls that fit my idea.
> Use the starter's walkable world and menus where they help the experience.
> Keep game UI inside the sandboxed container. Use the SDK runtime for wallet
> connection, owned Friend selection, inventory and confirmations. Keep purchases
> and rewards simulated.
> Do not add website navigation, headers, footers, About/Store pages, a separate
> wallet flow or another application checkout. Run the relevant checks and give
> me the command and local URL to play.

The commands to create and run your own copy of the starter are:

```sh
npm run build
npx friendsdk init games/my-game
npm run dev:game -- games/my-game
```

`init` creates a new directory and refuses to overwrite an existing one. Choose
your own name in place of `my-game`. Your game files are:

| File | What your agent changes |
| --- | --- |
| `index.tsx` | Game interface and interactions; default-export the game component or adapter |
| `game.json` | Exact RF cost, outcome weights, rewards and consumable rules |
| `style.css` and local assets | Your game's visual style and world artwork |
| `host.css` (optional) | Trusted runtime layout, including container size/aspect ratio |
| `README.md` | Your game's controls, run instructions and exact rules |

The component receives `friendId`, `client` and `paused` through
`GameComponentProps`. Use the SDK's fixed action client for supported actions;
its menus are reference components for your game UI. The supplied world renderer,
presets, scenery and Friend sprites are optional. Choose character rendering and
artwork that fit your game, and pause gameplay interactions when `paused` is true.
Edit source files; `.friendsdk/` contains generated output.

### Required prototype identity and interface

The runtime verifies fresh ownership of the selected hardwired Generations NFT
before play and rechecks when the account, network or selection changes. Items
and rewards belong to that NFT's canonical wallet. Mock identities are reserved
for automated tests.

Keep game UI and runtime confirmations inside the sandboxed container. Choose
controls appropriate to the genre and target devices; a puzzle or card game does
not need character movement. Make touch interactions usable on supported phones,
provide keyboard access where appropriate, support reduced motion, and show
loading and error states. If the game has audio, provide mute controls. For moving
worlds, keep collision, pointer input and layering consistent with the camera.
Use existing wallet and Friend context through `ConnectedGameHost` when supplied
by the current project; see [the runtime guide](HOST_INTEGRATION.md).

### Larger worlds and practical details

Run `npm run dev:game -- examples/scrolling-world` to try a larger world inside
the reference frame. Custom cameras, scrolling maps and connected rooms are allowed;
choose a world size that performs well on your target devices. The optional
`GameWorld` renderer's fixed camera is one starting point, not a platform limit.

The **960 × 640** layout and SDK menus are references, not fixed presentation
requirements. For a wider CLI game, add a `host.css` file in its game directory:

```css
:root {
  --rf-game-max-width: 1200px;
  --rf-game-aspect-ratio: 16 / 9;
}
```

Use `480px` and `3 / 4` for a portrait layout. The defaults are `960px` and `3 / 2`.
The CLI loads `host.css` into the trusted runtime page; your child `style.css`
still controls the game UI. In a custom host, set these variables on the wrapper
around `GameHost` or `ConnectedGameHost`. See
[runtime integration](HOST_INTEGRATION.md#react-runtime).
Restart the dev runner after adding `host.css` for the first time; edits to an
existing file rebuild automatically.

- **Toolbar:** the runtime overlays wallet/Friend controls at the bottom-left
  and a menu button at the bottom-right. Place important HUD controls clear of
  them and check on a phone-sized viewport.
- **Small screens:** the default frame keeps a 3:2 aspect ratio. At 360 pixels
  wide it is about 240 pixels tall; check your chosen layout on target devices.
- **Storage:** the sandbox has no `localStorage` or IndexedDB access and the
  bridge has no save API. Simulated balances and inventory last for the runtime
  session; reloading starts a new session. Persistent progress is not supplied.
- **Input:** where the game uses a camera, transform pointer coordinates through
  its display scale. Pause gameplay interactions when the runtime opens a menu.

## Try the fishing example

Fishing is a complete example with a bait vendor, lake, catches and fixed-price
redemption. Run these commands from the SDK root:

| Mode | Play locally | Build static files | Output folder |
| --- | --- | --- | --- |
| Simulated | `npm run dev:fishing` | `npm run build:fishing` | `examples/fishing/.friendsdk/preview/` |
| Live contracts | `npm run dev:fishing:live` | `npm run build:fishing:live` | `examples/fishing/.friendsdk/live/` |

Live mode uses the included [public deployment configuration](examples/fishing/deployment.json)
and real wallet transactions. The NFT's canonical wallet needs RF for bait;
**Transfer RF to Friend** in the wallet menu funds it from the connected account.
Keep ETH in the signing wallet for gas and RNG fees. Bait costs **1 RF**, the
maximum reward is **10 RF**, and the expected reward is **0.90 RF**. See the
[fishing guide](examples/fishing/README.md) for controls and the full outcome table.

The live runtime caps each Dice RNG request at **0.000025 ETH**, excluding gas.
Rare Friends plans to subsidize RNG costs for all developers to improve the user
experience and reduce costs. This demo uses wallet-paid RNG and does not include
the subsidy. For a pending cast, choose **Resume cast** to continue its existing
result. Detailed [oracle operations and recovery](docs/oracle/README.md) are
separate from game development.

## Build and share a preview

**You may deploy and share public playable previews on GitHub Pages or another
static host, including from your own fork. No separate Rare Friends approval is
required for submission previews.** You may use and adapt SDK-supplied artwork
in your projects, including finished commercial projects; see [NOTICE.md](NOTICE.md).
The SDK source is Apache-2.0. Keep the wallet/ownership
gate and label the economy as simulated. Official publication through Rare
Friends remains a separate review.

Build your component from the SDK root:

```sh
npm run build
npx friendsdk build games/my-game
npx friendsdk check games/my-game
```

The output is `games/my-game/.friendsdk/`. Use that folder as your static site's
root and upload all generated HTML, JavaScript, CSS and assets. Preserve relative
paths and the sandbox document's CSP. See [serving requirements](HOST_INTEGRATION.md#serving-and-sandbox)
for HTTPS hosting.

To host on **GitHub Pages**:

1. Copy the **contents** of `games/my-game/.friendsdk/` into the root of a dedicated
   `gh-pages` branch in your repository or fork. Keep `index.html`, `game.html`,
   JavaScript, CSS and asset folders together, and add an empty `.nojekyll` file.
2. In **Settings → Pages**, choose **Deploy from a branch**, select `gh-pages`
   and **/(root)**, then save. See [GitHub's publishing instructions](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site).
3. Open `https://<account>.github.io/<repository>/`, verify the preview works,
   and add that URL to your submission README and PR description.

You may also use your own GitHub Pages Actions workflow to deploy the generated
files. Players still need an eligible Friend and a wallet on Robinhood mainnet;
the automated test harness's mocked wallet is not included in public builds.

To play from another device on your local network:

```sh
npm run dev:game -- games/my-game --host 0.0.0.0 --port 4173
```

Open `http://YOUR_COMPUTER_LAN_IP:4173` on that device using a browser with your
wallet available. Allow the port through your local firewall as needed. WSL2
also needs [LAN networking configuration](https://learn.microsoft.com/en-us/windows/wsl/networking#accessing-a-wsl-2-distribution-from-your-local-area-network-lan).

## Install in an existing project

Download `rarefriends-friendsdk-0.1.4.tgz` from the
[v0.1.4 GitHub release](https://github.com/spokesz/friendsdk/releases/tag/v0.1.4)
into your existing project, then run there:

```sh
npm install ./rarefriends-friendsdk-0.1.4.tgz react react-dom
npx friendsdk init ./games/my-game
npx friendsdk dev ./games/my-game
```

To create the archive yourself from an SDK checkout, run `npm ci` and `npm pack`.

Build with `npx friendsdk build ./games/my-game`, then validate with
`npx friendsdk check ./games/my-game`. The package supplies the runner and
runtime; your agent works in your current project. Node tooling has supported
`@rarefriends/friendsdk/build`, `/serve` and `/testing` imports; no relative
imports into `node_modules` are needed. See [tooling APIs](API.md#node-tooling).
Keep your existing project structure, renderer and build tools if they suit your
game. Mount `GameHost` or `ConnectedGameHost` in the trusted page and use a thin
React `GameSession` adapter in a separately built sandboxed child. That adapter
can pass `friendId`, `client` and `paused` to your existing renderer; the game
itself need not be written in React. Keep the runtime's identity gate, sandbox
and confirmations. See [runtime integration](HOST_INTEGRATION.md#react-runtime).

The CLI route still expects `index.tsx` and `game.json`; its checker allows game
sources within that game directory plus the SDK and dependencies. A custom
build may use your project's own entry points and validation, with the same
runtime/sandbox requirements. The current runtime still accepts a
`ChanceGameDefinition`, even when your game does not use its economy actions.

The SDK is distributed as a package archive. Publication to the npm registry
is not planned. Source code uses [Apache-2.0](LICENSE); artwork
permissions are separate. See [NOTICE.md](NOTICE.md).

### Check your game without a wallet

The automated browser harness works with any game directory. It provides a mock
wallet, mock Robinhood RPC reads and sample canonical sprites, runs the normal
runtime and captures browser errors. Install its optional browser dependency once:

```sh
npm install -D playwright
npx playwright install chromium
npx friendsdk test ./games/my-game --screenshot ./artifacts/game.png
```

On Linux, use `npx playwright install --with-deps chromium` if system libraries
are missing. Add `--width 360` to check a phone-sized frame. The test builds into
a temporary directory and closes its browser/server when finished. Add a focused
interaction check with the exported [test helper](API.md#automated-game-tests).

Mocks are for automated tests only. `dev` and `build` still require a connected
wallet owning an eligible Friend on Robinhood before play. A passing mock test
does not verify real ownership reads or replace a real-wallet playtest.

## Optional contract development

Keep the first game prototype simulated. Use the supplied live adapter and
contract tools when you explicitly choose to implement on-chain play. Contract
deployment, funding and wallet transactions require explicit authorization.
Official production publication through Rare Friends requires separate review;
[hosting a simulated submission preview](#build-and-share-a-preview) is allowed.

### Deploy your game to mainnet

Install [Foundry](https://getfoundry.sh/introduction/installation/) in your Linux
or WSL environment, then follow [contract setup and deployment](contracts/README.md).
The deploying wallet needs ETH for gas and RF for the prize stake. Deployment
does not require a Generations NFT ID.

From the SDK root:

```sh
npm run deploy:contracts -- examples/fishing/game.json
```

Enter the stake and private key only at the script's terminal prompts; the key
prompt is hidden. Review the terms before confirming deployment. Never put a
private key in chat, source or an environment file. The script prints a manifest
for connecting the game to your contracts. The [contract guide](contracts/README.md#deploy-and-run-a-game)
covers that connection, deployment resume and terminal play.

## Verify and submit

For a CLI game, build it, run `friendsdk check` and `friendsdk test` as above, and
check its genre-appropriate controls on target devices. For a custom build, run
your equivalent build and browser checks, including the real ownership gate.
For SDK changes, run the relevant tests and checks from the SDK root:

```sh
npm test
npm run typecheck
npm run check:games
npx playwright install --with-deps chromium
npm run check:browser
```

Playwright's browser installation is a one-time setup; Linux may request system
package installation. Foundry is optional for the SDK checks: local contract
integration tests report a skip when its tools are unavailable. For contract
changes, also run the checks in the [contract guide](contracts/README.md).

For vibeathon game submissions, include a **public playable preview URL** in the
submission README and PR description, with the required wallet/network and
controls. GitHub Pages is an allowed host; use the steps above.

Submit the game source and assets, run instructions, SDK version **v0.1.4** and
exact costs and rules for its items, rewards, upgrades and currencies. Include
outcome weights and consumable rules when using the supplied chance game. RF uses
bigint base units (`1 RF = 10n ** 18n`). In that chance game, each purchased
consumable reserves its maximum prize and kept rewards retain their RF backing
with no redemption expiry. Promised RF redemption must remain backed; cosmetics
or upgrades without an RF redemption promise do not need a prize reserve. Label
simulated results, and claim live transactions only after verified receipts.

Record asset sources and any capability gaps. Supply thumbnail/title, developer
credit, About and Store metadata only when requested by the publishing interface.
Rare Friends reviews the game and assets against `AGENTS.md` before official
production publication. This repository's checks do not deploy games; developers
may host submission previews themselves or through their own Pages workflow.

## Reference docs

| Guide | Use it for |
| --- | --- |
| [AGENTS.md](AGENTS.md) | Instructions for your coding agent |
| [API.md](API.md) | Exported modules and game actions |
| [Runtime and capabilities](HOST_INTEGRATION.md) | Runtime integration, sandbox serving and implemented features |
| [World and character guidance](WORLD_RULES.md) | World design, character rendering and optional renderer utilities |
| [Fishing design](FISHING_GAME_DESIGN.md) | Complete example rules and reward table |
| [Sound kit](SOUND_KIT.md) and [asset notices](NOTICE.md) | Audio controls and asset provenance |
| [Contracts](contracts/README.md) | Optional contract deployment and developer tooling |
| [Oracle operations](docs/oracle/README.md) | RNG delivery, pending plays and proposed recovery work |

Trading, creator fees and wearable NFTs are not implemented in v0.1.4. See the
[capability list](HOST_INTEGRATION.md#capabilities) for the full supported scope.
