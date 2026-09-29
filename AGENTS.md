# Build with FriendSDK

## Build the requested experience

Choose the interface and mechanics that fit the idea. Walkable worlds, cards,
puzzles, management screens and other formats are welcome. The starter's world,
movement and location-based activities are references, not required game design.

Durable items, cosmetics, perks, upgrades and additional currencies are welcome
when backed by or integrated with **$RAREFRIENDS (RF)**. Explain that backing or
integration in the submission and label simulated mechanics. Any promised RF
redemption must remain funded. The supplied chance-game API is one implementation;
mechanics beyond its current capabilities need their own integration.

## Workspace and deliverable

Unless otherwise requested, build in the user's current project directory. Do
not modify another application or integrate into a separate host repository.
Build only the requested game component, assets and logic. Do not add site
navigation, routing, headers, footers, landing pages, About/Store pages, catalogs
or detail pages unless explicitly requested.

Read README.md, API.md and WORLD_RULES.md before changing a game, and
FISHING_GAME_DESIGN.md when working on that example or its economy. Use exported
SDK APIs at the integration boundary. Keep the project's existing source layout,
engine and build tools where practical; a thin React adapter can mount another
renderer through `GameSession`. Choose assets, art style, palette and camera to
suit the game. SDK reference content lives in `examples/` or `games/`.

The optional renderer's 576 × 384 plane is not a platform limit. Custom cameras,
scrolling maps and worlds of any size are allowed. The reference viewport is
960 × 640; portrait, wider and responsive layouts are welcome. See
`examples/scrolling-world` for a larger-world reference.

## Use the package runtime

For the supplied CLI, the game directory contains `index.tsx`, `game.json` and
assets. Default-export a React adapter accepting `GameComponentProps`
(`friendId`, `client`, `paused`). Existing projects may build their own child
document with `GameSession` and mount it through `GameHost` or
`ConnectedGameHost`; the CLI directory layout is not a submission requirement.
The current runtime still accepts a chance-game definition and fixed action
client. Document custom build/run steps and integration gaps.

