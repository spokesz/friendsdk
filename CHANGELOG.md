# Changelog

## 0.1.4

- Excluded live RF transfer, approval, signing and unused raw-transaction code from CLI
  preview bundles while retaining wallet connection and fresh ownership checks.
- Kept the live transaction path unchanged for explicit `--deployment` builds.

## 0.1.3

- Fixed owned Friend discovery on the default Robinhood RPC by starting at the
  canonical collection's first `Transfer` block and paging history reads within
  the provider's ten-million-block limit.
- Kept discovery account-filtered and verified against current balances,
  ownership, generation and canonical Friend wallets without scanning token IDs.

## 0.1.2

- Welcomed durable items, cosmetics, perks, upgrades and additional currencies
  backed by or integrated with $RAREFRIENDS, with the NFT ownership gate retained.
- Made layouts, menus, character rendering, genre-specific controls and project
  structure flexible; documented current runtime and economy limitations.
- Added optional `host.css` and CSS variables for custom runtime frame dimensions.
- Allowed SDK artwork use and modification in finished and commercial projects.

## 0.1.1

- Added `friendsdk test` and an exported automated browser harness with mock
  wallet, Robinhood RPC reads and sample sprites, usable with any game directory.
- Added a scrolling-world example and clarified that the optional renderer's
  576 × 384 plane does not limit custom worlds or cameras.
- Added supported Node build, serve and testing exports, plus game-directory
  validation through `friendsdk check`.
- Documented toolbar placement, small-screen sizing, session-only simulated
  state and the archive install → init → run → build → check workflow.
- Licensed source code under Apache-2.0, with artwork permissions documented
  separately in `NOTICE.md`.
- Fixed validation of SDK asset imports in generated starter games.
- Added Robinhood network switching and distinct wallet, discovery-error and
  empty-result states, including a count of hidden generation-0 Friends.
- Explicitly allowed public playable previews on GitHub Pages, including the
  bundled runtime and SDK artwork, without separate Rare Friends approval.
- Added a non-SDK vibeathon submission path, playable-preview guidance and
  Telegram support links for builders.
- Fixed the custom-artwork validation fixture used by CI.

Playable previews still require a wallet owning an eligible Friend on Robinhood.
Purchases and rewards remain simulated by default. The SDK is distributed as a
package archive; publication to the npm registry is not planned.
