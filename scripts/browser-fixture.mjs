// Shared read-only wallet/RPC fixtures for headless automated tests only.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { decodeFunctionData, encodeFunctionResult, encodeEventTopics, padHex, parseAbi, zeroAddress } from "viem";
import { FAMILIES_REGISTRY_ABI, GENERATION_SPRITE_MANIFEST } from "../dist/generation-sprites.js";

export const OWNER = "0x1111111111111111111111111111111111111111";
export const SECOND_OWNER = "0x2222222222222222222222222222222222222222";
export const FRIEND_WALLET = "0x3333333333333333333333333333333333333333";
const COLLECTION = "0x14C49e6118F46525dE9ab41a51cBAA3c6EBF181D";
const ABI = parseAbi([
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
  "function balanceOf(address account) view returns (uint256)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function generation(uint256 tokenId) view returns (uint8)",
  "function tokenBoundAccount(uint256 tokenId) view returns (address)",
]);
/** `owner` is the connected account that owns Friend #7730; pass a real key's address when a test must also sign. */
export async function installFixture(page, origin, { artworkCall, initialChain = "0x1237", owner = OWNER } = {}) {
  const ownerId = value => value.toLowerCase() === owner.toLowerCase() ? 7730n : 3412n;
  const tokenOwner = id => id === 7730n ? owner : SECOND_OWNER;
  const state = { mode: "eligible", requests: [], ownerReads: 0, hold: null, release: null, errors: [] };
  await page.addInitScript(({ owner, initialChain }) => {
    // Internal automation is the only place an account/identity may be mocked.
    const listeners = new Map();
    const state = { accounts: [], chainId: initialChain, requests: [], switchError: null };
    const emit = (event, value) => { for (const listener of listeners.get(event) ?? []) listener(value); };
    window.ethereum = {
      async request({ method, params }) {
        state.requests.push(method);
        if (method === "eth_accounts") return state.accounts;
        if (method === "eth_requestAccounts") { state.accounts = [owner]; return state.accounts; }
        if (method === "eth_chainId") return state.chainId;
        if (method === "wallet_switchEthereumChain") {
          if (state.switchError) throw { code: state.switchError };
          if (params[0].chainId !== "0x1237") throw new Error("Switch only to Robinhood");
          state.chainId = params[0].chainId; emit("chainChanged", state.chainId); return null;
        }
        throw new Error(`Unexpected signing or wallet method: ${method}`);
      },
      on(event, listener) { if (!listeners.has(event)) listeners.set(event, new Set()); listeners.get(event).add(listener); },
      removeListener(event, listener) { listeners.get(event)?.delete(listener); },
    };
    window.__friendWalletTest = {
      state,
      accounts(accounts) { state.accounts = accounts; emit("accountsChanged", accounts); },
      chain(chainId) { state.chainId = chainId; emit("chainChanged", chainId); },
      disconnect() { state.accounts = []; emit("disconnect", { code: 4900, message: "Fixture disconnected" }); },
    };
    const random = crypto.getRandomValues.bind(crypto);
    crypto.getRandomValues = array => array instanceof Uint32Array && array.length === 1 ? (array[0] = 1500, array) : random(array);
  }, { owner, initialChain });

  async function answer(request) {
    state.requests.push(request);
    if (state.mode === "loading") await state.hold;
    if (state.mode === "rpc-error") return { jsonrpc: "2.0", id: request.id, error: { code: -32001, message: "Fixture RPC unavailable" } };
    let result;
    if (request.method === "eth_chainId") result = "0x1237";
    else if (request.method === "eth_blockNumber") result = "0x100";
    else if (request.method === "eth_getLogs") {
      const filter = request.params[0];
      assert.equal(filter.address.toLowerCase(), COLLECTION.toLowerCase());
      assert(filter.topics?.[1] || filter.topics?.[2], "Discovery must filter Transfer logs by the connected owner");
      const topic = filter.topics[2] || filter.topics[1];
      assert([padHex(owner, { size: 32 }), padHex(SECOND_OWNER, { size: 32 })].map(value => value.toLowerCase()).includes(topic.toLowerCase()), "Only owner-indexed history is allowed");
      const holder = `0x${topic.slice(-40)}`;
      result = filter.topics[1] ? [] : [{ address: COLLECTION, blockNumber: "0x10", blockHash: padHex("0x10", { size: 32 }),
        data: "0x", logIndex: "0x0", transactionHash: padHex("0x1234", { size: 32 }), transactionIndex: "0x0", removed: false,
        topics: encodeEventTopics({ abi: ABI, eventName: "Transfer", args: { from: zeroAddress, to: holder, tokenId: ownerId(holder) } }) }];
    } else if (request.method === "eth_call") {
      if (request.params[0].to.toLowerCase() !== COLLECTION.toLowerCase()) {
        assert.equal(typeof artworkCall, "function", "Read only the pinned collection unless artwork is explicitly mocked");
        result = await artworkCall(request.params[0]);
      } else {
        const { functionName, args } = decodeFunctionData({ abi: ABI, data: request.params[0].data });
        let value;
        if (functionName === "balanceOf") value = state.mode === "unowned" ? 0n : 1n;
        else {
          assert([7730n, 3412n].includes(args[0]), "Do not enumerate token IDs or scan the collection");
          if (functionName === "ownerOf") {
            state.ownerReads++;
            value = state.mode === "owner-changed" && state.ownerReads > 1 ? SECOND_OWNER : tokenOwner(args[0]);
          } else if (functionName === "generation") value = state.mode === "unhardwired" ? 0 : 1;
          else if (functionName === "tokenBoundAccount") value = FRIEND_WALLET;
          else throw new Error(`Unsupported collection read ${functionName}`);
        }
        result = encodeFunctionResult({ abi: ABI, functionName, result: value });
      }
    } else throw new Error(`Unexpected public RPC method: ${request.method}`);
    return { jsonrpc: "2.0", id: request.id, result };
  }
  await page.route("**/*", async route => {
    try {
      const url = new URL(route.request().url());
      if (url.origin === origin || ["blob:", "data:"].includes(url.protocol)) return route.continue();
      assert.equal(url.origin, "https://rpc.mainnet.chain.robinhood.com", "Automated tests cannot access external services");
      if (route.request().method() === "OPTIONS") return route.fulfill({ status: 204, headers: {
        "access-control-allow-origin": "*", "access-control-allow-methods": "POST,OPTIONS", "access-control-allow-headers": "content-type",
      } });
      const request = route.request().postDataJSON();
      const response = Array.isArray(request) ? await Promise.all(request.map(answer)) : await answer(request);
      return route.fulfill({ json: response, headers: { "access-control-allow-origin": "*" } });
    } catch (error) {
      state.errors.push(error.message);
      await route.abort("blockedbyclient");
    }
  });
  return state;
}

