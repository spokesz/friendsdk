import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir, readdir, rm, stat, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { buildGame } from '@rarefriends/friendsdk/build';
import { createGameServer } from '@rarefriends/friendsdk/serve';

const exec = promisify(execFile);

test('installed-style CLI creates and builds a game in the current project and refuses to overwrite it', async () => {
  const project = await mkdtemp(join(tmpdir(), 'friendsdk consumer '));
  try {
    const source = fileURLToPath(new URL('../scripts/dev-game.mjs', import.meta.url));
    const command = process.platform === 'win32' ? source : join(project, 'friendsdk');
    if (command !== source) await symlink(source, command);
    await exec(process.execPath, [command, 'init', 'games/my-game'], { cwd: project });
    const component = join(project, 'games/my-game/index.tsx');
    const original = await readFile(component, 'utf8');
    assert.match(original, /export default function/);
    await assert.rejects(exec(process.execPath, [command, 'init', 'games/my-game'], { cwd: project }));
    assert.equal(await readFile(component, 'utf8'), original);
    await exec(process.execPath, [command, 'build', 'games/my-game'], { cwd: project });
    assert.match((await exec(process.execPath, [command, 'check', 'games/my-game'], { cwd: project })).stdout, /valid;/);
    for (const name of ['index.html', 'runtime.js', 'game.html', 'game.js']) {
      assert((await stat(join(project, 'games/my-game/.friendsdk', name))).size > 0);
    }
  } finally { await rm(project, { recursive: true, force: true }); }
});

test('preview server serves sandbox assets with CORS and never exposes project source', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'friendsdk-server-'));
  let build, server;
  try {
    build = await buildGame(fileURLToPath(new URL('../examples/starter', import.meta.url)), { outdir: join(directory, 'output') });
    server = createGameServer(build.outdir);
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}`;
    const frame = await fetch(`${url}/game.html`);
    assert.equal(frame.headers.get('access-control-allow-origin'), '*');
    assert.match(await frame.text(), /Content-Security-Policy/);
    assert.equal((await fetch(`${url}/..%2f..%2fpackage.json`)).status, 404);
    assert.equal((await fetch(`${url}/index.tsx`)).status, 404);
    assert.equal((await fetch(`${url}/`, { method: 'POST' })).status, 405);
    const canary = 'FAKE_LOCAL_CANARY_NOT_A_CREDENTIAL';
    await writeFile(join(build.outdir, '.env.audit'), canary);
    await writeFile(join(build.outdir, 'private-record.json'), JSON.stringify({ canary }));
    for (const pathname of ['/.env.audit', '/private-record.json', '/.friendsdk-output.json']) {
      assert.equal((await fetch(url + pathname)).status, 404, pathname);
    }
    await assert.rejects(buildGame(fileURLToPath(new URL('../examples/starter', import.meta.url)), { outdir: build.outdir }), /unrelated file/);
    assert.equal(await readFile(join(build.outdir, '.env.audit'), 'utf8'), canary);
    assert.equal(JSON.parse(await readFile(join(build.outdir, 'private-record.json'), 'utf8')).canary, canary);
    if (process.platform !== 'win32') {
      // Even a generated filename cannot alias an unlisted file inside or outside the output root.
      await rm(join(build.outdir, 'game.js'));
      await symlink(join(build.outdir, '.env.audit'), join(build.outdir, 'game.js'));
      assert.equal((await fetch(`${url}/game.js`)).status, 404);
      await rm(join(build.outdir, 'game.js'));
      await writeFile(join(directory, 'outside.txt'), canary);
      await symlink(join(directory, 'outside.txt'), join(build.outdir, 'game.js'));
      assert.equal((await fetch(`${url}/game.js`)).status, 404);
    }
  } finally {
    if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    await build?.close(); await rm(directory, { recursive: true, force: true });
  }
});

test('builds reject project roots and mixed directories, but upgrade clean legacy outputs', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'friendsdk-output-'));
  const source = fileURLToPath(new URL('../examples/starter', import.meta.url));
  let build;
  try {
    await assert.rejects(buildGame(source, { outdir: source }), /project directory/);
    await assert.rejects(buildGame(source, { outdir: join(source, '..') }), /project directory/);
    const mixed = join(directory, 'mixed'); await mkdir(mixed);
    await writeFile(join(mixed, '.env.audit'), 'FAKE_CANARY');
    await writeFile(join(mixed, 'source.json'), '{"private":"FAKE_CANARY"}');
    await assert.rejects(buildGame(source, { outdir: mixed }), /unrelated file/);
    assert.deepEqual((await readdir(mixed)).sort(), ['.env.audit', 'source.json']);
    assert.equal(await readFile(join(mixed, '.env.audit'), 'utf8'), 'FAKE_CANARY');
    const outdir = join(directory, 'legacy');
    build = await buildGame(source, { outdir });
    await build.close(); build = undefined;
    await rm(join(outdir, '.friendsdk-output.json'));
    build = await buildGame(source, { outdir });
    // Eight runtime documents plus server.js from the starter's server.ts.
    assert.equal(JSON.parse(await readFile(join(outdir, '.friendsdk-output.json'), 'utf8')).files.length, 9);
  } finally { await build?.close(); await rm(directory, { recursive: true, force: true }); }
});

test('watch rebuilds register newly emitted assets while unrelated files stay private', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'friendsdk-watch-'));
  const outdir = join(directory, '.friendsdk');
  let build, server;
  try {
    await writeFile(join(directory, 'game.json'), await readFile(new URL('../examples/starter/game.json', import.meta.url)));
    await writeFile(join(directory, 'index.tsx'), "import image from './icon.svg'; export default function Game() { return <img src={image} alt='asset test'/>; }");
    await writeFile(join(directory, 'icon.svg'), '<svg xmlns="http://www.w3.org/2000/svg"><text>first</text></svg>');
    build = await buildGame(directory, { outdir, watch: true });
    server = createGameServer(outdir);
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}`;
    const manifest = async () => JSON.parse(await readFile(join(outdir, '.friendsdk-output.json'), 'utf8'));
    const before = (await manifest()).files;
    const first = before.find(file => file.startsWith('assets/'));
    assert(first); assert.equal((await fetch(`${url}/${first}`)).status, 200);
    await writeFile(join(outdir, '.env.audit'), 'FAKE_CANARY');
    await writeFile(join(directory, 'icon.svg'), '<svg xmlns="http://www.w3.org/2000/svg"><text>second</text></svg>');
    let second;
    const deadline = Date.now() + 5000;
    while (!second && Date.now() < deadline) {
      second = (await manifest()).files.find(file => file.startsWith('assets/') && !before.includes(file));
      if (!second) await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert(second, 'The watch rebuild must register its new hashed asset');
    assert.match(await (await fetch(`${url}/${second}`)).text(), /second/);
    assert.equal((await fetch(`${url}/.env.audit`)).status, 404);
  } finally {
    if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    await build?.close(); await rm(directory, { recursive: true, force: true });
  }
});
