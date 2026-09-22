import test from 'node:test';
import assert from 'node:assert/strict';
import { privateKeyToAccount } from 'viem/accounts';
import { defineFriendGameServer, createLocalGameBackend, FriendRpcError, friendCustomId, walletLoginMessage, parseWalletLogin } from '../dist/server/index.js';
import { verifyFriendLogin, recoverSigner, callFriendRpc, beforeAuthenticateCustom, setKnownGames } from '../dist/server/nakama.js';
import { createNakamaGameBackend } from '../dist/nakama-client.js';
import { bindGameFrame, createFrameGameClient } from '../dist/frame-bridge.js';
import { createGamePreview, RF } from '../dist/game.js';

const contract = '0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D';
const friend = { chainId: 4663, contract, tokenId: '7730' };
const owner = privateKeyToAccount(`0x${'11'.repeat(32)}`);
const identity = { ...friend, contract: contract.toLowerCase(), controller: owner.address.toLowerCase() };
const counter = defineFriendGameServer({ id: 'counter', rpcs: {
  load(ctx) { return ctx.storage.get('state')?.value ?? { count: 0 }; },
  add(ctx, payload) {
    if (typeof payload?.by !== 'number' || payload.by < 1) throw new FriendRpcError('Add at least 1.');
    const record = ctx.storage.get('state');
    const state = { count: (record?.value.count ?? 0) + payload.by, controller: ctx.friend.controller };
    ctx.storage.put('state', state, record?.version ?? '*');
    return state;
  },
  boom() { throw new Error('secret internal detail'); },
  activity(ctx) { return ctx.activity(); },
} });

test('a local game backend keeps state per Friend and exposes only rule errors', async () => {
  const backend = createLocalGameBackend(counter, identity);
  assert.deepEqual(await backend.rpc('load', null), { count: 0 });
  assert.deepEqual(await backend.rpc('add', { by: 2 }), { count: 2, controller: identity.controller });
  assert.deepEqual(await backend.rpc('add', { by: 3 }), { count: 5, controller: identity.controller });
  await assert.rejects(backend.rpc('add', { by: 0 }), /Add at least 1/);
  await assert.rejects(backend.rpc('missing', null), /Unknown game action/);
  const activity = await backend.rpc('activity', null);
  assert.deepEqual(Object.keys(activity), ['counter']);
  assert(Date.now() - activity.counter < 5_000, 'Activity is the last write time');
  assert.deepEqual(await createLocalGameBackend(counter, { ...identity, tokenId: '2' }).rpc('activity', null), {}, 'No writes, no activity');
  assert.deepEqual(await createLocalGameBackend(counter, { ...identity, tokenId: '1' }).rpc('load', null), { count: 0 });
});

test('game server ids and rpc names are validated', () => {
  assert.throws(() => defineFriendGameServer({ id: 'Bad Id', rpcs: {} }), /game server id/);
  assert.throws(() => defineFriendGameServer({ id: 'ok', rpcs: { 'eth_send': () => 1 } }), /Invalid game RPC/);
  assert.throws(() => defineFriendGameServer({ id: 'ok', rpcs: { load: 1 } }), /Invalid game RPC/);
});

test('the bridge routes rpc calls to the game backend without a wallet confirmation', async () => {
  const definition = { name: 'Test', consumable: 'Bait', price: RF, outcomes: [{ name: 'Fish', chanceBps: 10000, reward: 2n * RF }] };
  const { port1, port2 } = new MessageChannel();
  const preview = createGamePreview(definition, { stake: 10n * RF, rfBalance: 20n * RF, friendId: 7730n });
  const errors = [];
  const host = bindGameFrame(port1, { client: preview.client, authorize: async () => { throw new Error('rpc must not prompt'); },
    backend: createLocalGameBackend(counter, identity), onError: error => errors.push(error.message) });
  const frame = createFrameGameClient(port2, definition);
  try {
    assert.deepEqual(await frame.client.rpc('add', { by: 4 }), { count: 4, controller: identity.controller });
    assert.deepEqual(await frame.client.rpc('load'), { count: 4, controller: identity.controller });
    await assert.rejects(frame.client.rpc('add', { by: 0 }), /Add at least 1/);
    await assert.rejects(frame.client.rpc('boom'), /Game server request failed/);
    assert.deepEqual(errors, ['Add at least 1.', 'secret internal detail'], 'Internal detail stays with the trusted host');
    for (const [name, payload] of [['eth_send', {}], ['load', { amount: 1n }], ['a'.repeat(40), null]]) {
      await assert.rejects(frame.client.rpc(name, payload), /Unsupported/);
    }
  } finally { host.close(); frame.close(); }
  const { port1: a, port2: b } = new MessageChannel();
  const serverless = bindGameFrame(a, { client: preview.client, authorize: async () => {} });
  const child = createFrameGameClient(b, definition);
  try { await assert.rejects(child.client.rpc('load'), /Game server request failed/); } finally { serverless.close(); child.close(); }
});

