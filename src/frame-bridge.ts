import type { ChanceGameDefinition, GameSnapshot, GameClient, GameServerClient } from './game.js';
import { RPC_NAME_PATTERN } from './server/module.js';

export type GameMethod = 'read' | 'canBuy' | 'buy' | 'play' | 'settle' | 'redeem' | 'rpc';
export type GameArguments = readonly unknown[];
/** Host-side game server connection; see createNakamaGameBackend and createLocalGameBackend. */
export type GameBridgeBackend = Readonly<{ rpc(name: string, payload: unknown): Promise<unknown> }>;
const UINT256_MAX = (1n << 256n) - 1n;
const RPC_PAYLOAD_LIMIT = 16_384;
const quantity = (value: unknown) => typeof value === 'bigint' && value > 0n && value <= 99n;
function serializable(value: unknown): boolean {
  try { return value === null || (JSON.stringify(value) ?? '').length <= RPC_PAYLOAD_LIMIT; } catch { return false; }
}
function valid(method: unknown, args: unknown, outcomes: number): args is unknown[] {
  if (!Array.isArray(args)) return false;
  switch (method) {
    case 'read': return args.length === 0;
    case 'canBuy': case 'buy': case 'play': return args.length === 1 && quantity(args[0]);
    case 'settle': return args.length === 1 && typeof args[0] === 'bigint' && args[0] > 0n && args[0] <= UINT256_MAX;
    case 'redeem': return args.length === 2 && Number.isInteger(args[0]) && (args[0] as number) >= 1 && (args[0] as number) <= outcomes && quantity(args[1]);
    case 'rpc': return args.length === 2 && typeof args[0] === 'string' && RPC_NAME_PATTERN.test(args[0]) && serializable(args[1]);
    default: return false;
  }
}

// Provider errors can contain private RPC URLs, API keys, request bodies and wallet
// diagnostics. Only SDK-authored public messages cross the community-game boundary.
const PUBLIC_ACTION_ERRORS = new Set([
  'Game session changed.', 'Game action cancelled.', 'Cancelled',
  'Another game action is pending.', 'Another game transaction is pending.',
  'Close the host menu before playing.', 'Choose a quantity from 1 through 99.',
  'Invalid outcome.', 'Invalid play ID.', 'This play belongs to a different Friend.',
  'Dice fee exceeds the approved maximum. Keep this pending cast and review the fee before retrying.',
]);
function publicError(error: unknown, method: GameMethod): string {
  if (error instanceof Error) {
    const transaction = error as Error & { code?: unknown; transactionHash?: unknown };
    if (transaction.name === 'ChanceTransactionError' && typeof transaction.transactionHash === 'string' &&
        /^0x[0-9a-f]{64}$/i.test(transaction.transactionHash)) {
      const messages: Record<string, string> = {
        unconfirmed: 'has an unknown confirmation status', replaced: 'was replaced',
        reorg: 'is no longer confirmed on the expected chain', unverified: 'has an unverified game result',
        reverted: 'reverted',
      };
      if (typeof transaction.code === 'string' && Object.hasOwn(messages, transaction.code)) {
        return `Transaction ${transaction.transactionHash} ${messages[transaction.code]}. Inspect the transaction in your wallet before retrying the same action.`;
      }
    }
    if (PUBLIC_ACTION_ERRORS.has(error.message) || /^Cast #[1-9][0-9]{0,77} is pending\. Finish that same cast before starting another\.$/.test(error.message)) {
      return error.message;
    }
  }
  return method === 'read' || method === 'canBuy'
    ? 'Could not read game state. Retry the read.'
    : 'Game action failed. Check your wallet and transaction status before trying the same action again.';
}
/** Game server rule messages are written for players; anything else is a host-side failure. */
function publicRpcError(error: unknown): string {
  return error instanceof Error && (error.name === 'FriendRpcError' || error.message === 'Game session changed.') ? error.message : 'Game server request failed.';
}

