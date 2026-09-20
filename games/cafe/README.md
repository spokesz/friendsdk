# Rare Friends Cafe

You run a coffee shop staffed by your Rare Friend NFT. The Friend's token ID determines barista skill, which affects drink quality and tip earnings. Five customers per shift, five menu items, real RF economy (preview mode).

> Submitted to the [Rare Friends Vibeathon 2026](https://rarefriends.com/) -- **Character Spotlight** category.

![Rare Friends Cafe screenshot](./media/screenshot.jpg)

## TL;DR

- Pick your Rare Friend as the barista -- their `tokenId` determines skill level (1-100)
- 5 customers per shift, each orders one of 5 drink types
- Brew the drink by spending the right amount of beans
- Customer satisfaction rolls via SDK chance game (preview mode, simulated)
- Friend skill adds a bonus to every tip (skill 1-100 -> +0% to +20% tip)
- Tips = simulated RF earnings; spend beans (1 RF equivalent per bean) to keep brewing

## Two ways to play

### 1. Offline demo (no wallet, no NFT, no chain) -- **recommended for first try**

**https://rocky-motivation-sussex-influence.trycloudflare.com/cafe/demo.html**

A standalone HTML preview that runs the full cafe game loop with a sample Friend (token ID 7730, skill 85, generation 1). Anyone can play -- no browser extension, no NFT, no RF. This uses the same game balance and satisfaction tier table as the SDK version, so reviewers can verify the design without setup.

### 2. Live SDK preview (Robinhood Wallet + Generations NFT + Robinhood mainnet 4663)

**https://rocky-motivation-sussex-influence.trycloudflare.com/cafe/** (or `./game.html`)

The SDK v0.1.2 preview deployment reads your Friend data from Robinhood mainnet (chainId 4663) via the SDK's hardwired NFT ownership gate. To play, you must:

1. Install [Robinhood Wallet](https://robinhood.com/us/en/crypto/wallet/) browser extension, **and**
2. Hold at least one **Generations NFT (generation 1+)** in the connected wallet, **and**
3. Switch your wallet network to **Robinhood mainnet (chainId 4663)**.

> **Important correction:** preview mode still requires the on-chain NFT ownership gate. The SDK reads `OwnedFriends` from chain 4663 via viem; if you have no Generations NFT on Robinhood mainnet, the picker shows "No playable Friends found." This is by design and cannot be bypassed without holding real assets.

> **HTTPS required.** The URL above is HTTPS via Cloudflare Tunnel -- necessary because Robinhood Wallet and other EIP-1193 providers only inject into secure contexts. HTTP URLs will not work for the live preview.

Preview rolls are simulated; no RF is actually spent or earned. No live contract is bound to this preview.

## Project info

| Field | Value |
|---|---|
| Project name | Rare Friends Cafe |
| Builder | wudong6120415 |
| Contact | GitHub [@wudong6120415](https://github.com/wudong6120415) |
| Category | Character Spotlight |
| Submission path | `submissions/rare-friends-cafe/` |
| **Offline demo (no wallet)** | https://rocky-motivation-sussex-influence.trycloudflare.com/cafe/demo.html |
| **Live SDK preview (wallet + NFT + chain 4663)** | https://rocky-motivation-sussex-influence.trycloudflare.com/cafe/ |
| SDK | FriendSDK v0.1.2 |
| Deadline | September 30, 2026 |

## The experience

A Rare Friend NFT is the barista of your cafe. Connect your Robinhood mainnet wallet, choose your Friend, and they appear behind the counter with a skill badge. As customers arrive one by one, you read their order, brew the right drink with the right bean count, and watch their reaction.

Each drink has a base tip and a bean cost. The SDK's chance game rolls the customer satisfaction tier (Furious -> Disappointed -> Satisfied -> Happy -> Delighted). The Friend's skill level adds a permanent bonus to every tip.

## Menu

| Drink | Beans | Base Tip | When |
|---|---|---|---|
| Espresso | 1 | 0.20 RF | Quick orders |
| Latte | 2 | 0.50 RF | Standard |
| Cappuccino | 3 | 0.80 RF | Foam art |
| Mocha | 4 | 1.50 RF | Sweet tooths |
| Daily Special | 5 | 2.50 RF | Rare occasions |

## Satisfaction tiers

| Tier | Probability | Tip Multiplier |
|---|---|---|
| Furious | 5% | 0% |
| Disappointed | 15% | 20% |
| Satisfied | 40% | 50% |
| Happy | 30% | 100% |
| Delighted | 10% | 200% |

Final tip = `baseTip * tierMultiplier * (1 + skill/500)` for the Friend's skill 1-100.

## Barista skill (from token ID)

```
skill = Number(friendId % 100n) + 1
name =
  80-100: "Master Barista"
  50-79:  "Skilled Barista"
  25-49:  "Apprentice Barista"
  1-24:   "Novice Barista"
```

Every Friend has a unique skill. The cafe tells you who they are before you start.

## Files

| File | Purpose |
|---|---|
| `index.tsx` | Main game component: HUD, customer queue, brewing, reveal |
| `game.json` | Outcome table: 5 satisfaction tiers + weights |
| `style.css` | Cafe-themed UI: warm browns, cream backgrounds, barista avatar |
| `demo.html` | Standalone offline preview (no wallet required) |
| `media/cafe-bg.jpg` | Cafe interior background (AI-generated) |
| `media/espresso.jpg` | Espresso cup art |
| `media/latte.jpg` | Latte glass art |
| `media/cappuccino.jpg` | Cappuccino cup art |
| `media/mocha.jpg` | Mocha art |
| `media/specialty.jpg` | Daily special art |
| `media/screenshot.jpg` | Composite README screenshot |

## How to run

### Prerequisites

- Linux or Ubuntu in WSL2 on Windows, or macOS
- Node.js 22+
- npm
- Git
- For the SDK preview: Robinhood mainnet (chainId 4663) wallet holding a Generations NFT (gen 1+) -- even in preview mode
- For the offline demo: just a browser

### Setup

```sh
git clone https://github.com/wudong6120415/friendsdk.git
cd friendsdk
npm ci
node scripts/dev-game.mjs init games/rare-friends-cafe
cp submissions/rare-friends-cafe/* games/rare-friends-cafe/
npm run dev:game -- games/rare-friends-cafe
```

Open the displayed URL (normally `http://localhost:4173`), connect your Robinhood Wallet, choose your Friend, and start serving.

### Controls

| Input | Action |
|---|---|
| **Open shop** button | Start a customer order |
| **Brew** button | Serve the requested drink (deducts beans, plays the chance game) |
| Tab / Menu | Open settings (toggle mute, reduced-motion, view token id) |

## Checks (expected)

- `npm run typecheck` passes
- `npm run build` passes
- `npm run dev:game` boots at `localhost:4173`
- Offline demo at `https://rocky-motivation-sussex-influence.trycloudflare.com/cafe/demo.html` (no wallet required)
- Live SDK preview at `https://rocky-motivation-sussex-influence.trycloudflare.com/cafe/`

## Known limitations

- The offline demo (`demo.html`) is a simplified client-side version of the same loop. It runs without any SDK, wallet, or chain.
- The live SDK preview (`game.html`) requires Robinhood Wallet + a Generations NFT + Robinhood mainnet (chainId 4663). **Even in preview mode, the SDK enforces the on-chain ownership gate** -- it reads `OwnedFriends` from the public RPC and shows "No playable Friends found" if you have no Generations NFT.
- I previously claimed "anyone can play" of the SDK preview -- that was wrong. The correct statement is: the **offline demo** (`demo.html`) is open to anyone; the SDK preview requires Robinhood + chain 4663 + NFT.
- Robinhood mainnet RPC may rate-limit under heavy load.
- Drink art is AI-generated and may benefit from manual refinement.
- No multi-customer queueing (one customer at a time, by design).
- Bean economy is currently fixed (no upgrade system yet); preview economy only.
- Live mode (real RF settlements) is not enabled -- production deployment requires an explicit chain deployment.

## Future work

- **Day/night cycle**: open hours 6am-10pm, peak hours = bonus tips
- **Menu expansion**: seasonal drinks, unlockable via tokens spent
- **Barista outfits**: Friend appearance changes based on tip earnings tier
- **Customer memory**: regulars remember you (NPC state)
- **Live mode**: spend real RF on beans, settle real tips via SDK Dice
- **Multi-customer queue**: serve 2-3 customers in parallel
- **Offline-mock mode**: let the SDK preview accept a "demo Friend" override for reviewers without NFT (would require upstream SDK change)

## Credits

- **FriendSDK v0.1.2** by spokesz -- runtime, chance game, wallet, container
- **MiniMax-M3** -- game design and code generation
- **MiniMax image-01** -- drink and cafe artwork
- **Rare Friends** -- theme and integration