test('one wallet signature signs in every Friend the wallet owns, and nothing else', async () => {
  const expires = new Date(Date.now() + 60_000).toISOString();
  const message = walletLoginMessage({ account: owner.address, expires });
  const signature = await owner.signMessage({ message });
  assert.deepEqual(parseWalletLogin(message), { account: owner.address.toLowerCase(), expires });
  assert.equal(recoverSigner(message, signature), owner.address.toLowerCase());
  const owned = new Set(['7730', '41']);
  const read = (address, tokenId) => { assert.equal(address, contract.toLowerCase()); return { owner: owned.has(tokenId) ? owner.address : `0x${'22'.repeat(20)}`, generation: 1 }; };
  const base = { customId: friendCustomId(friend), message, signature, now: Date.now(), generations: contract, read };
  assert.deepEqual(verifyFriendLogin(base), identity);
  assert.deepEqual(verifyFriendLogin({ ...base, customId: friendCustomId({ ...friend, tokenId: '41' }) }), { ...identity, tokenId: '41' }, 'The same signature signs in another owned Friend');
  assert.throws(() => verifyFriendLogin({ ...base, customId: friendCustomId({ ...friend, tokenId: '1' }) }), /does not own/);
  assert.throws(() => verifyFriendLogin({ ...base, customId: 'rf:4663:nope:7730' }), /Unrecognized Friend account/);
  assert.throws(() => verifyFriendLogin({ ...base, now: Date.parse(expires) }), /expired/);
  assert.throws(() => verifyFriendLogin({ ...base, message: message.replace(owner.address.toLowerCase(), `0x${'22'.repeat(20)}`) }), /does not match the account/);
  assert.throws(() => verifyFriendLogin({ ...base, read: () => ({ owner: owner.address, generation: 0 }) }), /not hardwired/);
  assert.throws(() => verifyFriendLogin({ ...base, generations: `0x${'33'.repeat(20)}` }), /Unknown Friend collection/);
  assert.throws(() => verifyFriendLogin({ ...base, message: 'Log in please' }), /Unrecognized sign-in/);
});

test('the Nakama hooks verify ownership on chain and scope storage to the Friend and game', async () => {
  const expires = new Date(Date.now() + 60_000).toISOString();
  const message = walletLoginMessage({ account: owner.address, expires });
  const signature = await owner.signMessage({ message });
  const calls = [];
  const nk = {
    httpRequest(url, method, headers, body) {
      const request = JSON.parse(body); calls.push([url, request.params[0].to]);
      const ownerOf = request.params[0].data.startsWith('0x6352211e');
      assert.equal(request.params[0].data.slice(10), (7730n).toString(16).padStart(64, '0'));
      return { code: 200, body: JSON.stringify({ jsonrpc: '2.0', id: 1, result: ownerOf ? `0x${owner.address.slice(2).toLowerCase().padStart(64, '0')}` : `0x${'1'.padStart(64, '0')}` }) };
    },
  };
  const ctx = { env: { CHAIN_RPC_URL: 'https://rpc.test' } };
  const logger = { error() {}, info() {} };
  const result = beforeAuthenticateCustom(ctx, logger, nk, { create: true, account: { id: friendCustomId(friend), vars: { message, signature } } });
  assert.deepEqual(result, { create: true, username: 'rf-4663-7730', account: { id: friendCustomId(friend),
    vars: { controller: owner.address.toLowerCase(), chainId: '4663', contract: contract.toLowerCase(), tokenId: '7730' } } });
  assert.deepEqual(calls, [['https://rpc.test', contract.toLowerCase()], ['https://rpc.test', contract.toLowerCase()]]);
  assert.throws(() => beforeAuthenticateCustom(ctx, logger, nk, { create: true, account: { id: friendCustomId(friend), vars: { message, signature: `0x${'00'.repeat(65)}` } } }), { code: 16 });

  const store = new Map();
  let revision = 0;
  const storageNk = {
    storageRead(keys) { return keys.flatMap(({ collection, key, userId }) => { const record = store.get(`${collection}/${userId}/${key}`); return record ? [{ collection, key, userId, ...record }] : []; }) },
    storageList(userId, collection) {
      assert(collection, 'Nakama lists one collection at a time');
      return { objects: [...store.entries()].filter(([id]) => id.startsWith(`${collection}/${userId}/`)).map(([id, record]) => ({ collection, key: id.split('/')[2], userId, ...record })) };
    },
    storageWrite(writes) {
      return writes.map(write => {
        const id = `${write.collection}/${write.userId}/${write.key}`, current = store.get(id);
        if (write.version === '*' ? current : write.version !== undefined && current?.version !== write.version) throw new Error('storage write rejected');
        assert.deepEqual([write.permissionRead, write.permissionWrite], [1, 0], 'Clients may read but never write game state');
        store.set(id, { value: write.value, version: String(++revision), updateTime: 1_700_000_000 + revision });
        return { key: write.key, collection: write.collection, userId: write.userId, version: String(revision) };
      });
    },
  };
  const session = { userId: 'user-1', vars: result.account.vars, env: {} };
  assert.deepEqual(JSON.parse(callFriendRpc(counter, 'add', session, logger, storageNk, JSON.stringify({ by: 5 }))), { count: 5, controller: owner.address.toLowerCase() });
  assert.deepEqual(JSON.parse(callFriendRpc(counter, 'load', session, logger, storageNk, '')), { count: 5, controller: owner.address.toLowerCase() });
  assert.deepEqual([...store.keys()], ['counter/user-1/state']);
  store.set('other-game/user-1/save', { value: {}, version: '9', updateTime: 1_700_000_500 });
  store.set('unlisted/user-1/save', { value: {}, version: '10', updateTime: 1_700_000_900 });
  setKnownGames(['counter', 'other-game']);
  assert.deepEqual(JSON.parse(callFriendRpc(counter, 'activity', session, logger, storageNk, '')), { counter: 1_700_000_001_000, 'other-game': 1_700_000_500_000 }, 'Seconds from Nakama become milliseconds, latest write per bundled game');
  assert.throws(() => callFriendRpc(counter, 'add', session, logger, storageNk, '{"by":0}'), { code: 3, message: 'Add at least 1.' });
  assert.throws(() => callFriendRpc(counter, 'boom', session, logger, storageNk, ''), { code: 13, message: 'Game server error.' });
  assert.throws(() => callFriendRpc(counter, 'load', { userId: '', vars: {}, env: {} }, logger, storageNk, ''), { code: 16 });
});

