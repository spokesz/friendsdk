import { createClient, http, type PublicClient } from "viem";
import { getBlockNumber, getChainId, getLogs, readContract } from "viem/actions";

export type FriendReadClient = Pick<PublicClient, "getBlockNumber" | "getChainId" | "getLogs" | "readContract">;

/** Public RPC client with only the actions used by previews and artwork reads. */
export function createFriendReadClient(rpcUrl: string, options: Parameters<typeof http>[1] = {}): FriendReadClient {
  const client = createClient({ transport: http(rpcUrl, options), cacheTime: 0, pollingInterval: 1_000 });
  return {
    getBlockNumber: parameters => getBlockNumber(client, parameters),
    getChainId: () => getChainId(client),
    getLogs: parameters => getLogs(client, parameters),
    readContract: parameters => readContract(client, parameters),
  } as FriendReadClient;
}
