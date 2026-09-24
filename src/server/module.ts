/**
 * Game server rules. One implementation runs in the browser during a local preview
 * (see local.ts) and inside Nakama in production (see nakama.ts). Handlers are
 * synchronous, receive JSON and return JSON.
 */
export type FriendIdentity = Readonly<{
  chainId: number; contract: string; tokenId: string;
  /** Wallet that proved control of the Friend when this session signed in. */
  controller: string;
  /** Generation read on chain when this session signed in: 1 is the oldest land, 6 the newest. A promotion shows on the next sign-in. */
  generation: number;
}>;
export type FriendRecord<T> = Readonly<{ value: T; version: string }>;
export type FriendStorage = Readonly<{
  /** One JSON object per key, private to this Friend and this game. */
  get<T extends object>(key: string): FriendRecord<T> | null;
  /** Pass the version read earlier to refuse a concurrent write, "*" to require a new key, or nothing to overwrite. */
  put(key: string, value: object, version?: string): void;
}>;
export type FriendRpcContext = Readonly<{
  friend: FriendIdentity; now: number; storage: FriendStorage;
  /** When each game last wrote this Friend's records, by game id, in server milliseconds. Games only write while the Friend plays. */
  activity(): Readonly<Record<string, number>>;
}>;
export type FriendRpcHandler = (context: FriendRpcContext, payload: unknown) => unknown;
export type FriendGameServer = Readonly<{ id: string; rpcs: Readonly<Record<string, FriendRpcHandler>> }>;

/** A rule violation the player may read. Any other error stays in server logs. */
export class FriendRpcError extends Error {
  constructor(message: string) { super(message); this.name = "FriendRpcError"; }
}

export const GAME_ID_PATTERN = /^[a-z][a-z0-9-]{1,31}$/;
export const RPC_NAME_PATTERN = /^[a-z][a-zA-Z0-9]{0,31}$/;

export function defineFriendGameServer(input: FriendGameServer): FriendGameServer {
  if (!GAME_ID_PATTERN.test(input.id)) throw new TypeError("A game server id is 2 to 32 lowercase letters, digits or dashes.");
  const rpcs: Record<string, FriendRpcHandler> = {};
  for (const name of Object.keys(input.rpcs)) {
    if (!RPC_NAME_PATTERN.test(name) || typeof input.rpcs[name] !== "function") throw new TypeError(`Invalid game RPC ${name}.`);
    rpcs[name] = input.rpcs[name];
  }
  return Object.freeze({ id: input.id, rpcs: Object.freeze(rpcs) });
}
