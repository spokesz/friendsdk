# Changelog

## 0.2.2

- Custody sign-in: with `CUSTODY_CONTRACT` and `CUSTODY_TICKET_SIGNER` set, Nakama also
  signs in the wallet named by a grant service's signed custody ticket for a Friend the
  custody contract holds, unless custody has bound it on chain to another wallet.
  `ConnectedGameHost` accepts `custody`, `createNakamaGameBackend` accepts `custodyTicket`,
  and `readGenerationEligibility` accepts a custody address and reports `custodied`.
  Without the variables, sign-in is unchanged.

## 0.2.1

- `FriendIdentity.generation`: rules receive the Friend's generation as read on chain when
  the session signed in. The Nakama hook already performed that read; it now keeps the value
  in the session vars, so a promotion shows on the next sign-in. Local preview backends use
  generation 1.

## 0.2.0

- Added the game server: `server.ts` rules defined with `defineFriendGameServer`,
  called from games through `client.rpc`, with Friend-scoped storage. The same
  rules run in the browser for previews and tests and on Nakama in production.
- Added wallet sign-in for Nakama: the wallet signs one login message per hour
  that covers every Friend it holds, and the bundled `beforeAuthenticateCustom`
  hook verifies the signature and the named Friend's current Generations
  ownership on chain before issuing a session for that Friend.
- `friendsdk build` writes `server.js` for Nakama when a game has `server.ts`;
  `dev` and `build` read `NAKAMA_HOST`, `NAKAMA_PORT`, `NAKAMA_SSL` and
  `NAKAMA_SERVER_KEY`; `check` compiles the server module.
- `GameHost` and `ConnectedGameHost` accept `server` and `backend`; the bridge
  accepts `rpc`; the starter includes a one-rule server.

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
