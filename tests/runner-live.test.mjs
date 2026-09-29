import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { buildGame, readGameDeployment } from '../scripts/dev-game.mjs';

const deployment = JSON.parse(await readFile(new URL('../examples/fishing/deployment.json', import.meta.url), 'utf8'));
const exec = promisify(execFile);

test('live runner retains only public deployment fields and validates configuration', async () => {
  const input = { ...deployment, deploymentBlock: BigInt(deployment.deploymentBlock), internalOnly: 'not-for-the-browser',
    transactions: [{ step: 'fund', hash: 'unrelated-record' }], definition: { extra: 'not-for-the-browser' } };
  const result = await readGameDeployment(input);
  assert.deepEqual(result, deployment);
  assert(Object.isFrozen(result));
  await assert.rejects(readGameDeployment({ ...deployment, chainId: 1 }), /4663/);
  await assert.rejects(readGameDeployment({ ...deployment, game: 'not-an-address' }), /game address/);
  await assert.rejects(readGameDeployment({ ...deployment, deploymentBlock: -1n }), /deploymentBlock/);
  await assert.rejects(readGameDeployment({ ...deployment, deploymentBlock: undefined }), /confirmed deployment transaction/);
});

test('explicit live builds do not bundle full deployment records or pass deployment to the game', async () => {
  const outdir = await mkdtemp(join(tmpdir(), 'friendsdk-live-build-'));
  let build;
  try {
    build = await buildGame(fileURLToPath(new URL('../examples/fishing', import.meta.url)), {
      outdir, deployment: { ...deployment, internalOnly: 'UNSHARED_DEPLOYMENT_RECORD' },
    });
    const host = await readFile(join(outdir, 'runtime.js'), 'utf8');
    const child = await readFile(join(outdir, 'game.js'), 'utf8');
    assert(!host.includes('UNSHARED_DEPLOYMENT_RECORD'));
    assert(!child.includes(deployment.game));
    assert(!child.includes('UNSHARED_DEPLOYMENT_RECORD'));
  } finally { await build?.close(); await rm(outdir, { recursive: true, force: true }); }
});

test('runner rejects malformed network flags before starting a server', async () => {
  const script = fileURLToPath(new URL('../scripts/dev-game.mjs', import.meta.url));
  await assert.rejects(exec(process.execPath, [script, 'dev', '--port', '0']), /Port must be/);
  await assert.rejects(exec(process.execPath, [script, 'dev', '--port', '70000']), /Port must be/);
  await assert.rejects(exec(process.execPath, [script, 'build', '--host', '0.0.0.0']), /Usage:/);
  await assert.rejects(exec(process.execPath, [script, 'init', '--deployment', 'deployment.json']), /Usage:/);
  await assert.rejects(exec(process.execPath, [script, 'init', '--outdir', 'output']), /Usage:/);
  await assert.rejects(exec(process.execPath, [script, 'build', '--outdir']), /Missing value/);
});

test('preview and live CLI outputs remain separate, portable static bundles with no private records', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'friendsdk fishing variants '));
  const script = fileURLToPath(new URL('../scripts/dev-game.mjs', import.meta.url));
  const fishing = fileURLToPath(new URL('../examples/fishing', import.meta.url));
  const config = fileURLToPath(new URL('../examples/fishing/deployment.json', import.meta.url));
  const preview = join(directory, 'preview'), live = join(directory, 'live');
  try {
    await exec(process.execPath, [script, 'build', fishing, '--outdir', preview]);
    const originalPreview = await readFile(join(preview, 'runtime.js'), 'utf8');
    const previewGame = await readFile(join(preview, 'game.js'), 'utf8');
    assert(!originalPreview.includes(deployment.game), 'The default preview does not enable the live deployment');
    await exec(process.execPath, [script, 'build', fishing, '--deployment', config, '--outdir', live]);
    const liveRuntime = await readFile(join(live, 'runtime.js'), 'utf8');
    assert.equal(await readFile(join(preview, 'runtime.js'), 'utf8'), originalPreview, 'A live build cannot overwrite the preview');
    assert(liveRuntime.includes(deployment.game), 'Only the live host receives the deployment');
    const liveOnlyMarkers = ['eth_sendTransaction', 'wallet_sendTransaction', 'writeContract',
      'eth_signTypedData_v4', 'personal_sign',
      'function approve(address spender, uint256 amount) returns (bool)',
      'function transfer(address to, uint256 value) returns (bool)'];
    for (const marker of [...liveOnlyMarkers, 'eth_sendRawTransaction', 'sendRawTransaction']) {
      assert(!originalPreview.includes(marker), `Preview excludes ${marker}`);
      assert(!previewGame.includes(marker), `Sandbox excludes ${marker}`);
    }
    for (const marker of liveOnlyMarkers) assert(liveRuntime.includes(marker), `Live build retains ${marker}`);
    for (const output of [preview, live]) {
      const files = await readdir(output);
      assert.deepEqual(files.sort(), ['.friendsdk-output.json', 'game-layout.css', 'game.css', 'game.html', 'game.js', 'index.html', 'layout.css', 'runtime.css', 'runtime.js']);
      const generated = JSON.parse(await readFile(join(output, '.friendsdk-output.json'), 'utf8'));
      assert.equal(generated.version, 1);
      assert.deepEqual(generated.files, files.filter(file => file !== '.friendsdk-output.json'));
      for (const document of ['index.html', 'game.html']) {
        const html = await readFile(join(output, document), 'utf8');
        for (const match of html.matchAll(/(?:src|href)="\.\/([^"?#]+)"/g)) assert(files.includes(match[1]), `Missing local asset ${match[1]}`);
        assert(!html.includes(directory), 'Static HTML is independent of its build-machine path');
      }
      assert(!(await readFile(join(output, 'game.js'), 'utf8')).includes(deployment.game), 'The sandbox contains game code only');
    }
  } finally { await rm(directory, { recursive: true, force: true }); }
});
