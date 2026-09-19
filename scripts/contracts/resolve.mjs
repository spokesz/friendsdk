import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { formatEther, parseEventLogs } from 'viem';
import { MAINNET, ENTROPY_ABI, GENERATIONS_ABI, equal, uint, ask, signingClients, loadManifest,
  artifact, verifyGame, sendContract, validateArgs, reportError } from './common.mjs';

const DICE_ERRORS = ENTROPY_ABI.filter(entry => entry.type === 'error');
const VERIFY_RETRY = 'Receipt succeeded but the Dice retry could not be verified.';

/** Dice reclaims only a request it never revealed, and only after its own block delay. */
async function reclaimable(client, sequenceNumber) {
  const dice = (functionName, args) => client.readContract({ address: MAINNET.entropy, abi: ENTROPY_ABI, functionName, args });
  const [request, refundDelayBlocks, currentBlock] = await Promise.all([
    dice('getRequestV2', [MAINNET.provider, sequenceNumber]), dice('getRefundDelayBlocks'), client.getBlockNumber(),
  ]);
  // Dice clears a reclaimed request by zeroing its sequence number, and status 1 is "not
  // started", so a word Dice already revealed is never reclaimed and never re-requested.
  const active = request.sequenceNumber === sequenceNumber && request.callbackStatus === 1;
  return { requestBlock: request.blockNumber, refundDelayBlocks, currentBlock, reclaim: request.feePaid,
    ready: active && currentBlock >= request.blockNumber + refundDelayBlocks,
    reason: active
      ? `Dice cannot reclaim this request before block ${request.blockNumber + refundDelayBlocks}.`
      : 'Dice has no unrevealed request for this play group; its result is already on the way or delivered.' };
}

function revertReason(error) {
  const reverted = typeof error?.walk === 'function' ? error.walk(entry => entry?.name === 'ContractFunctionRevertedError') : undefined;
  return reverted?.data?.errorName ?? error?.shortMessage ?? error?.message ?? 'The retry would fail.';
}

/** One committed play; reruns observe the existing request/result instead of buying a new draw. */
export async function resolvePlay({ client, wallet, account, abi, manifest, playId,
  onHash = hash => console.log(`Submitted: ${hash}`), waitMs = 120_000,
  maxOracleFee,
  retryStuck = async () => false,
  sleep = ms => new Promise(done => setTimeout(done, ms)) }) {
  const game = await verifyGame(client, abi, manifest);
  const read = (functionName, args) => client.readContract({ address: game, abi, functionName, args });
  const quoteFee = async () => {
    const fee = await client.readContract({ address: MAINNET.entropy, abi: ENTROPY_ABI,
      functionName: 'getFeeV2', args: [MAINNET.provider, 200_000] });
    if (maxOracleFee !== undefined && fee > maxOracleFee) throw new Error('Dice fee increased since confirmation. Review the new fee before retrying.');
    return fee;
  };
  let [friendId, batchId, outcomeId] = await read('plays', [playId]);
  if (batchId === 0n) throw new Error('Unknown play ID.');
  if (outcomeId !== 0n) return { playId, friendId, batchId, outcomeId, alreadySettled: true };
  let randomness = await read('randomness', [batchId]);
  if (!randomness[1]) {
    await sendContract({ client, wallet, account, address: game, abi, functionName: 'requestRandomness',
      args: [batchId], value: await quoteFee(), onHash });
    randomness = await read('randomness', [batchId]);
    if (!randomness[1]) throw new Error('Receipt succeeded but the Dice request could not be verified.');
  }
  const waitForWord = async () => {
    const deadline = Date.now() + waitMs;
    while (!randomness[2] && Date.now() < deadline) {
      await sleep(Math.min(5000, Math.max(0, deadline - Date.now())));
      randomness = await read('randomness', [batchId]);
    }
    return randomness[2];
  };
  let retried;
  if (!await waitForWord()) {
    const stale = randomness[0];
    const dice = await reclaimable(client, stale);
    const stuck = { playId, friendId, batchId, pending: true, sequenceNumber: stale,
      requestBlock: dice.requestBlock, refundDelayBlocks: dice.refundDelayBlocks };
    if (!dice.ready) return { ...stuck, retryAvailable: false, reason: dice.reason };
    // The owner signs a retry directly; this command never routes one through the wallet.
    const owner = await client.readContract({ address: MAINNET.generations, abi: GENERATIONS_ABI, functionName: 'ownerOf', args: [friendId] });
    if (!equal(owner, account.address)) return { ...stuck, retryAvailable: false, reason: `Only the Friend owner ${owner} can retry this request.` };
    const fee = await quoteFee();
    try {
      await client.simulateContract({ account, address: game, abi: [...abi, ...DICE_ERRORS],
        functionName: 'retryRandomness', args: [batchId], value: fee });
    } catch (error) {
      return { ...stuck, retryAvailable: false, reason: revertReason(error) };
    }
    if (!await retryStuck({ playId, friendId, batchId, staleSequence: stale, fee, reclaim: dice.reclaim,
      requestBlock: dice.requestBlock, currentBlock: dice.currentBlock })) {
      return { ...stuck, retryAvailable: true };
    }
    const sent = await sendContract({ client, wallet, account, address: game, abi,
      functionName: 'retryRandomness', args: [batchId], value: fee, onHash });
    const [event] = parseEventLogs({ abi, eventName: 'RandomnessRetried', strict: true,
      logs: sent.logs.filter(log => equal(log.address, game)) })
      .filter(entry => entry.args.batchId === batchId && entry.args.staleSequence === stale && entry.args.sequenceNumber !== stale);
    if (!event) throw new Error(VERIFY_RETRY);
    // Read in the retry transaction's own block; no delivery can have landed there yet.
    const bound = await client.readContract({ address: game, abi, functionName: 'randomness', args: [batchId], blockNumber: sent.blockNumber });
    if (!bound[1] || bound[2] || bound[0] !== event.args.sequenceNumber) throw new Error(VERIFY_RETRY);
    retried = sent.transactionHash;
    randomness = await read('randomness', [batchId]);
    if (!await waitForWord()) return { playId, friendId, batchId, pending: true, sequenceNumber: randomness[0], retried };
  }
  // Another caller may settle while Dice is fulfilling; this is the same immutable draw.
  [, , outcomeId] = await read('plays', [playId]);
  if (outcomeId !== 0n) return { playId, friendId, batchId, outcomeId, alreadySettled: true, retried };
  const confirmed = await sendContract({ client, wallet, account, address: game, abi,
    functionName: 'settle', args: [playId], onHash });
  const result = await client.readContract({ address: game, abi, functionName: 'plays', args: [playId], blockNumber: confirmed.blockNumber });
  if (result[0] !== friendId || result[1] !== batchId || result[2] === 0n) throw new Error('Receipt succeeded but the settled play could not be verified.');
  return { playId, friendId, batchId, outcomeId: result[2], transactionHash: confirmed.transactionHash, retried };
}

