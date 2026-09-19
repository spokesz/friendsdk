import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { encodeAbiParameters, encodeEventTopics, parseAbi, zeroHash } from 'viem';
import { parseChanceGame } from '../dist/game.js';
import { MAINNET, ERC20_ABI, promptSecret, validateArgs, receipt, loadManifest, saveManifest } from '../scripts/contracts/common.mjs';
import { constructorArgs, preflight, deployGame, fundDeployment } from '../scripts/contracts/deploy.mjs';
import { resolvePlay } from '../scripts/contracts/resolve.mjs';

const ACCOUNT = '0x0000000000000000000000000000000000000011';
const FRIEND = '0x0000000000000000000000000000000000000022';
const GAME = '0x0000000000000000000000000000000000000033';
const CONSUMABLE = '0x0000000000000000000000000000000000000044';
const DEPLOY_HASH = `0x${'1'.repeat(64)}`;
const BLOCK_HASH = `0x${'2'.repeat(64)}`;
const definition = parseChanceGame({ name: 'Test', consumable: 'Bait', price: '1', outcomes: [{ name: 'Fish', chanceBps: 10000, reward: '10' }] });
const gameAbi = parseAbi([
  'function rf() view returns(address)', 'function generations() view returns(address)',
  'function entropy() view returns(address)', 'function provider() view returns(address)',
  'function team() view returns(address)', 'function price() view returns(uint256)',
  'function maxPrize() view returns(uint256)', 'function consumable() view returns(address)',
  'function fund(uint256)', 'event Funded(address indexed funder,uint256 amount)',
  'function plays(uint256) view returns(uint256,uint256,uint256)',
  'function randomness(uint256) view returns(uint64,bool,bool,bytes32)',
  'function requestRandomness(uint256) payable returns(uint64)', 'function settle(uint256) returns(uint256)',
  'function retryRandomness(uint256) payable returns(uint64)',
  'event RandomnessRetried(uint256 indexed batchId,uint64 indexed staleSequence,uint64 indexed sequenceNumber,uint256 reclaimed)',
]);

function manifest() {
  return { chainId: MAINNET.chainId, rf: MAINNET.rf, generations: MAINNET.generations, entropy: MAINNET.entropy,
    provider: MAINNET.provider, deployer: ACCOUNT, game: GAME, initialStake: '10', friendId: '7', friendWallet: FRIEND,
    definition: JSON.parse(JSON.stringify(definition, (_, value) => typeof value === 'bigint' ? value.toString() : value)),
    status: 'deployed', transactions: [{ step: 'deploy', hash: DEPLOY_HASH, status: 'confirmed' }] };
}

function confirmed(hash = DEPLOY_HASH, extra = {}) {
  return { transactionHash: hash, status: 'success', blockNumber: 3n, blockHash: BLOCK_HASH,
    from: ACCOUNT, to: null, contractAddress: GAME, logs: [], ...extra };
}

