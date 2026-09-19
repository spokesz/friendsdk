import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline/promises';
import { createPublicClient, createWalletClient, defineChain, getAddress, isAddress, parseAbi, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const MAINNET = Object.freeze({
  chainId: 4663,
  rpc: 'https://rpc.mainnet.chain.robinhood.com',
  generations: '0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D',
  rf: '0x0779369854d3EcdEA927206718FFD7730C67B71f',
  entropy: '0xd8a0680e7699526b57140ed4eafdcc7219dc0a0c',
  provider: '0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6',
});
export const CHAIN = defineChain({ id: MAINNET.chainId, name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [MAINNET.rpc] } } });
export const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function decimals() view returns (uint8)',
  'event Approval(address indexed owner,address indexed spender,uint256 value)',
]);
export const GENERATIONS_ABI = parseAbi([
  'function ownerOf(uint256) view returns (address)',
  'function generation(uint256) view returns (uint8)',
  'function tokenBoundAccount(uint256) view returns (address)',
  'function token() view returns (address)',
]);
export const WALLET_ABI = parseAbi([
  'function owner() view returns (address)',
  'function token() view returns (uint256,address,uint256)',
]);
// Dice's errors are parsed here so a retry that fails inside Dice prints a name.
export const ENTROPY_ABI = parseAbi([
  'function getFeeV2(address,uint32) view returns (uint128)',
  'function getRefundDelayBlocks() view returns (uint64)',
  'function getRequestV2(address,uint64) view returns ((address provider,uint64 sequenceNumber,uint32 numHashes,bytes32 commitment,uint64 blockNumber,address requester,bool useBlockhash,uint8 callbackStatus,uint16 gasLimit10k,uint128 feePaid))',
  'error RefundNotAvailable()',
  'error NoSuchRequest()',
  'error Unauthorized()',
]);
export const equal = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
export const json = value => JSON.stringify(value, (_, item) => typeof item === 'bigint' ? item.toString() : item, 2) + '\n';

export function uint(value, label) {
  if (typeof value !== 'string' || !/^[0-9]+$/.test(value) || BigInt(value) <= 0n || BigInt(value) >= 1n << 256n) throw new Error(`${label} must be a positive uint256 decimal integer.`);
  return BigInt(value);
}

export function validateArgs(args) {
  if (args.some(arg => /^(?:0x)?[0-9a-f]{64}$/i.test(arg) || /private.?key/i.test(arg))) {
    throw new Error('Enter the private key only at the hidden terminal prompt, never in arguments.');
  }
}

export async function ask(message) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('Run this script in an interactive terminal.');
  const terminal = createInterface({ input: process.stdin, output: process.stdout });
  try { return (await terminal.question(message)).trim(); } finally { terminal.close(); }
}

/** No command arguments, environment variable, readline history, or echo for secrets. */
export function promptSecret(input = process.stdin, output = process.stdout) {
  if (!input.isTTY || !output.isTTY || typeof input.setRawMode !== 'function') throw new Error('A local interactive terminal is required for the hidden private-key prompt.');
  output.write('Private key (hidden; kept in memory for this run): ');
  return new Promise((resolveKey, reject) => {
    let secret = '';
    const wasRaw = input.isRaw;
    function finish(error) {
      input.off('data', onData); input.off('end', onEnd); input.off('error', onError);
      input.setRawMode(Boolean(wasRaw)); input.pause(); output.write('\n');
      const value = secret; secret = '';
      if (error) reject(error); else resolveKey(value);
    }
    function onEnd() { finish(new Error('Private-key input closed.')); }
    function onError() { finish(new Error('Private-key input failed.')); }
    function onData(chunk) {
      for (const character of chunk.toString()) {
        if (character === '\u0003' || character === '\u0004') { finish(new Error('Cancelled.')); return; }
        if (character === '\r' || character === '\n') { finish(); return; }
        if (character === '\u007f' || character === '\b') secret = secret.slice(0, -1);
        else if (character >= ' ') {
          if (secret.length >= 1024) { finish(new Error('Private-key input is too long.')); return; }
          secret += character;
        }
      }
    }
    input.setRawMode(true); input.on('data', onData); input.once('end', onEnd); input.once('error', onError); input.resume();
  });
}

