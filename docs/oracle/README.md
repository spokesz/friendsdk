# Oracle operations and recovery

FriendSDK v0.1.4 uses Dice for paid chance-game outcomes. Simulated games do not
request oracle delivery. The browser runtime handles the normal request and
settlement flow; these notes cover developer operations on a committed play.

## Implemented flow

`play` commits one or more play IDs as a group. The group's first play ID is its
`batchId`. A group receives one Dice request, and each play settles once.

1. A sponsor calls `requestRandomness(batchId)` with the exact current fee from
   `Dice.getFeeV2(provider, 200000)`. The game forwards it through
   `requestV2(provider, userRandomNumber, 200000)`.
2. Dice calls `_entropyCallback(sequenceNumber, provider, randomNumber)`. Only
   the pinned oracle and provider can fulfill a known request, once. The callback
   records the word without minting rewards.
3. Anyone can call `settle(playId)`. The game derives its outcome from Dice's
   word, game address, chain ID, batch ID and play ID, then mints the reward into
   its canonical Friend wallet. Verified receipts and contract state establish
   the result before the game reveals it.

The browser's **Resume cast** continues an existing play. If a request already
exists, it is reused without another oracle payment or another consumable.
The browser waits up to 30 seconds per settlement attempt and reports a pending
result if delivery has not arrived. Request and settlement transactions cost gas.

## Resolve a committed play from the terminal

Use the SDK root with the [contract tools and build](../../contracts/README.md#deploy-and-run-a-game)
available. The deployment command creates this build and prints its manifest
path. Replace the manifest path and `PLAY_ID` below with your saved values. The
command runs in your Linux or Ubuntu/WSL terminal:

```sh
npm run resolve:contracts -- contracts/deployments/YOUR_DEPLOYMENT.json PLAY_ID
```

Enter the paying account's private key at the hidden terminal prompt. Keep keys
out of commands, source, environment files and deployment manifests. Review the
network, contract, play, quoted fee and gas requirements, then type `RESOLVE` to
authorize the request and settlement transactions. The account needs ETH for gas
and, when no request exists, the quoted Dice fee.

The command requests randomness only if the group has no request. It waits up to
two minutes for delivery and settles when the word is available. It reports an
already settled play without purchasing or drawing again. If delivery remains
pending, rerun the same command later with the same play ID. A pending status
does not confirm a reward.

Pending plays retain their maximum-prize RF backing. Kept rewards retain their
fixed RF value without expiry. Requesting or resuming oracle delivery does not
buy bait, change a play ID or withdraw that backing.

## Implemented limits and proposed recovery

Dice's provider can delay or withhold delivery. The deployed game exposes no
oracle-fee refund, play cancellation, replacement request, fallback randomness
or provider change. Rerunning the resolver observes the existing request; it
cannot replace an unrevealed request.

Controller-authorized reclaim and retry are proposed contract work:

- [Recovery requirements](intent-recovery.md) define unchanged plays and backing,
  Dice's reclaim delay, and one final outcome per play.
- [Implementation and verification plan](plan-recovery.md) specifies contract,
  command-line and test changes for a future compatible deployment.

Those documents do not describe available runtime actions. Implementing them
requires a new contract deployment and its applicable authorization; they cannot
change an immutable deployment that lacks the retry function.
