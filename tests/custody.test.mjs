import test from 'node:test';
import assert from 'node:assert/strict';
import { privateKeyToAccount } from 'viem/accounts';
import { custodyTicketMessage, parseCustodyTicket, friendCustomId, walletLoginMessage } from '../dist/server/index.js';
import { verifyFriendLogin, beforeAuthenticateCustom } from '../dist/server/nakama.js';
import { createNakamaGameBackend } from '../dist/nakama-client.js';
import { readGenerationEligibility } from '../dist/identity.js';

const contract = '0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D';
const custody = '0x37702f6b25217e5ef34f6b3af589476cea35be3a';
const friend = { chainId: 4663, contract, tokenId: '334269' };
const player = privateKeyToAccount(`0x${'11'.repeat(32)}`);
const grants = privateKeyToAccount(`0x${'22'.repeat(32)}`);
const stranger = privateKeyToAccount(`0x${'33'.repeat(32)}`);
const ZERO = '0x0000000000000000000000000000000000000000';
const account = player.address.toLowerCase();

async function signed(overrides = {}) {
  const expires = new Date(Date.now() + 60_000).toISOString();
  const message = walletLoginMessage({ account: player.address, expires });
  const ticketFriend = overrides.friend ?? friend;
  const ticket = custodyTicketMessage({ friend: ticketFriend, account: overrides.account ?? player.address, expires: overrides.expires ?? expires });
  return {
    customId: friendCustomId(friend), message, signature: await player.signMessage({ message }), now: Date.now(), generations: contract,
    read: () => ({ owner: custody, generation: 6 }),
    custody: { contract: custody, signer: grants.address, beneficiary: () => overrides.beneficiary ?? ZERO },
    ticket, ticketSignature: await (overrides.ticketSigner ?? grants).signMessage({ message: ticket }),
  };
}

test('the ticket format matches the grant Worker byte for byte', () => {
  const message = custodyTicketMessage({ friend, account: player.address, expires: '2026-09-25T17:00:00.000Z' });
  assert.equal(message, `Rare Friends custody ticket\nFriend: rf:4663:0x14c49e6118f46525de9ab41a51cbaa3c6ebf181d:334269\nAccount: ${account}\nExpires: 2026-09-25T17:00:00.000Z`);
  assert.deepEqual(parseCustodyTicket(message), { friend: friendCustomId(friend), account, expires: '2026-09-25T17:00:00.000Z' });
  assert.equal(parseCustodyTicket(message.replace('Friend: rf:4663', 'Friend: rf:x')), null);
});

test('a ticketed wallet signs in as a Friend custody holds', async () => {
  const identity = verifyFriendLogin(await signed());
  assert.deepEqual(identity, { chainId: 4663, contract: contract.toLowerCase(), tokenId: '334269', controller: account, generation: 6 });
  assert.equal(verifyFriendLogin(await signed({ beneficiary: player.address })).controller, account, 'A paid action bound it to this wallet');
});

test('custody sign-in rejects every ticket that does not name this Friend, wallet and signer', async () => {
  const base = await signed();
  assert.throws(() => verifyFriendLogin({ ...base, ticket: undefined }), /held in custody/);
  assert.throws(() => verifyFriendLogin({ ...base, custody: undefined }), /does not own/, 'Custody is off unless configured');
  assert.throws(() => verifyFriendLogin({ ...base, read: () => ({ owner: stranger.address, generation: 6 }) }), /does not own/, 'Tickets only cover Friends custody holds');
  const cases = [
    [{ ticketSigner: stranger }, /Invalid custody ticket/],
    [{ friend: { ...friend, tokenId: '334270' } }, /another Friend or wallet/],
    [{ account: stranger.address }, /another Friend or wallet/],
    [{ expires: new Date(Date.now() - 1).toISOString() }, /Custody ticket expired/],
    [{ beneficiary: stranger.address }, /belongs to another wallet/],
  ];
  for (const [overrides, error] of cases) {
    const input = await signed(overrides);
    assert.throws(() => verifyFriendLogin(input), error);
  }
  assert.throws(() => verifyFriendLogin({ ...base, read: () => ({ owner: custody, generation: 0 }) }), /not hardwired/);
});

