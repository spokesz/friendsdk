/** Trusted host side of the game server: signs in as the selected Friend and forwards game RPCs. Never given to a game frame. */
import { FriendRpcError } from "./server/module.js";
import { friendCustomId, walletLoginMessage, parseWalletLogin } from "./server/login.js";

export type NakamaBackend = Readonly<{ host: string; port: number; useSSL: boolean; serverKey: string }>;
export type GameBackend = Readonly<{ rpc(name: string, payload: unknown): Promise<unknown>; close(): void }>;
export type NakamaGameBackendOptions = Readonly<{
  backend: NakamaBackend; gameId: string;
  friend: Readonly<{ chainId: number; contract: string; tokenId: string }>;
  account: string;
  /** personal_sign through the connected wallet. Called at most once per hour per wallet; one signature covers every Friend it holds. */
  signMessage(message: string): Promise<string>;
}>;

const LOGIN_TTL_MS = 60 * 60 * 1000;
const UNAVAILABLE = "Game server unavailable. Check your connection and retry.";
const REJECTED_CREDENTIALS = new Set(["Sign-in message expired.", "Invalid signature.", "Signature does not match the account."]);
type Signed = Readonly<{ message: string; signature: string }>;
/** One signature per wallet, shared by every Friend backend on the page; sessionStorage carries it across page loads. */
const signed = new Map<string, Signed>();
const signing = new Map<string, Promise<Signed>>();

function tokenExpiry(token: string): number {
  try {
    const payload = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    return typeof payload.exp === "number" ? payload.exp * 1000 : 0;
  } catch { return 0; }
}
async function readError(response: Response, fallback: string): Promise<Error> {
  let message = fallback;
  try { const body = await response.json(); if (typeof body?.message === "string" && body.message) message = body.message; } catch { /* keep fallback */ }
  return response.status < 500 ? new FriendRpcError(message) : new Error(message);
}

export function createNakamaGameBackend(options: NakamaGameBackendOptions): GameBackend {
  const { backend, gameId, friend, account } = options;
  if (!/^[a-z0-9.-]+$/i.test(backend.host) || !Number.isInteger(backend.port) || backend.port < 1 || backend.port > 65535) throw new TypeError("Invalid game server address.");
  const base = `${backend.useSSL ? "https" : "http"}://${backend.host}:${backend.port}`;
  const customId = friendCustomId(friend), cacheKey = `friendsdk:login:${account.toLowerCase()}`;
  let alive = true, session: { token: string; expiresAt: number } | null = null, pending: Promise<string> | null = null;
  const store = typeof sessionStorage === "undefined" ? undefined : sessionStorage;
  const usable = (value: Signed | null | undefined): value is Signed =>
    !!value && Date.parse(parseWalletLogin(value.message)?.expires ?? "") > Date.now() + 60_000;

  async function credentials(): Promise<Signed> {
    const held = signed.get(cacheKey);
    if (usable(held)) return held;
    try {
      const cached = JSON.parse(store?.getItem(cacheKey) ?? "null");
      if (usable(cached)) { signed.set(cacheKey, cached); return cached; }
    } catch { /* re-sign */ }
    const pendingSignature = signing.get(cacheKey);
    if (pendingSignature) return pendingSignature;
    // Friend switches and separate game backends may start while the wallet's
    // first prompt is open. Share the whole credential, including its exact
    // message, because independently generated expiry timestamps can differ.
    const request = Promise.resolve().then(async () => {
      const message = walletLoginMessage({ account, expires: new Date(Date.now() + LOGIN_TTL_MS).toISOString() });
      const value = { message, signature: await options.signMessage(message) };
      signed.set(cacheKey, value);
      try { store?.setItem(cacheKey, JSON.stringify(value)); } catch { /* storage unavailable */ }
      return value;
    }).finally(() => { signing.delete(cacheKey); });
    signing.set(cacheKey, request);
    return request;
  }
  async function login(): Promise<string> {
    const vars = await credentials();
    if (!alive) throw new Error("Game session changed.");
    let response: Response;
    try {
      response = await fetch(`${base}/v2/account/authenticate/custom?create=true`, { method: "POST",
        headers: { Authorization: `Basic ${btoa(`${backend.serverKey}:`)}`, "Content-Type": "application/json" },
        body: JSON.stringify({ id: customId, vars }) });
    } catch { throw new Error(UNAVAILABLE); }
    if (!response.ok) {
      const error = await readError(response, "Sign-in was rejected.");
      // A Friend's eligibility or a server outage does not invalidate the
      // wallet's signature for its other Friends. Nor may a delayed rejection
      // remove credentials obtained after this request started.
      if (error instanceof FriendRpcError && REJECTED_CREDENTIALS.has(error.message)) {
        const current = signed.get(cacheKey);
        if (current?.message === vars.message && current.signature === vars.signature) signed.delete(cacheKey);
        try {
          const cached = JSON.parse(store?.getItem(cacheKey) ?? "null");
          if (cached?.message === vars.message && cached.signature === vars.signature) store?.removeItem(cacheKey);
        } catch { /* storage unavailable */ }
      }
      throw error;
    }
    const body = await response.json();
    if (typeof body?.token !== "string") throw new Error(UNAVAILABLE);
    session = { token: body.token, expiresAt: tokenExpiry(body.token) };
    return session.token;
  }
  function token(): Promise<string> {
    if (session && session.expiresAt > Date.now() + 30_000) return Promise.resolve(session.token);
    pending ??= login().finally(() => { pending = null; });
    return pending;
  }
  async function call(name: string, payload: unknown, retry: boolean): Promise<unknown> {
    const bearer = await token();
    if (!alive) throw new Error("Game session changed.");
    let response: Response;
    try {
      response = await fetch(`${base}/v2/rpc/${encodeURIComponent(`${gameId}.${name}`)}?unwrap`, { method: "POST",
        headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" }, body: JSON.stringify(payload ?? null) });
    } catch { throw new Error(UNAVAILABLE); }
    if (response.status === 401 && retry) { session = null; return call(name, payload, false); }
    if (!response.ok) throw await readError(response, "Game server request failed.");
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }
  return Object.freeze({
    rpc(name: string, payload: unknown) {
      if (!alive) return Promise.reject(new Error("Game session changed."));
      return call(name, payload, true);
    },
    close() { alive = false; },
  });
}
