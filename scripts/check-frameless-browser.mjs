// Offline presentation regression: actual SDK host, eligibility gate, bridge and menus.
// Run after npm run build. Wallet/chain reads are in-memory fixtures, never real RPCs.
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { build as bundle } from "esbuild";
import { chromium } from "playwright";
import { buildGame, createGameServer } from "./dev-game.mjs";

const outdir = await mkdtemp(join(tmpdir(), "friendsdk-frameless-browser-"));
let build, server, browser;
try {
  build = await buildGame(resolve("examples/starter"), { outdir });
  const common = { absWorkingDir: process.cwd(), bundle: true, platform: "browser", format: "esm", jsx: "automatic",
    define: { "process.env.NODE_ENV": '"development"' } };
  await bundle({ ...common, outfile: join(outdir, "runtime.js"), stdin: {
    sourcefile: "frameless-host-fixture.tsx", resolveDir: process.cwd(), loader: "tsx", contents: `
import {useState} from 'react';
import {createRoot} from 'react-dom/client';
import {ConnectedGameHost} from '@rarefriends/friendsdk/runtime';
import {GameFrame} from '@rarefriends/friendsdk/frame';
import {parseChanceGame} from '@rarefriends/friendsdk/game';
import '@rarefriends/friendsdk/frame.css';
import '@rarefriends/friendsdk/runtime.css';
import gameJson from './examples/starter/game.json';
const definition = parseChanceGame(gameJson);
const owner = '0x1111111111111111111111111111111111111111';
const other = '0x2222222222222222222222222222222222222222';
const friends = [31n,32n].map(id=>({id,label:'Friend #'+id,kind:'owned'}));
const params = new URLSearchParams(location.search);
const fixture = window.__framelessTest = {mode:params.get('mode')??'loading',calls:[],release:null,block:100n};
const publicClient = {
  async getChainId(){fixture.calls.push({method:'getChainId'});return 4663},
  async getBlockNumber(options){
    fixture.calls.push({method:'getBlockNumber',cacheTime:options.cacheTime});
    if(fixture.mode==='loading')await new Promise(resolve=>{fixture.release=resolve});
    if(fixture.mode==='rpc-error')throw new Error('Offline fixture read failed');
    return ++fixture.block;
  },
  async readContract({functionName,args,blockNumber}){
    fixture.calls.push({method:functionName,tokenId:String(args[0]),blockNumber:String(blockNumber)});
    if(![31n,32n].includes(args[0]))throw new Error('Unexpected Friend read');
    if(functionName==='ownerOf')return fixture.mode==='unowned'?other:owner;
    if(functionName==='generation')return fixture.mode==='unhardwired'?0:1;
    if(functionName==='tokenBoundAccount')return args[0]===31n?'0x3333333333333333333333333333333333333333':'0x4444444444444444444444444444444444444444';
    throw new Error('Unexpected public read '+functionName);
  },
};
function Harness(){
  const [selected,setSelected]=useState(params.has('standalone')?null:31n);
  if(params.has('standalone'))return <main><GameFrame chrome="none" mode="preview" friends={friends} selectedFriendId={selected} onSelectFriend={setSelected}>
    <p data-testid="standalone-friend">{selected===null?'Waiting':String(selected)}</p>
  </GameFrame></main>;
  return <main><div aria-label="Host Friend selection" className="host-friends">{friends.map(friend=><button key={String(friend.id)}
    aria-pressed={selected===friend.id} onClick={()=>setSelected(friend.id)}>Select Friend #{String(friend.id)}</button>)}</div>
    <ConnectedGameHost chrome="none" definition={definition} selectedFriend={friends.find(friend=>friend.id===selected)??null}
      account={owner} chainId={4663} publicClient={publicClient} frameUrl="./game.html"/>
  </main>;
}
createRoot(document.getElementById('root')).render(<Harness/>);`,
  } });
  await bundle({ ...common, outfile: join(outdir, "game.js"), stdin: {
    sourcefile: "frameless-child-fixture.tsx", resolveDir: process.cwd(), loader: "tsx", contents: `
import {useEffect,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {GameSession} from '@rarefriends/friendsdk/runtime';
import {parseChanceGame} from '@rarefriends/friendsdk/game';
import gameJson from './examples/starter/game.json';
const definition=parseChanceGame(gameJson);
function Game({friendId,client,paused}){
  const [snapshot,setSnapshot]=useState(null),[error,setError]=useState('');
  useEffect(()=>{let alive=true;client.read().then(value=>{if(alive)setSnapshot(value)}).catch(cause=>{if(alive)setError(cause.message)});return()=>{alive=false}},[client]);
  async function buy(){try{await client.buy(1n);setSnapshot(await client.read())}catch(cause){setError(cause.message)}}
  return <section aria-label="Frameless fixture"><p data-testid="friend">{String(friendId)}</p>
    <p data-testid="count">{snapshot?String(snapshot.consumables):'loading'}</p><p data-testid="paused">{String(paused)}</p>
    <button disabled={paused||!snapshot} onClick={buy}>Buy fixture pack</button>{error&&<p data-testid="action-error">{error}</p>}</section>;
}
createRoot(document.getElementById('root')).render(<GameSession definition={definition}>{props=><Game {...props}/>}</GameSession>);`,
  } });
  // The embedding host chooses dimensions; none of these rules remove SDK chrome.
  await writeFile(join(outdir, "layout.css"), `*{box-sizing:border-box}html,body{margin:0;font-family:ui-monospace,monospace;background:#d9d9d9}
    main{width:calc(100% - 32px);margin:16px;--rf-game-aspect-ratio:2/1}.host-friends{display:flex;gap:8px;margin-bottom:12px}
    .host-friends button{min-height:40px}@media(max-width:600px){main{--rf-game-aspect-ratio:3/4}}`);
  server = createGameServer(outdir);
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const externalRequests = [], errors = [];
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    if (url.origin === origin || ["data:", "blob:"].includes(url.protocol)) return route.continue();
    externalRequests.push(url.href);
    return route.abort("blockedbyclient");
  });
  context.on("page", page => {
    page.setDefaultTimeout(10_000);
    page.on("pageerror", error => errors.push(error.message));
  });

  async function assertFrameless(page, { standalone = false } = {}) {
    assert.equal(await page.locator(".rf-frame-toolbar").count(), 0, "No SDK toolbar is rendered");
    assert.equal(await page.getByRole("button", { name: "Open Friend wallet", exact: true }).count(), 0);
    if (!standalone) {
      assert.equal(await page.getByRole("button", { name: "Choose Friend", exact: true }).count(), 0);
      assert.equal(await page.getByRole("dialog", { name: "Choose your Friend", exact: true }).count(), 0);
      assert.equal(await page.getByRole("button", { name: /^Select Friend #/ }).count(), 2, "Selection remains in the host");
    }
    const style = await page.locator(".rf-game-frame").evaluate(frame => {
      const css = getComputedStyle(frame), box = frame.getBoundingClientRect(), parent = frame.parentElement.getBoundingClientRect();
      return { background: css.backgroundColor, border: [css.borderTopWidth, css.borderRightWidth, css.borderBottomWidth, css.borderLeftWidth],
        shadow: css.boxShadow, maxWidth: css.maxWidth, width: box.width, parentWidth: parent.width, height: box.height,
        overflow: document.documentElement.scrollWidth > innerWidth };
    });
    assert.equal(style.background, "rgba(0, 0, 0, 0)");
    assert.deepEqual(style.border, ["0px", "0px", "0px", "0px"]);
    assert.equal(style.shadow, "none");
    assert.equal(style.maxWidth, "none");
    assert.ok(Math.abs(style.width - style.parentWidth) < 1, "Frame fills the embedding host");
    assert.ok(style.height > 0);
    assert.equal(style.overflow, false);
    if (page.viewportSize().width > 1000) assert.ok(style.width > 960, "Frameless mode removes the reference width limit");
  }
  async function childState(page, friendId, count) {
    const child = page.frameLocator("iframe");
    await child.getByTestId("friend").filter({ hasText: new RegExp(`^${friendId}$`) }).waitFor();
    await child.getByTestId("count").filter({ hasText: new RegExp(`^${count}$`) }).waitFor();
    await child.getByTestId("paused").filter({ hasText: /^false$/ }).waitFor();
    return child;
  }
  async function openConfirmation(page, child) {
    await child.getByRole("button", { name: "Buy fixture pack", exact: true }).click();
    const dialog = page.getByRole("dialog", { name: "Buy pack", exact: true });
    await dialog.waitFor();
    await child.getByTestId("paused").filter({ hasText: /^true$/ }).waitFor();
    assert.equal(await child.getByRole("button", { name: "Buy fixture pack", exact: true }).isDisabled(), true);
    assert.equal(await dialog.getAttribute("aria-modal"), "true");
    assert.equal(await dialog.evaluate(node => node.contains(document.activeElement)), true, "Confirmation receives focus");
    assert.equal(await page.locator(".rf-frame-chrome").evaluate(node => node.inert), true, "Game controls are inert during confirmation");
    const frameBox = await page.locator(".rf-game-frame").boundingBox(), dialogBox = await dialog.boundingBox();
    assert.ok(dialogBox.x >= frameBox.x && dialogBox.y >= frameBox.y);
    assert.ok(dialogBox.x + dialogBox.width <= frameBox.x + frameBox.width + 1);
    assert.ok(dialogBox.y + dialogBox.height <= frameBox.y + frameBox.height + 1);
    assert.equal(await dialog.getByRole("button", { name: "Confirm preview", exact: true }).isVisible(), true);
    return dialog;
  }

  for (const viewport of [{ width: 1360, height: 900 }, { width: 375, height: 812 }]) {
    const page = await context.newPage();
    await page.setViewportSize(viewport);
    await page.goto(origin);
    await page.getByRole("status").filter({ hasText: "Checking ownership and hardwired eligibility" }).waitFor();
    assert.equal(await page.locator("iframe").count(), 0, "Unverified Friends cannot mount the playable document");
    await assertFrameless(page);
    await page.evaluate(() => { window.__framelessTest.mode = "eligible"; window.__framelessTest.release(); });
    let child = await childState(page, 31, 0);
    await assertFrameless(page);
    assert.equal(await page.locator("iframe").getAttribute("sandbox"), "allow-scripts");
    const verifiedReads = await page.evaluate(() => window.__framelessTest.calls);
    assert.deepEqual(verifiedReads.map(call => call.method), ["getChainId", "getBlockNumber", "ownerOf", "generation", "tokenBoundAccount"]);
    assert.equal(verifiedReads[1].cacheTime, 0);
    assert.equal(new Set(verifiedReads.slice(2).map(call => call.blockNumber)).size, 1, "Eligibility and canonical wallet share the fresh block");

    await openConfirmation(page, child);
    await page.keyboard.press("Escape");
    await page.getByRole("dialog").waitFor({ state: "detached" });
    child = await childState(page, 31, 0);
    await openConfirmation(page, child);
    await page.getByRole("button", { name: "Confirm preview", exact: true }).click();
    child = await childState(page, 31, 1);
    assert.deepEqual(await page.evaluate(() => window.__framelessTest.calls), verifiedReads, "Actions do not introduce extra identity reads");

    await openConfirmation(page, child);
    await page.locator("iframe").evaluate(node => { node.dataset.previousSession = "yes"; });
    await page.getByRole("button", { name: "Select Friend #32", exact: true }).click();
    await page.getByRole("dialog").waitFor({ state: "detached" });
    await childState(page, 32, 0);
    assert.equal(await page.locator("iframe[data-previous-session]").count(), 0, "Friend change removes the old sandbox and session");
    assert.equal(await page.getByRole("button", { name: "Confirm preview", exact: true }).count(), 0);
    await page.getByRole("button", { name: "Select Friend #31", exact: true }).click();
    await childState(page, 31, 1);
    await assertFrameless(page);
    await page.close();
    console.log(`PASS frameless ${viewport.width}px: host selection, eligibility, uncapped transparent frame, confirmations, pause, cancellation and Friend isolation.`);
  }

  for (const mode of ["unowned", "unhardwired", "rpc-error"]) {
    const page = await context.newPage();
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto(`${origin}/?mode=${mode}`);
    const alert = page.getByRole("alert");
    await alert.waitFor();
    assert.match(await alert.textContent(), mode === "rpc-error" ? /Could not verify.*Offline fixture read failed/ : /must own this hardwired Generations Friend/);
    assert.equal(await page.locator("iframe").count(), 0, `${mode} cannot play`);
    await assertFrameless(page);
    assert.equal(await alert.getByRole("button", { name: "Retry eligibility", exact: true }).isVisible(), true);
    await page.evaluate(() => { window.__framelessTest.mode = "eligible"; });
    await alert.getByRole("button", { name: "Retry eligibility", exact: true }).click();
    await childState(page, 31, 0);
    await page.close();
    console.log(`PASS frameless ${mode}: accessible error, no playable iframe, successful explicit retry.`);
  }

  const standalone = await context.newPage();
  await standalone.setViewportSize({ width: 375, height: 812 });
  await standalone.goto(`${origin}/?standalone`);
  const picker = standalone.getByRole("dialog", { name: "Choose your Friend", exact: true });
  await picker.waitFor();
  await assertFrameless(standalone, { standalone: true });
  await picker.getByRole("button", { name: /^Friend #31\b/ }).click();
  await picker.waitFor({ state: "detached" });
  assert.equal(await standalone.getByTestId("standalone-friend").textContent(), "31");
  assert.deepEqual(externalRequests, [], "Browser fixture never accesses external services");
  assert.deepEqual(errors, []);
  console.log("PASS frameless standalone: required Friend picker remains usable without toolbar chrome.");
} finally {
  await browser?.close();
  if (server) await new Promise(resolve => server.close(resolve));
  await build?.close();
  await rm(outdir, { recursive: true, force: true });
}
