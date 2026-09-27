import test from 'node:test';
import assert from 'node:assert/strict';
import { createNakamaGameBackend } from '../dist/nakama-client.js';
import { parseWalletLogin, friendCustomId } from '../dist/server/login.js';

const backend = { host: 'nakama.example.test', port: 443, useSSL: true, serverKey: 'test-key' };
const friend = { chainId: 4663, contract: '0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D', tokenId: '17' };
const token = () => `e30.${btoa(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 900 }))}.signature`;
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function mockTransport(t) {
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    const path = new URL(url).pathname;
    const body = JSON.parse(init.body);
    calls.push({ path, body });
    return Response.json(path.includes('/authenticate/custom') ? { token: token() } : { ok: true });
  });
  return calls;
}

test('concurrent Friends and games share one wallet prompt and the exact signed message', async t => {
  const calls = mockTransport(t);
  const account = '0x1111111111111111111111111111111111111111';
  const signature = deferred();
  const prompts = [];
  const signMessage = message => { prompts.push(message); return signature.promise; };
  const nexus = createNakamaGameBackend({ backend, gameId: 'nexus', friend, account, signMessage });
  const game = createNakamaGameBackend({ backend, gameId: 'ethergoo', friend: { ...friend, tokenId: '18' }, account: account.toUpperCase(), signMessage });
  const reads = [nexus.rpc('read', undefined), game.rpc('read', undefined)];
  await Promise.resolve();
  assert.equal(prompts.length, 1);
  assert.equal(calls.length, 0, 'No server request starts before the wallet accepts');
  const login = parseWalletLogin(prompts[0]);
  assert.equal(login.account, account);
  assert.ok(Date.parse(login.expires) > Date.now() + (24 * 60 - 1) * 60 * 1000);
  signature.resolve('accepted-signature');
  await Promise.all(reads);
  const auth = calls.filter(call => call.path.includes('/authenticate/custom'));
  assert.equal(auth.length, 2, 'Each Friend keeps its own Nakama session');
  assert.deepEqual(auth.map(call => call.body.id), [friendCustomId(friend), friendCustomId({ ...friend, tokenId: '18' })]);
  assert.deepEqual(auth[0].body.vars, auth[1].body.vars);
  await nexus.rpc('read', undefined);
  assert.equal(prompts.length, 1);
  nexus.close(); game.close();
});

test('closing a Friend during signing preserves the shared signature for its replacement', async t => {
  const calls = mockTransport(t);
  const account = '0x2222222222222222222222222222222222222222';
  const signature = deferred();
  let prompts = 0;
  const signMessage = () => { prompts++; return signature.promise; };
  const old = createNakamaGameBackend({ backend, gameId: 'nexus', friend, account, signMessage });
  const stale = assert.rejects(old.rpc('read', undefined), /session changed/);
  await Promise.resolve();
  old.close();
  const next = createNakamaGameBackend({ backend, gameId: 'nexus', friend: { ...friend, tokenId: '19' }, account, signMessage });
  const read = next.rpc('read', undefined);
  signature.resolve('accepted-signature');
  await Promise.all([stale, read]);
  assert.equal(prompts, 1);
  assert.equal(calls.filter(call => call.path === '/v2/rpc/nexus.read').length, 1, 'Closed Friend cannot issue its game RPC');
  next.close();
});

test('rejected shared signatures send no server requests and allow one clean retry', async t => {
  const calls = mockTransport(t);
  const account = '0x3333333333333333333333333333333333333333';
  const first = deferred();
  let prompts = 0;
  const signMessage = () => ++prompts === 1 ? first.promise : Promise.resolve('retry-signature');
  const nexus = createNakamaGameBackend({ backend, gameId: 'nexus', friend, account, signMessage });
  const game = createNakamaGameBackend({ backend, gameId: 'ethergoo', friend: { ...friend, tokenId: '20' }, account, signMessage });
  const reads = Promise.allSettled([nexus.rpc('read', undefined), game.rpc('read', undefined)]);
  await Promise.resolve();
  assert.equal(prompts, 1);
  first.reject(new Error('User rejected the request'));
  const results = await reads;
  assert.ok(results.every(result => result.status === 'rejected' && /User rejected/.test(result.reason.message)));
  assert.equal(calls.length, 0);
  await Promise.all([nexus.rpc('read', undefined), game.rpc('read', undefined)]);
  assert.equal(prompts, 2);
  nexus.close(); game.close();
});

test('different wallet accounts never share a pending signature', async t => {
  mockTransport(t);
  const prompts = [];
  const first = deferred(), second = deferred();
  const a = createNakamaGameBackend({ backend, gameId: 'nexus', friend, account: '0x4444444444444444444444444444444444444444', signMessage: message => { prompts.push(message); return first.promise; } });
  const b = createNakamaGameBackend({ backend, gameId: 'nexus', friend, account: '0x5555555555555555555555555555555555555555', signMessage: message => { prompts.push(message); return second.promise; } });
  const reads = [a.rpc('read', undefined), b.rpc('read', undefined)];
  await Promise.resolve();
  assert.equal(prompts.length, 2);
  assert.notEqual(parseWalletLogin(prompts[0]).account, parseWalletLogin(prompts[1]).account);
  first.resolve('wallet-a'); second.resolve('wallet-b');
  await Promise.all(reads);
  a.close(); b.close();
});