test('the Nakama hook reads custody\'s beneficiary only when configured', async () => {
  const base = await signed();
  const selectors = [];
  const nk = { httpRequest(url, method, headers, body) {
    const { to, data } = JSON.parse(body).params[0];
    selectors.push([to.toLowerCase(), data.slice(0, 10)]);
    const word = data.startsWith('0x6352211e') ? custody.slice(2).padStart(64, '0') : data.startsWith('0x5daa3160') ? ZERO.slice(2).padStart(64, '0') : '6'.padStart(64, '0');
    return { code: 200, body: JSON.stringify({ jsonrpc: '2.0', id: 1, result: `0x${word}` }) };
  } };
  const logger = { error() {}, info() {} };
  const request = { create: true, account: { id: base.customId, vars: { message: base.message, signature: base.signature, ticket: base.ticket, ticketSignature: base.ticketSignature } } };
  const env = { CHAIN_RPC_URL: 'https://rpc.test', CUSTODY_CONTRACT: custody, CUSTODY_TICKET_SIGNER: grants.address };
  const result = beforeAuthenticateCustom({ env }, logger, nk, request);
  assert.equal(result.account.vars.controller, account);
  assert.deepEqual(selectors.at(-1), [custody, '0x5daa3160'], 'beneficiary(uint256) on the custody contract');
  assert.throws(() => beforeAuthenticateCustom({ env: { CHAIN_RPC_URL: 'https://rpc.test' } }, logger, nk, request), error => error.code === 16 && /does not own/.test(error.message));
});

test('the client adds a fresh custody ticket to every sign-in and keeps the wallet signature shared', async t => {
  const bodies = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    bodies.push(JSON.parse(init.body));
    return Response.json(String(url).includes('/authenticate/custom') ? { token: `e30.${btoa(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 1 }))}.s` } : { ok: true });
  });
  let tickets = 0;
  const session = createNakamaGameBackend({ backend: { host: 'nakama.test', port: 443, useSSL: true, serverKey: 'k' }, gameId: 'nexus', friend,
    account: '0x9999999999999999999999999999999999999999', signMessage: async () => 'wallet-signature',
    custodyTicket: async () => ({ message: `ticket-${++tickets}`, signature: `ticket-signature-${tickets}` }) });
  await session.rpc('read', undefined);
  await session.rpc('read', undefined);
  const logins = bodies.filter(body => body?.id);
  assert.equal(logins.length, 2, 'The short session forces a second sign-in');
  assert.deepEqual(logins.map(body => [body.vars.signature, body.vars.ticket, body.vars.ticketSignature]),
    [['wallet-signature', 'ticket-1', 'ticket-signature-1'], ['wallet-signature', 'ticket-2', 'ticket-signature-2']]);
  session.close();
});

test('eligibility accepts a custodied Friend unless it is bound to another wallet', async () => {
  let bound = ZERO;
  const client = {
    getChainId: async () => 4663, getBlockNumber: async () => 100n,
    readContract: async ({ address, functionName }) => functionName === 'ownerOf' ? custody : functionName === 'generation' ? 6
      : (assert.equal(address, custody), bound),
  };
  const read = () => readGenerationEligibility(client, 334269n, player.address, undefined, custody);
  assert.deepEqual([(await read()).custodied, (await read()).eligible], [true, true]);
  bound = player.address;
  assert.equal((await read()).eligible, true);
  bound = stranger.address;
  assert.equal((await read()).eligible, false);
  assert.equal((await readGenerationEligibility(client, 334269n, player.address)).eligible, false, 'Without custody, only direct owners are eligible');
});