export async function signingClients() {
  let key = await promptSecret();
  if (!/^(?:0x)?[a-f0-9]{64}$/i.test(key)) { key = ''; throw new Error('Private key must contain exactly 64 hexadecimal digits.'); }
  let account;
  try { account = privateKeyToAccount(`0x${key.replace(/^0x/i, '')}`); }
  catch { throw new Error('Invalid private key.'); }
  finally { key = ''; }
  return { account,
    client: createPublicClient({ chain: CHAIN, transport: http(MAINNET.rpc) }),
    wallet: createWalletClient({ account, chain: CHAIN, transport: http(MAINNET.rpc) }) };
}

export async function checkNetwork(client) {
  if (await client.getChainId() !== MAINNET.chainId) throw new Error(`Expected Robinhood mainnet chain ${MAINNET.chainId}.`);
}

export async function receipt(client, hash) {
  const result = await client.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 120_000 });
  if (!equal(result.transactionHash, hash)) throw new Error(`Transaction ${hash} was replaced; inspect its receipt before continuing.`);
  if (result.status !== 'success') throw new Error(`Transaction ${hash} reverted.`);
  await checkNetwork(client);
  if (!equal((await client.getBlock({ blockNumber: result.blockNumber })).hash, result.blockHash)) throw new Error(`Transaction ${hash} receipt was reorganized; inspect it before continuing.`);
  return result;
}

export async function saveManifest(path, manifest) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(`${path}.tmp`, json(manifest), { mode: 0o600 });
  await rename(`${path}.tmp`, path);
}

export async function loadManifest(path) {
  const manifest = JSON.parse(await readFile(path, 'utf8'));
  if (manifest.chainId !== MAINNET.chainId) throw new Error('Manifest must describe Robinhood mainnet.');
  for (const field of ['rf', 'generations', 'entropy', 'provider']) if (!equal(manifest[field], MAINNET[field])) throw new Error(`Manifest has unexpected ${field}.`);
  if (!isAddress(manifest.deployer) || (manifest.game !== undefined && !isAddress(manifest.game)) || !Array.isArray(manifest.transactions)) throw new Error('Invalid deployment manifest.');
  return manifest;
}

export async function artifact() {
  return JSON.parse(await readFile(resolve(ROOT, 'contracts/out/ChanceGame.sol/ChanceGame.json'), 'utf8'));
}

export async function verifyGame(client, abi, manifest) {
  await checkNetwork(client);
  if (!manifest.game) throw new Error('The game deployment is not yet confirmed.');
  const deployment = manifest.transactions.find(tx => tx.step === 'deploy');
  if (!deployment) throw new Error('Manifest has no deployment transaction.');
  const confirmed = await receipt(client, deployment.hash);
  if (!equal(confirmed.contractAddress, manifest.game) || !equal(confirmed.from, manifest.deployer)) throw new Error('Deployment receipt does not match the manifest.');
  const names = ['rf', 'generations', 'entropy', 'provider', 'team'];
  const addresses = await Promise.all(names.map(functionName => client.readContract({ address: manifest.game, abi, functionName })));
  for (let i = 0; i < names.length; i++) if (!equal(addresses[i], names[i] === 'team' ? manifest.deployer : manifest[names[i]])) throw new Error(`Deployed game has unexpected ${names[i]}.`);
  return getAddress(manifest.game);
}

export async function sendContract({ client, wallet, account, address, abi, functionName, args = [], value = 0n, onHash = () => {} }) {
  await checkNetwork(client);
  const { request, result } = await client.simulateContract({ account, address, abi, functionName, args, value });
  if (functionName === 'approve' && result !== true) throw new Error('RF approval simulation returned false.');
  const hash = await wallet.writeContract({ ...request, account, chain: wallet.chain });
  await onHash(hash);
  return receipt(client, hash);
}

export function reportError(error) {
  // Do not print viem error causes, transaction objects, or the signing account.
  console.error(error?.shortMessage ?? error?.message ?? 'Operation failed.');
  process.exitCode = 1;
}