test('the host backend signs in once, forwards rpc calls with the session and retries after expiry', async () => {
  const token = exp => `h.${Buffer.from(JSON.stringify({ exp })).toString('base64url')}.s`;
  const requests = [];
  let logins = 0, signatures = 0;
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    requests.push([String(url), init.headers.Authorization]);
    if (String(url).includes('/v2/account/authenticate/custom')) {
      logins++;
      const body = JSON.parse(init.body);
      assert.equal(init.headers.Authorization, `Basic ${btoa('defaultkey:')}`);
      assert.equal(body.id, friendCustomId(logins < 3 ? friend : { ...friend, tokenId: '41' }));
      assert.equal(parseWalletLogin(body.vars.message)?.account, owner.address.toLowerCase());
      assert.equal(body.vars.signature, 'signed');
      return new Response(JSON.stringify({ token: token(Math.floor(Date.now() / 1000) + (logins === 1 ? 5 : 900)) }), { status: 200 });
    }
    assert.equal(String(url), 'http://127.0.0.1:7350/v2/rpc/counter.add?unwrap');
    if (init.headers.Authorization === `Bearer ${token(Math.floor(Date.now() / 1000) + 5)}`) return new Response('{"message":"stale"}', { status: 401 });
    const payload = JSON.parse(init.body);
    if (payload.by === 0) return new Response(JSON.stringify({ code: 3, message: 'Add at least 1.' }), { status: 400 });
    if (payload.by === 99) return new Response(JSON.stringify({ code: 13, message: 'internal' }), { status: 500 });
    return new Response(JSON.stringify({ count: payload.by }), { status: 200 });
  };
  try {
    const backend = createNakamaGameBackend({ backend: { host: '127.0.0.1', port: 7350, useSSL: false, serverKey: 'defaultkey' }, gameId: 'counter', friend,
      account: owner.address, signMessage: async () => { signatures++; return 'signed'; } });
    assert.deepEqual(await backend.rpc('add', { by: 2 }), { count: 2 });
    await assert.rejects(backend.rpc('add', { by: 0 }), error => error.name === 'FriendRpcError' && error.message === 'Add at least 1.');
    await assert.rejects(backend.rpc('add', { by: 99 }), error => error.name !== 'FriendRpcError' && error.message === 'internal');
    assert.equal(logins, 2, 'A token about to expire is replaced before the next call');
    assert.equal(signatures, 1, 'The wallet signs one message per session');
    backend.close();
    await assert.rejects(backend.rpc('add', { by: 1 }), /session changed/);
    const other = createNakamaGameBackend({ backend: { host: '127.0.0.1', port: 7350, useSSL: false, serverKey: 'defaultkey' }, gameId: 'counter', friend: { ...friend, tokenId: '41' },
      account: owner.address, signMessage: async () => { signatures++; return 'signed'; } });
    assert.deepEqual(await other.rpc('add', { by: 3 }), { count: 3 });
    assert.equal([logins, signatures].join(), '3,1', 'Switching to another Friend of the same wallet signs in again without a new signature');
    other.close();
  } finally { globalThis.fetch = original; }
});