test('a switched-away Friend waiting for a signature makes no obsolete server login', async t => {
  const calls = mockTransport(t);
  const signature = deferred();
  const old = createNakamaGameBackend({ backend, gameId: 'nexus', friend, account: '0x6666666666666666666666666666666666666666', signMessage: () => signature.promise });
  const stale = assert.rejects(old.rpc('read', undefined), /session changed/);
  await Promise.resolve();
  old.close();
  signature.resolve('accepted-signature');
  await stale;
  assert.equal(calls.length, 0);
});

test('Friend eligibility, server outages and deployment mismatch preserve wallet credentials', async t => {
  const failures = [
    [401, 'The signing account does not own this Friend.'],
    [401, 'This Friend is not hardwired.'],
    [500, 'Sign-in is unavailable. Try again.'],
    [401, 'Unrecognized sign-in message.'],
  ];
  for (const [index, [status, message]] of failures.entries()) {
    let authCalls = 0, signatures = 0;
    t.mock.method(globalThis, 'fetch', async (url) => {
      if (String(url).includes('/authenticate/custom') && ++authCalls === 1) return Response.json({ message }, { status });
      return Response.json(String(url).includes('/authenticate/custom') ? { token: token() } : { ok: true });
    });
    const options = { backend, gameId: 'nexus', friend, account: `0x${String(index + 7).padStart(40, '0')}`, signMessage: async () => { signatures++; return 'accepted-signature'; } };
    const rejected = createNakamaGameBackend(options);
    await assert.rejects(rejected.rpc('read', undefined), error => error.message === message);
    const next = createNakamaGameBackend({ ...options, friend: { ...friend, tokenId: '21' } });
    assert.deepEqual(await next.rpc('read', undefined), { ok: true });
    assert.equal(signatures, 1, `Preserve credentials after ${message}`);
    assert.equal(authCalls, 2);
    rejected.close(); next.close();
    t.mock.restoreAll();
  }
});

test('an explicitly rejected credential is replaced only on a requested retry', async t => {
  let authCalls = 0, signatures = 0;
  t.mock.method(globalThis, 'fetch', async url => {
    if (String(url).includes('/authenticate/custom') && ++authCalls === 1) return Response.json({ message: 'Invalid signature.' }, { status: 401 });
    return Response.json(String(url).includes('/authenticate/custom') ? { token: token() } : { ok: true });
  });
  const session = createNakamaGameBackend({ backend, gameId: 'nexus', friend, account: '0x7777777777777777777777777777777777777777', signMessage: async () => { signatures++; return `signature-${signatures}`; } });
  await assert.rejects(session.rpc('read', undefined), /Invalid signature/);
  assert.equal(signatures, 1);
  assert.equal(authCalls, 1, 'No automatic resign or login loop');
  assert.deepEqual(await session.rpc('read', undefined), { ok: true });
  assert.equal(signatures, 2);
  session.close();
});

test('a delayed old credential rejection cannot discard a newer wallet signature', async t => {
  let now = 1_800_000_000_000, signatures = 0, authCalls = 0;
  t.mock.method(Date, 'now', () => now);
  const oldReply = deferred();
  const stored = new Map();
  const originalStorage = Object.getOwnPropertyDescriptor(globalThis, 'sessionStorage');
  Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: { getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) } });
  t.after(() => { if (originalStorage) Object.defineProperty(globalThis, 'sessionStorage', originalStorage); else delete globalThis.sessionStorage; });
  t.mock.method(globalThis, 'fetch', async url => {
    if (String(url).includes('/authenticate/custom') && ++authCalls === 1) return oldReply.promise;
    return Response.json(String(url).includes('/authenticate/custom') ? { token: token() } : { ok: true });
  });
  const options = { backend, gameId: 'nexus', friend, account: '0x8888888888888888888888888888888888888888', signMessage: async () => { signatures++; return `signature-${signatures}`; } };
  const old = createNakamaGameBackend(options);
  const rejected = assert.rejects(old.rpc('read', undefined), /expired/);
  while (!authCalls) await Promise.resolve();
  now += 24 * 60 * 60 * 1000;
  const newer = createNakamaGameBackend({ ...options, friend: { ...friend, tokenId: '22' } });
  await newer.rpc('read', undefined);
  assert.equal(signatures, 2);
  oldReply.resolve(Response.json({ message: 'Sign-in message expired.' }, { status: 401 }));
  await rejected;
  assert.equal(JSON.parse(stored.get(`friendsdk:login:${options.account}`)).signature, 'signature-2');
  const last = createNakamaGameBackend({ ...options, friend: { ...friend, tokenId: '23' } });
  await last.rpc('read', undefined);
  assert.equal(signatures, 2);
  old.close(); newer.close(); last.close();
});
