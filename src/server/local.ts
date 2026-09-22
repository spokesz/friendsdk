import { FriendRpcError, RPC_NAME_PATTERN, type FriendGameServer, type FriendIdentity, type FriendRecord, type FriendStorage } from "./module.js";

const copy = <T>(value: T): T => JSON.parse(JSON.stringify(value));

/** In-memory game server for local previews and automated tests: the same rules, no persistence. */
export function createLocalGameBackend(server: FriendGameServer, friend: FriendIdentity) {
  const records = new Map<string, FriendRecord<object>>();
  let revision = 0, wroteAt = 0;
  const storage: FriendStorage = Object.freeze({
    get<T extends object>(key: string) {
      const record = records.get(key);
      return record ? Object.freeze({ value: copy(record.value) as T, version: record.version }) : null;
    },
    put(key: string, value: object, version?: string) {
      const current = records.get(key);
      if (version === "*" ? current !== undefined : version !== undefined && current?.version !== version) throw new FriendRpcError("Game state changed. Retry.");
      records.set(key, Object.freeze({ value: copy(value), version: String(++revision) }));
      wroteAt = Date.now();
    },
  });
  // A preview holds one game, so activity is this game's own last write.
  const activity = () => wroteAt ? { [server.id]: wroteAt } : {};
  return Object.freeze({
    async rpc(name: string, payload: unknown): Promise<unknown> {
      const handler = RPC_NAME_PATTERN.test(name) ? server.rpcs[name] : undefined;
      if (!handler) throw new FriendRpcError(`Unknown game action ${name}.`);
      const result = handler({ friend, now: Date.now(), storage, activity }, payload === undefined ? null : copy(payload));
      return result === undefined ? null : copy(result);
    },
    close() {},
  });
}