/** Recorded canonical artwork for fixture Friend #7730, never a playable identity. */
export async function createArtworkFixture() {
  const source = await readFile(new URL("../examples/fishing/sample-sprites.ts", import.meta.url), "utf8");
  const section = source.split('"7730": decodeGenerationSprites')[1]?.split("]),")[0];
  const frames = [...(section ?? "").matchAll(/0x[0-9a-f]+n/g)].map(([word]) => BigInt(word.slice(0, -1)));
  assert.equal(frames.length, 64, "Fixture must contain all 64 recorded canonical sample frames");
  return call => {
    assert.equal(call.to.toLowerCase(), GENERATION_SPRITE_MANIFEST.registry.toLowerCase());
    const { functionName, args } = decodeFunctionData({ abi: FAMILIES_REGISTRY_ABI, data: call.data });
    let result;
    if (functionName === "familyOf") { assert.equal(args[0], 7730n); result = 5; }
    else if (functionName === "seedOf") { assert.equal(args[0], 7730n); result = 7730; }
    else if (functionName === "frames") { assert.deepEqual(args, [5, 7730]); result = frames; }
    else throw new Error(`Unexpected artwork read ${functionName}`);
    return encodeFunctionResult({ abi: FAMILIES_REGISTRY_ABI, functionName, result });
  };
}

export async function assertBounds(page) {
  assert.deepEqual(await page.evaluate(() => {
    const frame = document.querySelector(".rf-game-frame"), problems = [];
    if (!frame) return ["Missing SDK frame"];
    if (document.querySelectorAll(".rf-game-frame").length !== 1) problems.push("Nested SDK frames");
    const bounds = frame.getBoundingClientRect();
    if (bounds.width <= 0 || bounds.height <= 0) problems.push("Game frame has no visible area");
    if (document.documentElement.scrollWidth > innerWidth) problems.push("Page overflow");
    if ([...document.querySelectorAll("nav,footer")].some(node => !frame.contains(node))) problems.push("Unrequested website scaffolding");
    for (const node of document.querySelectorAll("button,input,select,iframe")) {
      if (!frame.contains(node)) problems.push("Control outside game container");
    }
    for (const node of document.querySelectorAll(".rf-frame-menu")) {
      const box = node.getBoundingClientRect();
      if (box.left < bounds.left - 1 || box.right > bounds.right + 1 || box.top < bounds.top - 1 || box.bottom > bounds.bottom + 1) problems.push("Menu escaped container");
    }
    return problems;
  }), []);
}