/** Trusted host only. Transfer the other port to the exact sandboxed iframe window. */
export function bindGameFrame(port: MessagePort, options: {
  client: GameClient;
  authorize: (method: GameMethod, args: GameArguments) => Promise<void>;
  /** Game server for `rpc` calls; without it the game has no server actions. */
  backend?: GameBridgeBackend;
  onSnapshot?: (snapshot: GameSnapshot) => void;
  onError?: (error: Error, method: GameMethod) => void;
  onActionChange?: (busy: boolean) => void;
}) {
  let alive = true, busy = false, lastId = 0, paused = false;
  const send = (message: unknown) => { if (alive) port.postMessage(message); };
  port.onmessage = async ({ data }: MessageEvent<unknown>) => {
    if (!alive || !data || typeof data !== 'object') return;
    const request = data as { type?: unknown; id?: unknown; method?: unknown; args?: unknown };
    if (request.type !== 'friendsdk:request' || !Number.isSafeInteger(request.id) || Number(request.id) <= lastId) return;
    const id = Number(request.id); lastId = id;
    if (!valid(request.method, request.args, options.client.definition.outcomes.length)) {
      send({ type: 'friendsdk:response', id, error: 'Unsupported game action.' }); return;
    }
    const method = request.method as GameMethod, args = request.args;
    if (method === 'rpc') {
      // Server actions carry no wallet prompt and run alongside chance actions.
      try {
        if (!options.backend) throw new Error('This game has no game server.');
        const value = await options.backend.rpc(args[0] as string, args[1]);
        send({ type: 'friendsdk:response', id, value });
      } catch (error) {
        if (alive) options.onError?.(error instanceof Error ? error : new Error('Game server request failed.'), method);
        send({ type: 'friendsdk:response', id, error: publicRpcError(error) });
      }
      return;
    }
    if (busy) { send({ type: 'friendsdk:response', id, error: 'Another game action is pending.' }); return; }
    const mutation = ['buy', 'play', 'redeem'].includes(method) || (method === 'settle' && options.client.mode === 'chain');
    if (paused && mutation) {
      send({ type: 'friendsdk:response', id, error: 'Close the host menu before playing.' }); return;
    }
    busy = true;
    if (mutation) options.onActionChange?.(true);
    try {
      if (mutation) await options.authorize(method, args);
      // Authorization may have waited on a menu while selection/account changed.
      if (!alive) return;
      let value: unknown;
      switch (method) {
        case 'read': value = await options.client.read(); break;
        case 'canBuy': value = await options.client.canBuy(args[0] as bigint); break;
        case 'buy': value = await options.client.buy(args[0] as bigint); break;
        case 'play': value = await options.client.play(args[0] as bigint); break;
        case 'settle': value = await options.client.settle(args[0] as bigint); break;
        case 'redeem': value = await options.client.redeem(args[0] as number, args[1] as bigint); break;
      }
      if (!alive) return;
      if (method === 'read') options.onSnapshot?.(value as GameSnapshot);
      else if (options.client.mode === 'preview' && method !== 'canBuy') options.onSnapshot?.(await options.client.read());
      send({ type: 'friendsdk:response', id, value });
    } catch (error) {
      if (alive) options.onError?.(error instanceof Error ? error : new Error('Game action failed.'), method);
      send({ type: 'friendsdk:response', id, error: publicError(error, method) });
    } finally { busy = false; if (alive && mutation) options.onActionChange?.(false); }
  };
  port.start();
  return {
    setPaused(value: boolean) { paused = value; send({ type: 'friendsdk:paused', paused }); },
    close() { if (!alive) return; port.postMessage({ type: 'friendsdk:closed' }); alive = false; port.onmessage = null; port.close(); },
  };
}

/** Game-side client. No signer, account selection, deployment, or arbitrary RPC. */
export function createFrameGameClient(port: MessagePort, definition: ChanceGameDefinition, onPause?: (paused: boolean) => void, mode: GameClient["mode"] = "preview") {
  let nextId = 0, alive = true;
  const pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
  const close = () => {
    alive = false;
    for (const request of pending.values()) request.reject(new Error('Game session changed.'));
    pending.clear(); port.onmessage = null; port.close();
  };
  port.onmessage = ({ data }) => {
    if (!data || typeof data !== 'object') return;
    if (data.type === 'friendsdk:closed') { close(); return; }
    if (data.type === 'friendsdk:paused' && typeof data.paused === 'boolean') { onPause?.(data.paused); return; }
    if (data.type !== 'friendsdk:response') return;
    const request = pending.get(data.id);
    if (!request) return;
    pending.delete(data.id);
    if (typeof data.error === 'string') request.reject(new Error(data.error)); else request.resolve(data.value);
  };
  port.start();
  function call<T>(method: GameMethod, args: GameArguments): Promise<T> {
    if (!alive) return Promise.reject(new Error('Game session changed.'));
    if (pending.size >= 8) return Promise.reject(new Error('Too many pending game actions.'));
    const id = ++nextId;
    return new Promise<T>((resolve, reject) => {
      pending.set(id, { resolve: value => resolve(value as T), reject });
      port.postMessage({ type: 'friendsdk:request', id, method, args });
    });
  }
  const client = Object.freeze<GameClient & GameServerClient>({ mode, definition,
    read: () => call('read', []), canBuy: quantity => call('canBuy', [quantity]),
    buy: quantity => call('buy', [quantity]), play: (quantity = 1n) => call('play', [quantity]),
    settle: playId => call('settle', [playId]), redeem: (outcomeId, quantity) => call('redeem', [outcomeId, quantity]),
    rpc: (name, payload = null) => call('rpc', [name, payload]),
  });
  return { client, close };
}