function fixture(options = {}) {
  let allowance = options.allowance ?? 0n, requested = options.requested ?? false;
  let fulfilled = options.fulfilled ?? false, outcome = options.outcome ?? 0n;
  let sequence = requested ? 1n : 0n;
  const writes = [], receipts = new Map([[DEPLOY_HASH, confirmed()]]);
  const client = {
    getChainId: async () => options.chainId ?? MAINNET.chainId,
    getBlockNumber: async () => options.blockNumber ?? 3n, getBlock: async () => ({ hash: BLOCK_HASH }),
    getCode: async () => '0x1234', getBalance: async () => 1n,
    async readContract({ address, functionName, args, blockNumber }) {
      if (Object.hasOwn(MAINNET, functionName)) return MAINNET[functionName];
      const fixed = { ownerOf: ACCOUNT, generation: 1, tokenBoundAccount: FRIEND, owner: ACCOUNT,
        decimals: 18, team: ACCOUNT, price: 1n, maxPrize: 10n, consumable: CONSUMABLE,
        getFeeV2: 5n, balanceOf: 100n };
      if (functionName === 'token') return address === MAINNET.generations ? MAINNET.rf : [BigInt(MAINNET.chainId), MAINNET.generations, 7n];
      if (functionName === 'allowance') return allowance;
      if (functionName === 'plays') return [7n, args[0] === 9n ? 0n : 1n, outcome];
      // A retry cannot be delivered in its own block, so a read pinned there never is.
      if (functionName === 'randomness') return [sequence, requested, blockNumber === undefined ? fulfilled : false, zeroHash];
      if (functionName === 'getRefundDelayBlocks') return 6n;
      if (functionName === 'getRequestV2') {
        return { provider: MAINNET.provider, sequenceNumber: sequence, numHashes: 0, commitment: zeroHash,
          blockNumber: options.requestBlock ?? 3n, requester: GAME, useBlockhash: false,
          callbackStatus: options.callbackStatus ?? 1, gasLimit10k: 20, feePaid: 5n };
      }
      if (Object.hasOwn(options, functionName)) return options[functionName];
      if (Object.hasOwn(fixed, functionName)) return fixed[functionName];
      throw new Error(`Unexpected fixture read: ${functionName}`);
    },
    simulateContract: async request => ({ request, result: request.functionName === 'approve' ? true : undefined }),
    waitForTransactionReceipt: async ({ hash }) => receipts.get(hash),
  };
  const wallet = { chain: { id: MAINNET.chainId },
    async writeContract(request) {
      writes.push(request);
      const hash = `0x${String(writes.length + 3).padStart(64, '0')}`;
      let logs = [];
      if (request.functionName === 'approve') {
        allowance = request.args[1];
        logs = [{ address: MAINNET.rf, topics: encodeEventTopics({ abi: ERC20_ABI, eventName: 'Approval', args: { owner: ACCOUNT, spender: GAME } }), data: encodeAbiParameters([{ type: 'uint256' }], [allowance]) }];
      } else if (request.functionName === 'fund') {
        assert.equal(allowance, 10n); allowance = 0n;
        logs = [{ address: GAME, topics: encodeEventTopics({ abi: gameAbi, eventName: 'Funded', args: { funder: ACCOUNT } }), data: encodeAbiParameters([{ type: 'uint256' }], [10n]) }];
      } else if (request.functionName === 'requestRandomness') { requested = true; sequence = 1n; fulfilled = options.fulfillOnRequest ?? true; }
      else if (request.functionName === 'retryRandomness') {
        sequence = 2n; fulfilled = options.fulfillOnRetry ?? false;
        logs = [{ address: GAME, topics: encodeEventTopics({ abi: gameAbi, eventName: 'RandomnessRetried', args: { batchId: 1n, staleSequence: 1n, sequenceNumber: 2n } }), data: encodeAbiParameters([{ type: 'uint256' }], [5n]) }];
      }
      else if (request.functionName === 'settle') outcome = 1n;
      receipts.set(hash, confirmed(hash, { to: request.address, contractAddress: null, logs: options.missingLogs ? [] : logs,
        status: options.reverted ? 'reverted' : 'success' }));
      return hash;
    },
  };
  return { client, wallet, account: { address: ACCOUNT }, abi: gameAbi, manifest: manifest(), writes, receipts, save: async () => {} };
}

test('hidden key input never echoes, restores terminal mode, and rejects non-TTY input', async () => {
  const input = new PassThrough(), output = new PassThrough();
  const modes = []; let visible = '';
  input.isTTY = true; output.isTTY = true; input.setRawMode = raw => modes.push(raw);
  output.on('data', chunk => { visible += chunk; });
  const key = 'a'.repeat(64);
  const pending = promptSecret(input, output);
  input.write(`${key}\r`);
  assert.equal(await pending, key);
  assert.ok(!visible.includes(key)); assert.deepEqual(modes, [true, false]);
  assert.throws(() => promptSecret(new PassThrough(), output), /interactive terminal/);
});

test('key cancellation restores raw mode and arguments cannot supply a secret', async () => {
  const input = new PassThrough(), output = new PassThrough();
  const modes = [];
  input.isTTY = output.isTTY = true; input.setRawMode = raw => modes.push(raw);
  const pending = promptSecret(input, output); input.write('private\u0003');
  await assert.rejects(pending, /Cancelled/); assert.deepEqual(modes, [true, false]);
  assert.throws(() => validateArgs([`0x${'a'.repeat(64)}`]), /hidden terminal/);
  assert.throws(() => validateArgs(['--private-key']), /hidden terminal/);
  assert.doesNotThrow(() => validateArgs([`contracts/deployments/4663-${DEPLOY_HASH}.json`]));
});

test('constructor encodes only existing dependencies and JSON outcome metadata', () => {
  const args = constructorArgs(definition);
  assert.equal(args.length, 8); assert.deepEqual(args.slice(0, 4), [MAINNET.rf, MAINNET.generations, MAINNET.entropy, MAINNET.provider]);
  assert.equal(args[4], 'Bait'); assert.equal(args[5], 'Bait');
  const metadata = JSON.parse(Buffer.from(args[7][0].metadataURI.split(',')[1], 'base64').toString());
  assert.equal(metadata.name, 'Fish'); assert.ok(!('image' in metadata));
});

