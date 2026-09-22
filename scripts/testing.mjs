import assert from "node:assert/strict";
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { buildGame, createGameServer } from "./dev-game.mjs";
import { installFixture, createArtworkFixture, assertBounds, OWNER, FRIEND_WALLET } from "./browser-fixture.mjs";
/** The mocks behind testGame, for custom browser drivers such as a game-server end-to-end check. */
export { installFixture, createArtworkFixture, assertBounds, OWNER, FRIEND_WALLET };

/**
 * Run a game's real sandboxed runtime in headless Chromium with read-only fixtures.
 * This is automated testing only: no preview server or mock identity is published.
 */
export async function testGame(gameDirectory, { width = 960, height = 800, screenshot, timeout = 15_000, check } = {}) {
  for (const [name, value] of Object.entries({ width, height, timeout })) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer.`);
  }
  let chromium;
  try { ({ chromium } = await import("playwright")); }
  catch (cause) { throw new Error("Browser tests require Playwright. Run: npm install -D playwright && npx playwright install chromium", { cause }); }
  const directory = await realpath(resolve(gameDirectory));
  const temporary = await mkdtemp(join(tmpdir(), "friendsdk-test-"));
  let build, server, browser, fixture;
  const errors = [];
  try {
    build = await buildGame(directory, { outdir: join(temporary, "dist") });
    server = createGameServer(build.outdir);
    await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
    const origin = `http://127.0.0.1:${server.address().port}`;
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width, height }, hasTouch: width < 500,
      reducedMotion: "reduce" });
    // Reject sockets as well as fetches; RPC is always answered locally below.
    await context.routeWebSocket("**/*", socket => { errors.push(`Unexpected WebSocket: ${socket.url()}`); socket.close(); });
    const page = await context.newPage();
    page.setDefaultTimeout(timeout);
    page.setDefaultNavigationTimeout(timeout);
    page.on("pageerror", error => errors.push(error.message));
    fixture = await installFixture(page, origin, { artworkCall: await createArtworkFixture() });
    const game = page.frameLocator("iframe");
    await page.goto(origin);
    await page.getByRole("button", { name: /^Connect (wallet|Browser wallet)$/ }).click();
    await page.getByRole("button", { name: /^Friend #7730\b/ }).click();
    await page.locator("iframe").waitFor();
    await game.locator("#root > *").first().waitFor();
    await game.getByText("Waiting for your Friend…", { exact: true }).waitFor({ state: "hidden" });
    await page.locator(".rf-runtime-status").waitFor({ state: "hidden" });
    assert(fixture.ownerReads >= 2, "The real runtime must freshly verify the selected fixture identity");
    assert.equal(await page.locator("iframe").getAttribute("sandbox"), "allow-scripts");
    assert.equal(await game.locator("body").evaluate(() => { try { return Boolean(parent.document); } catch { return false; } }), false);
    await assertBounds(page);
    if (check) await check({ page, game, friendId: 7730n, account: OWNER, friendWallet: FRIEND_WALLET });
    // The callback owns game-specific readiness; polling games need not become idle.
    await game.locator("body").evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    if (screenshot) {
      screenshot = resolve(screenshot);
      await mkdir(dirname(screenshot), { recursive: true });
      await page.locator(".rf-game-frame").screenshot({ path: screenshot });
    }
    assert.deepEqual([...errors, ...fixture.errors], [], "Game browser errors");
    assert((await page.evaluate(() => window.__friendWalletTest.state.requests)).every(method =>
      ["eth_accounts", "eth_requestAccounts", "eth_chainId", "wallet_switchEthereumChain"].includes(method)), "Fixture cannot sign transactions");
    return { gameDirectory: directory, friendId: "7730", width, height, ...(screenshot ? { screenshot } : {}) };
  } catch (error) {
    const detail = [...errors, ...(fixture?.errors ?? [])];
    if (detail.length) throw new Error(`${error.message}\nBrowser errors: ${[...new Set(detail)].join("; ")}`, { cause: error });
    throw error;
  } finally {
    await browser?.close();
    if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    await build?.close();
    await rm(temporary, { recursive: true, force: true });
  }
}
