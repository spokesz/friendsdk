/**
 * Nakama adapter for a game server module. Bundled by `friendsdk build` into the
 * server entrypoint; never imported by browser code.
 */
import { secp256k1 } from "@noble/curves/secp256k1";
import { keccak_256 } from "@noble/hashes/sha3";
import { FriendRpcError, type FriendGameServer, type FriendIdentity, type FriendStorage } from "./module.js";
import { parseFriendCustomId, parseWalletLogin } from "./login.js";

// nkruntime.Codes values; the enum exists only in the type definitions.
const INVALID_ARGUMENT = 3, INTERNAL = 13, UNAUTHENTICATED = 16;
const GENERATIONS = "0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D";
const RPC_URL = "https://rpc.mainnet.chain.robinhood.com";
const fail = (message: string, code: number): nkruntime.Error => ({ message, code });

function utf8(text: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | c >> 6, 0x80 | c & 63);
    else out.push(0xe0 | c >> 12, 0x80 | c >> 6 & 63, 0x80 | c & 63);
  }
  return new Uint8Array(out);
}
function hex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) out += (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16);
  return out;
}

/** EIP-191 personal_sign recovery; returns the lowercase signer address. */
export function recoverSigner(message: string, signature: string): string {
  if (!/^0x[0-9a-fA-F]{130}$/.test(signature)) throw new FriendRpcError("Invalid signature.");
  const body = utf8(message), prefix = utf8(`\u0019Ethereum Signed Message:\n${body.length}`);
  const data = new Uint8Array(prefix.length + body.length);
  data.set(prefix); data.set(body, prefix.length);
  let v = parseInt(signature.slice(130, 132), 16);
  if (v >= 27) v -= 27;
  if (v !== 0 && v !== 1) throw new FriendRpcError("Invalid signature.");
  let key: Uint8Array;
  try { key = secp256k1.Signature.fromCompact(signature.slice(2, 130)).addRecoveryBit(v).recoverPublicKey(keccak_256(data)).toRawBytes(false); }
  catch { throw new FriendRpcError("Invalid signature."); }
  return `0x${hex(keccak_256(key.slice(1))).slice(24)}`;
}

export type FriendChainRead = (contract: string, tokenId: string) => Readonly<{ owner: string; generation: number }>;

/** Verify a wallet's signed login for the Friend named by the custom ID. Pure; chain reads are supplied. */
export function verifyFriendLogin(input: Readonly<{ customId: string; message: string; signature: string; now: number; generations: string; read: FriendChainRead }>): FriendIdentity {
  const key = parseFriendCustomId(input.customId);
  if (!key) throw new FriendRpcError("Unrecognized Friend account.");
  if (key.contract !== input.generations.toLowerCase()) throw new FriendRpcError("Unknown Friend collection.");
  const login = parseWalletLogin(input.message);
  if (!login) throw new FriendRpcError("Unrecognized sign-in message.");
  if (!(Date.parse(login.expires) > input.now)) throw new FriendRpcError("Sign-in message expired.");
  if (recoverSigner(input.message, input.signature) !== login.account) throw new FriendRpcError("Signature does not match the account.");
  const friend = input.read(key.contract, key.tokenId);
  if (friend.owner.toLowerCase() !== login.account) throw new FriendRpcError("The signing account does not own this Friend.");
  if (friend.generation < 1) throw new FriendRpcError("This Friend is not hardwired.");
  return Object.freeze({ chainId: key.chainId, contract: key.contract, tokenId: key.tokenId, controller: login.account, generation: friend.generation });
}

const selector = (signature: string) => hex(keccak_256(utf8(signature))).slice(0, 8);
const OWNER_OF = selector("ownerOf(uint256)"), GENERATION = selector("generation(uint256)");

function ethCall(nk: nkruntime.Nakama, url: string, to: string, data: string): string {
  const response = nk.httpRequest(url, "post", { "Content-Type": "application/json" },
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }), 10_000);
  const result = response.code === 200 ? JSON.parse(response.body).result : undefined;
  if (typeof result !== "string" || !/^0x[0-9a-f]{64}$/i.test(result)) throw new Error(`Chain read failed (${response.code}).`);
  return result.slice(2).toLowerCase();
}

