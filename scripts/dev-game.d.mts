import type { Server } from 'node:http';

export function buildGame(gameDirectory: string, options?: {
  outdir?: string; watch?: boolean;
  /** Public deployment configuration. Omit for simulated gameplay. */
  deployment?: unknown;
}): Promise<{ outdir: string; close(): Promise<void> }>;

/** Returns a Node server; call listen() to start and close() to stop it. */
export function createGameServer(outdir: string): Server;

export function readGameDeployment(input: unknown): Promise<Readonly<{
  chainId: number; game: string; rf: string; generations: string; entropy: string; provider: string; deploymentBlock: string;
}>>;

/** Game server address from NAKAMA_HOST, NAKAMA_PORT, NAKAMA_SSL and NAKAMA_SERVER_KEY; undefined when unset. */
export function readGameBackend(env?: Record<string, string | undefined>): Readonly<{ host: string; port: number; useSSL: boolean; serverKey: string }> | undefined;

/** Bundle several games' server.ts rules into one Nakama runtime module; resolves with the game ids. */
export function buildServerModule(gameDirectories: readonly string[], outfile: string): Promise<string[]>;