async function main(args) {
  validateArgs(args);
  if (args.length !== 2 || args.some(arg => arg.startsWith('--'))) throw new Error('Usage: npm run resolve:contracts -- manifest.json playId');
  const manifest = await loadManifest(resolve(args[0]));
  const playId = uint(args[1], 'Play ID');
  const { abi } = await artifact();
  const { client, wallet, account } = await signingClients();
  const game = await verifyGame(client, abi, manifest);
  const [friendId, batchId, outcomeId] = await client.readContract({ address: game, abi, functionName: 'plays', args: [playId] });
  if (batchId === 0n) throw new Error('Unknown play ID.');
  if (outcomeId !== 0n) { console.log(`Play ${playId} is already settled: outcome ${outcomeId}.`); return; }
  const [, requested] = await client.readContract({ address: game, abi, functionName: 'randomness', args: [batchId] });
  const fee = await client.readContract({ address: MAINNET.entropy, abi: ENTROPY_ABI, functionName: 'getFeeV2', args: [MAINNET.provider, 200_000] });
  console.log(`Network: Robinhood mainnet (${MAINNET.chainId})\nSigner: ${account.address}\nGame: ${game}\nFriend: ${friendId}\nPlay: ${playId}; batch: ${batchId}`);
  console.log(requested ? 'Dice request already exists; no additional oracle payment unless you choose to retry a stuck one.' : `Dice request fee now: ${formatEther(fee)} ETH. Fee is re-quoted immediately before simulation.`);
  console.log('Oracle request and settlement cost ETH gas. No new purchase, reroll, or RF payment.');
  console.log(`If Dice never reveals, its own delay lets this request be reclaimed and replaced by a new one. That retry is offered separately below and is never sent without a second confirmation.`);
  if (await ask('Type RESOLVE to sponsor Dice if needed and settle this play: ') !== 'RESOLVE') throw new Error('Cancelled before broadcasting.');
  console.log('Waiting up to two minutes for Dice fulfillment.');
  const result = await resolvePlay({ client, wallet, account, abi, manifest, playId, maxOracleFee: fee,
    retryStuck: async stuck => {
      console.log(`Dice request ${stuck.staleSequence} was made at block ${stuck.requestBlock} and never revealed; the chain is now at block ${stuck.currentBlock}.`);
      console.log(`Retrying reclaims ${formatEther(stuck.reclaim)} ETH from Dice and pays ${formatEther(stuck.fee)} ETH for a new request, both inside one transaction from ${account.address}. That ETH is Dice's fee moving, not a payout, a reward, or any change to RF.`);
      console.log(`This stays play ${stuck.playId} in batch ${stuck.batchId}, on the same bait, with one result. It is not a new play, a second chance, or better odds, and a result Dice has already delivered can never be requested again.`);
      console.log('Only the Friend owner can send it, and it costs ETH gas.');
      return await ask('Type RETRY to reclaim the stuck Dice request and send one new request: ') === 'RETRY';
    } });
  if (result.retried) console.log(`Retried the stuck Dice request: ${result.retried}. The play, its bait and its reserved backing are unchanged.`);
  if (result.pending) console.log(`Dice sequence ${result.sequenceNumber} is still pending.${result.reason ? ` ${result.reason}` : ''} Rerun this command later; the existing request will be reused. Pending backing remains reserved.`);
  else console.log(`Confirmed play ${playId}: outcome ${result.outcomeId}${result.transactionHash ? `; transaction ${result.transactionHash}` : ' (already settled)'}.`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main(process.argv.slice(2)).catch(reportError);