Run `npm ci` and `npm run dev:game -- examples/starter` in this SDK checkout, or
`npx friendsdk dev ./games/my-game` with the
[package archive installed](README.md#install-in-an-existing-project).
The runner supplies the runtime, sandbox document, bridge and local serving.

`GameHost` from `@rarefriends/friendsdk/runtime` supplies wallet connection,
owned Friend discovery/selection, fresh eligibility checks, a simulated ledger
by default, frame and confirmations. Use `ConnectedGameHost` when wallet and selected Friend
context already exists. Reuse that context without adding another selection or
connection flow. `GameSession` handles the child session. Game code uses only the
SDK's fixed action client; wallet providers and clients remain outside the sandbox.

Do not implement wallet connection, NFT discovery, an ownership gate or another
Friend selector in game code. Use the SDK runtime. Never scan the Generations
collection or enumerate token IDs to find a player's NFTs. Do not locate another
checkout or require website source, private services or developer-local files.

The **960 × 640** viewport and SDK menu components are references. Choose custom
menus and a layout suited to the game. The CLI can load an optional `host.css`
for trusted runtime styling; see the layout options in HOST_INTEGRATION.md.
Keep community game code and its UI inside the sandbox. Wallet identity and
transaction confirmations remain in the trusted runtime and must stay usable.
Do not access the parent page, inject outside UI, open popups or request
top navigation from game code.

## Required prototype identity

Every creator-facing or playable prototype requires a connected wallet whose
account owns a hardwired Rare Friends Generations NFT (generation ≥ 1). This
applies to builders and players, including simulated previews and explicitly
requested alternative interfaces. No activation, tier or weight rule is added.

The trusted runtime must use `readGenerationEligibility` at a fresh block before
enabling play. Artwork, a typed token ID, discovery results and a `kind: "owned"`
label do not verify ownership. Keep connection, selection, loading, ineligible,
error and retry states in the container. Unverified or failed reads cannot play.

On account, network or Friend changes, cancel pending confirmations, close the
old bridge and recheck eligibility before the new session. Resolve the canonical
NFT wallet for the selected session. Contracts enforce ownership and eligibility
when live actions execute; do not add repeated ownership reads or transaction
simulations before wallet prompts. Retain account/network/session cancellation
and receipt verification. Inventory and rewards belong to the canonical NFT
wallet, not a substituted owner address.

Automated tests may use mock accounts and sample Friends through
`npx friendsdk test <game-directory>` or `@rarefriends/friendsdk/testing`. They are
test fixtures, not deliverable prototypes. Verify the real ownership gate before
delivering a playable prototype. Wallet connection and ownership reads require
no private key or signing transaction.

## Prototype scope: defer on-chain implementation

Unless explicitly instructed otherwise, keep purchases, rewards, redemption and
other economy actions simulated. Do not implement transaction adapters,
deployment flows, on-chain game actions or custom Solidity for a prototype.
Required wallet connection and read-only ownership checks remain in scope.
Label simulated balances and outcomes.

On-chain implementation is a later phase with the Rare Friends team after the
experience passes publishing requirements. Document intended actions and
capability gaps for that review. Existing contract tools and transport docs are
references for that phase. An explicit request for on-chain coding does not
authorize funding, contract deployment, signatures, wallet transactions or
official Rare Friends production publication;
obtain the applicable explicit authorization. Report publishing readiness only
when supported by evidence.

Public playable submission previews may be hosted on GitHub Pages or another
static host, including from a developer's fork, without separate Rare Friends
approval. Developers may deploy the bundled runtime and SDK-supplied artwork for
these previews. Keep the real wallet/eligibility gate and simulated economy.
When the developer asks to host a preview, follow that request without adding
another Rare Friends permission step. Official Rare Friends production
publication and on-chain transactions retain their separate authorization rules.

For explicitly requested live play, use the SDK runtime with a public deployment
configuration (`--deployment` in the CLI). Keep exact RF approvals, wallet
confirmations, canonical-wallet RF transfers and the Dice fee cap of 0.000025 ETH
excluding gas in trusted runtime code. Live mode requires signed transactions.
Rare Friends plans to subsidize RNG costs for all developers; the demo implements
wallet-paid RNG and does not implement that planned subsidy.
Recover pending plays by their existing IDs and expose **Resume cast**; never
consume another bait to recover a pending result or reveal an unsettled outcome.
Do not expose funding or transaction clients to sandboxed game code.

## Game and delivery rules

- Build the requested mechanics, including durable items, cosmetics, perks,
  upgrades and additional currencies backed by or integrated with $RAREFRIENDS.
  Gameplay upgrades do not change the runtime's NFT eligibility requirement.
- For the supplied chance-game economy, new purchases require free stake covering
  the highest prize. Every purchased consumable reserves its maximum prize.
  Pending plays and kept rewards cannot share backing; redemption has no expiry.
  Do not impose that consumable model on mechanics with no RF payout promise.
- Contracts determine paid outcomes. Animation, browser randomness and local
  balances are preview/presentation only. Claim a transaction only after a
  confirmed verified receipt.
- Canonical Friend sprites are a reference. Custom character art, animations,
  transformations, costumes and visual effects are allowed; the verified NFT
  remains the player's identity regardless of its visual representation.
- Choose controls for the genre and target devices. Movement/collision rules
  apply when the game has movement; provide mute when it has audio and reduced
  motion alternatives when effects need them. Keep controls readable, handle
  loading/errors and honor the runtime's `paused` state.
- Do not expose a signer, arbitrary calldata, deployment or bankroll withdrawal
  powers to game code.
- For vibeathon game submissions, include a public playable preview URL and its
  wallet/network requirements. GitHub Pages is allowed.
- Submit source/assets, run instructions, SDK version and applicable economy
  terms: costs, rewards, backing or RF integration, and any outcome weights or
  consumable rules. Use bigint RF base units for SDK RF actions.
- Run checks appropriate to the chosen build and game; use SDK game validation
  for CLI projects and browser checks for the actual interactions. Report
  failures honestly. Do not deploy contracts or publish to Rare Friends production
  from PR automation. Developer-controlled static preview workflows, including
  GitHub Pages, are allowed. Official production publication requires separate
  Rare Friends review.

See [the runtime guide and capability list](HOST_INTEGRATION.md). Trading,
creator fees and wearable NFTs are not implemented SDK v0.1.4 capabilities.

Contracts live in `contracts/`; read its `AGENTS.md` and `COMMANDMENTS.md` before
contract work. Reference existing mainnet RF, Generations, canonical NFT wallets
and Dice through interfaces only. Explicitly authorized developer testing may use
the interactive mainnet tools. Private keys are entered in the developer's
terminal, never in chat, source, environment files or deployment records.