export function readFriendOnChain(nk: nkruntime.Nakama, url: string, contract: string, tokenId: string) {
  const id = BigInt(tokenId).toString(16).padStart(64, "0");
  return Object.freeze({
    owner: `0x${ethCall(nk, url, contract, `0x${OWNER_OF}${id}`).slice(24)}`,
    generation: parseInt(ethCall(nk, url, contract, `0x${GENERATION}${id}`), 16),
  });
}

/** Register with `initializer.registerBeforeAuthenticateCustom`. Only a wallet that owns the Friend can sign in as it. */
export function beforeAuthenticateCustom(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, data: nkruntime.AuthenticateCustomRequest): nkruntime.AuthenticateCustomRequest {
  const account = data.account ?? {}, vars = account.vars ?? {};
  let friend: FriendIdentity;
  try {
    friend = verifyFriendLogin({ customId: account.id ?? "", message: vars.message ?? "", signature: vars.signature ?? "", now: Date.now(),
      generations: ctx.env.GENERATIONS_CONTRACT ?? GENERATIONS,
      read: (contract, tokenId) => readFriendOnChain(nk, ctx.env.CHAIN_RPC_URL ?? RPC_URL, contract, tokenId) });
  } catch (error) {
    if (error instanceof FriendRpcError) throw fail(error.message, UNAUTHENTICATED);
    logger.error("Friend sign-in failed: %s", String(error));
    throw fail("Sign-in is unavailable. Try again.", INTERNAL);
  }
  return { create: data.create, username: `rf-${friend.chainId}-${friend.tokenId}`,
    account: { id: account.id, vars: { controller: friend.controller, chainId: String(friend.chainId), contract: friend.contract, tokenId: friend.tokenId, generation: String(friend.generation) } } };
}

function storageFor(nk: nkruntime.Nakama, userId: string, collection: string): FriendStorage {
  return Object.freeze({
    get<T extends object>(key: string) {
      const [object] = nk.storageRead([{ collection, key, userId }]);
      return object ? Object.freeze({ value: object.value as T, version: object.version }) : null;
    },
    put(key: string, value: object, version?: string) {
      try { nk.storageWrite([{ collection, key, userId, value: value as { [key: string]: unknown }, version, permissionRead: 1, permissionWrite: 0 }]); }
      catch (error) { throw new FriendRpcError("Game state changed. Retry."); }
    },
  });
}

let knownGames: readonly string[] = [];
/** The generated entrypoint names every game bundled into this module; activity is read from their collections. */
export function setKnownGames(ids: readonly string[]): void { knownGames = ids; }

/** Latest write per game among this Friend's records; every game's rules write to their own collection. */
function activityFor(nk: nkruntime.Nakama, userId: string): Record<string, number> {
  const latest: Record<string, number> = {};
  for (const collection of knownGames) {
    for (const object of nk.storageList(userId, collection, 100).objects ?? []) {
      const at = object.updateTime < 1e12 ? object.updateTime * 1000 : object.updateTime;
      if (!(latest[collection] >= at)) latest[collection] = at;
    }
  }
  return latest;
}

/** Called from the generated entrypoint's named RPC functions; Nakama requires those to be top-level declarations. */
export function callFriendRpc(server: FriendGameServer, name: string, ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const vars = ctx.vars ?? {};
  if (!ctx.userId || !vars.controller || !vars.tokenId || !vars.contract || !vars.generation) throw fail("Sign in with a Friend first.", UNAUTHENTICATED);
  const friend: FriendIdentity = { chainId: Number(vars.chainId), contract: vars.contract, tokenId: vars.tokenId, controller: vars.controller, generation: Number(vars.generation) };
  let input: unknown = null;
  if (payload) {
    try { input = JSON.parse(payload); } catch { throw fail("Invalid payload.", INVALID_ARGUMENT); }
  }
  try {
    const userId = ctx.userId;
    const result = server.rpcs[name]({ friend, now: Date.now(), storage: storageFor(nk, userId, server.id), activity: () => activityFor(nk, userId) }, input);
    return JSON.stringify(result === undefined ? null : result);
  } catch (error) {
    if (error instanceof FriendRpcError) throw fail(error.message, INVALID_ARGUMENT);
    logger.error("%s.%s failed: %s", server.id, name, String(error instanceof Error ? error.stack ?? error.message : error));
    throw fail("Game server error.", INTERNAL);
  }
}