test('deployment preflight rejects the wrong chain, NFT owner, RF stake and wallet binding', async () => {
  assert.equal((await preflight(fixture().client, ACCOUNT, 7n, 10n)).friendWallet, FRIEND);
  await assert.rejects(preflight(fixture({ chainId: 1 }).client, ACCOUNT, 7n, 10n), /chain 4663/);
  await assert.rejects(preflight(fixture({ ownerOf: FRIEND }).client, ACCOUNT, 7n, 10n), /must own/);
  await assert.rejects(preflight(fixture({ generation: 0 }).client, ACCOUNT, 7n, 10n), /hardwired/);
  await assert.rejects(preflight(fixture({ balanceOf: 1n }).client, ACCOUNT, 7n, 10n), /initial game stake/);
  await assert.rejects(preflight(fixture().client, ACCOUNT, 8n, 10n), /NFT binding/);
});

test('receipts reject failures, replacements, wrong chains and reorganizations', async () => {
  const base = fixture().client;
  await assert.rejects(receipt({ ...base, waitForTransactionReceipt: async () => confirmed(DEPLOY_HASH, { status: 'reverted' }) }, DEPLOY_HASH), /reverted/);
  await assert.rejects(receipt({ ...base, waitForTransactionReceipt: async () => confirmed(zeroHash) }, DEPLOY_HASH), /replaced/);
  await assert.rejects(receipt(fixture({ chainId: 1 }).client, DEPLOY_HASH), /chain 4663/);
  await assert.rejects(receipt({ ...base, getBlock: async () => ({ hash: zeroHash }) }, DEPLOY_HASH), /reorganized/);
});

test('confirmed deployment is saved independently of funding without serializing signer secrets', async () => {
  const f = fixture(), saved = [];
  f.wallet.deployContract = async () => DEPLOY_HASH;
  const result = await deployGame({ ...f, account: { address: ACCOUNT, privateKey: 'never serialize' }, definition,
    built: { abi: gameAbi, bytecode: { object: '0x1234' } }, friend: { friendId: 7n, friendWallet: FRIEND }, initialStake: 10n,
    save: async value => saved.push(JSON.parse(JSON.stringify(value))) });
  assert.equal(saved[0].status, 'deploying'); assert.equal(saved[0].transactions[0].hash, DEPLOY_HASH);
  assert.equal(result.game, GAME); assert.equal(result.status, 'deployed');
  assert.ok(!JSON.stringify(saved).includes('never serialize')); assert.equal(f.writes.length, 0);
});

test('funding uses exact approval and verifies both receipts; resume never funds twice', async () => {
  const f = fixture();
  await fundDeployment(f);
  assert.deepEqual(f.writes.map(write => write.functionName), ['approve', 'fund']);
  assert.deepEqual(f.writes[0].args, [GAME, 10n]); assert.equal(f.manifest.status, 'funded');
  await fundDeployment(f); assert.equal(f.writes.length, 2);
});

test('a prior successful approval is repeated when the current allowance no longer matches', async () => {
  const f = fixture();
  f.manifest.transactions.push({ step: 'approval', hash: zeroHash, status: 'confirmed' });
  await fundDeployment(f);
  assert.deepEqual(f.writes.map(write => write.functionName), ['approve', 'fund']);
});

test('funding does not claim success for missing events or a reverted approval', async () => {
  const noEvent = fixture({ missingLogs: true });
  await assert.rejects(fundDeployment(noEvent), /Approval event/);
  assert.equal(noEvent.manifest.status, 'deployed'); assert.equal(noEvent.writes.length, 1);
  const reverted = fixture({ reverted: true });
  await assert.rejects(fundDeployment(reverted), /reverted/);
  assert.equal(reverted.manifest.transactions[1].status, 'submitted'); assert.equal(reverted.writes.length, 1);
});

test('resolver requests Dice once, settles the committed play, and reuses a settled result', async () => {
  const f = fixture();
  const result = await resolvePlay({ ...f, playId: 1n, waitMs: 0, onHash() {} });
  assert.equal(result.outcomeId, 1n);
  assert.deepEqual(f.writes.map(write => write.functionName), ['requestRandomness', 'settle']);
  assert.equal(f.writes[0].value, 5n);
  assert.equal((await resolvePlay({ ...f, playId: 1n })).alreadySettled, true);
  assert.equal(f.writes.length, 2);
});

