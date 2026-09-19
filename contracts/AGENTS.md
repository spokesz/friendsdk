# Standalone FriendSDK contracts

Read [COMMANDMENTS.md](COMMANDMENTS.md) and the repository's v1 game rules before changing Solidity. The commandments' Genesis-specific storage list and owner methods describe that deployed contract; this package implements new game contracts only. Apply their house style and minimal-scope rules here.

- Keep only the game, its bound consumable, external-call interfaces, and their tests. No original Rare Friends protocol implementation belongs in this package. Test doubles belong in `test/` only.
- RF, Generations, its canonical NFT wallet, and Dice Protocol are existing mainnet dependencies. Do not redeploy or modify them.
- The user explicitly authorized developer deployment for mainnet development. The deploying developer manages this game's free stake. This supersedes the earlier team-only deployment workflow for the standalone package; it does not authorize integration with the production web app.
- Preserve canonical-wallet payment, maximum-prize reserves, permanent rewards, immutable terms, and nontransferable game inventory. Only free stake may be withdrawn.
- Use Dice's explicit `requestV2(provider, userRandomNumber, gasLimit)` interface. Authenticate callbacks. Never reroll a delivered result, and never send a second request while one is active. A play group may get a new request only after Dice has cleared an unrevealed one through its own refund, triggered by the Friend controller. Do not add cancellation, fallback entropy, or mutable provider selection.
- Deployment tooling prompts for a private key locally without echo. Never store it or pass it through shell arguments, environment variables, manifests, or logs.
- Build and test locally; a mainnet fork is a local test. Do not broadcast a deployment or test transaction as part of automated checks.