test('resolver keeps an unfulfilled request pending without paying again or inventing an outcome', async () => {
  const f = fixture({ requested: true });
  const result = await resolvePlay({ ...f, playId: 1n, waitMs: 0 });
  assert.equal(result.pending, true); assert.equal(result.outcomeId, undefined); assert.equal(f.writes.length, 0);
  await assert.rejects(resolvePlay({ ...f, playId: 9n, waitMs: 0 }), /Unknown play/);
});

test('resolver requires a new confirmation if the Dice fee exceeds the approved quote', async () => {
  const f = fixture();
  await assert.rejects(resolvePlay({ ...f, playId: 1n, waitMs: 0, maxOracleFee: 4n }), /fee increased/);
  assert.equal(f.writes.length, 0);
  const pending = fixture({ requested: true });
  assert.equal((await resolvePlay({ ...pending, playId: 1n, waitMs: 0, maxOracleFee: 0n })).pending, true);
  assert.equal(pending.writes.length, 0);
});

test('resolver offers a retry only when Dice can reclaim, pays the quoted fee once, verifies the new request, and never retries a revealed or fulfilled request', async () => {
  const ready = { requested: true, blockNumber: 9n };
  const early = fixture({ requested: true });
  const notYet = await resolvePlay({ ...early, playId: 1n, waitMs: 0, retryStuck: async () => true });
  assert.equal(notYet.retryAvailable, false);
  assert.match(notYet.reason, /before block 9/);
  assert.equal(early.writes.length, 0);

  const declined = fixture(ready);
  const offered = await resolvePlay({ ...declined, playId: 1n, waitMs: 0, retryStuck: async () => false });
  assert.equal(offered.retryAvailable, true);
  assert.equal(offered.retried, undefined);
  assert.equal(declined.writes.length, 0);

  const accepted = fixture(ready);
  const details = [];
  const retried = await resolvePlay({ ...accepted, playId: 1n, waitMs: 0, onHash() {},
    retryStuck: async stuck => { details.push(stuck); return true; } });
  assert.deepEqual(accepted.writes.map(write => write.functionName), ['retryRandomness']);
  assert.equal(accepted.writes[0].value, 5n);
  assert.deepEqual([details[0].staleSequence, details[0].fee, details[0].reclaim, details[0].batchId], [1n, 5n, 5n, 1n]);
  assert.equal(retried.pending, true);
  assert.equal(retried.sequenceNumber, 2n);
  assert.ok(retried.retried);

  const delivered = fixture({ ...ready, fulfillOnRetry: true });
  const settled = await resolvePlay({ ...delivered, playId: 1n, waitMs: 0, onHash() {}, retryStuck: async () => true });
  assert.deepEqual(delivered.writes.map(write => write.functionName), ['retryRandomness', 'settle']);
  assert.equal(settled.outcomeId, 1n);
  assert.ok(settled.retried);

  const unverified = fixture({ ...ready, missingLogs: true });
  await assert.rejects(resolvePlay({ ...unverified, playId: 1n, waitMs: 0, onHash() {}, retryStuck: async () => true }), /retry could not be verified/);

  // A revealed word and a delivered result are both final; neither is ever re-requested.
  for (const options of [{ ...ready, callbackStatus: 3 }, { ...ready, fulfilled: true }]) {
    const refused = fixture(options);
    let asked = false;
    await resolvePlay({ ...refused, playId: 1n, waitMs: 0, onHash() {},
      retryStuck: async () => { asked = true; return true; } });
    assert.equal(asked, false);
    assert.ok(!refused.writes.some(write => write.functionName === 'retryRandomness'));
  }

  const notOwner = fixture({ ...ready, ownerOf: FRIEND });
  const foreign = await resolvePlay({ ...notOwner, playId: 1n, waitMs: 0, retryStuck: async () => true });
  assert.equal(foreign.retryAvailable, false);
  assert.match(foreign.reason, /Friend owner/);
  assert.equal(notOwner.writes.length, 0);

  const raised = fixture(ready);
  await assert.rejects(resolvePlay({ ...raised, playId: 1n, waitMs: 0, maxOracleFee: 4n,
    retryStuck: async () => { throw new Error('offered before the fee was checked'); } }), /fee increased/);
  assert.equal(raised.writes.length, 0);
});

test('manifest persists exact base-unit strings with restricted permissions and rejects substituted deployments', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'friendsdk-cli-'));
  try {
    const file = join(dir, 'deployment.json');
    await saveManifest(file, manifest());
    assert.equal((await stat(file)).mode & 0o777, 0o600);
    assert.equal((await loadManifest(file)).initialStake, '10');
    assert.ok(!(await readFile(file, 'utf8')).includes('privateKey'));
    await saveManifest(file, { ...manifest(), rf: GAME });
    await assert.rejects(loadManifest(file), /unexpected rf/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
