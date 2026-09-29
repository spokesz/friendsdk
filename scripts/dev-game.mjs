#!/usr/bin/env node
import { context } from 'esbuild';
import { readFile, writeFile, mkdir, realpath, stat, lstat, cp, readdir, rename } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createPublicClient, http, isAddress, zeroAddress } from 'viem';
import { parseChanceGame } from '../dist/game.js';

const sdkRoot = fileURLToPath(new URL('..', import.meta.url));
const require = createRequire(import.meta.url);
const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const mainnetRpc = 'https://rpc.mainnet.chain.robinhood.com';
const escapeHtml = value => value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
const childCsp = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; font-src 'self'; media-src 'self' blob:; connect-src 'self' https://rpc.mainnet.chain.robinhood.com; base-uri 'none'; form-action 'none'; frame-src 'none'";
const html = (name, title, child = false) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">${child ? `<meta http-equiv="Content-Security-Policy" content="${childCsp}">` : ''}<title>${escapeHtml(title)}</title><link rel="stylesheet" href="./${name}.css"></head><body><main id="root"></main><script src="./${name}.js"></script></body></html>
`;
const outputManifest = '.friendsdk-output.json';
const standardOutputs = new Set(['index.html', 'game.html', 'runtime.js', 'game.js', 'runtime.css', 'game.css', 'layout.css', 'game-layout.css']);
const generatedName = name => typeof name === 'string' && (standardOutputs.has(name) ||
  /^assets\/(?!\.)[^/\\]+-[A-Z0-9]{8}\.(png|jpg|webp|svg|woff2|mp3|wav)$/.test(name));

async function recordedOutputs(root) {
  if (!(await lstat(path.join(root, outputManifest))).isFile()) throw new Error('SDK output manifest must be a regular file.');
  const manifest = JSON.parse(await readFile(path.join(root, outputManifest), 'utf8'));
  if (manifest.version !== 1 || !Array.isArray(manifest.files) || !manifest.files.every(generatedName)) {
    throw new Error('Invalid SDK output manifest. Choose a new output directory.');
  }
  return new Set(manifest.files);
}

async function checkOutputDirectory(root, allowed) {
  const found = [];
  async function visit(directory, prefix = '') {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const name = prefix + entry.name;
      if (entry.isDirectory() && name === 'assets') { await visit(path.join(directory, entry.name), 'assets/'); continue; }
      if (!entry.isFile() || (name !== outputManifest && !(allowed ? allowed.has(name) : generatedName(name)))) {
        throw new Error(`Output directory contains an unrelated file or directory (${name}). Choose an empty dedicated --outdir; existing files were preserved.`);
      }
      if (name !== outputManifest) found.push(name);
    }
  }
  await visit(root);
  return found;
}

/** Only public deployment fields may enter the browser bundle. Never spread a manifest. */
export async function readGameDeployment(input) {
  if (!input || typeof input !== 'object' || input.chainId !== 4663) throw new Error('Live deployment requires Robinhood mainnet chainId 4663.');
  const deployment = { chainId: input.chainId };
  for (const name of ['game', 'rf', 'generations', 'entropy', 'provider']) {
    if (typeof input[name] !== 'string' || !isAddress(input[name]) || input[name].toLowerCase() === zeroAddress) {
      throw new Error(`Live deployment requires a valid ${name} address.`);
    }
    deployment[name] = input[name];
  }
  let block = input.deploymentBlock;
  if (block === undefined) {
    const hash = input.transactions?.find?.(transaction => transaction.step === 'deploy')?.hash;
    if (typeof hash !== 'string' || !/^0x[0-9a-f]{64}$/i.test(hash)) throw new Error('Live deployment requires deploymentBlock or a confirmed deployment transaction.');
    const client = createPublicClient({ transport: http(mainnetRpc) });
    if (await client.getChainId() !== deployment.chainId) throw new Error('Deployment RPC is on the wrong chain.');
    const receipt = await client.getTransactionReceipt({ hash });
    if (receipt.status !== 'success' || receipt.contractAddress?.toLowerCase() !== deployment.game.toLowerCase()) {
      throw new Error('Deployment transaction does not confirm the configured game.');
    }
    block = receipt.blockNumber;
  }
  if (!(typeof block === 'bigint' && block > 0n) && !(typeof block === 'string' && /^[1-9][0-9]*$/.test(block))) {
    throw new Error('deploymentBlock must be a positive bigint or decimal string.');
  }
  return Object.freeze({ ...deployment, deploymentBlock: String(block) });
}

/** Bundle a game component with the SDK runtime. Only generated files go in outdir. */
export async function buildGame(gameDirectory, { outdir = path.join(gameDirectory, '.friendsdk'), watch = false, deployment } = {}) {
  const liveDeployment = deployment === undefined ? undefined : await readGameDeployment(deployment);
  const directory = await realpath(path.resolve(gameDirectory));
  outdir = path.resolve(outdir);
  const definitionPath = path.join(directory, 'game.json');
  const definition = parseChanceGame(JSON.parse(await readFile(definitionPath, 'utf8')));
  const componentPath = path.join(directory, 'index.tsx');
  await stat(componentPath);
  const hostStylePath = path.join(directory, 'host.css');
  let hostStyleImport = '';
  try {
    await stat(hostStylePath);
    hostStyleImport = `import ${JSON.stringify(hostStylePath)};`;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await mkdir(outdir, { recursive: true });
  outdir = await realpath(outdir);
  for (const source of [directory, await realpath(process.cwd()), await realpath(sdkRoot)]) {
    if (source === outdir || source.startsWith(outdir + path.sep)) {
      throw new Error('Output directory must not be the project directory or one of its parents. Choose a dedicated --outdir.');
    }
  }
  let previous;
  try { previous = await recordedOutputs(outdir); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const generated = new Set(await checkOutputDirectory(outdir, previous));
  let manifestWrites = Promise.resolve();
  const outputTracking = {
    name: 'friendsdk-output-files', setup(build) {
      build.onEnd(result => {
        if (result.errors.length) return;
        for (const file of Object.keys(result.metafile.outputs)) {
          const relative = path.relative(outdir, path.resolve(directory, file)).split(path.sep).join('/');
          if (!generatedName(relative)) throw new Error('Build emitted an unexpected output path.');
          generated.add(relative);
        }
        manifestWrites = manifestWrites.then(async () => {
          await writeFile(path.join(outdir, `${outputManifest}.tmp`), JSON.stringify({ version: 1, files: [...generated].sort() }) + '\n');
          await rename(path.join(outdir, `${outputManifest}.tmp`), path.join(outdir, outputManifest));
        });
        return manifestWrites;
      });
    },
  };
  const sdkExports = {
    name: 'friendsdk-exports', setup(build) {
      build.onResolve({ filter: /^@rarefriends\/friendsdk(?:\/|$)/ }, args => {
        const name = args.path.replace('@rarefriends/friendsdk', '.') || '.';
        const entry = packageJson.exports[name];
        if (!entry) return { errors: [{ text: `Unknown SDK export: ${args.path}` }] };
        return { path: path.join(sdkRoot, typeof entry === 'string' ? entry : entry.import) };
      });
    },
  };
  const common = {
    absWorkingDir: directory, bundle: true, format: 'iife', platform: 'browser', target: 'es2022', jsx: 'automatic',
    define: { 'process.env.NODE_ENV': '"production"', 'globalThis.__FRIENDSDK_LIVE__': liveDeployment ? 'true' : 'false' }, minify: true, logLevel: 'warning',
    loader: { '.png': 'file', '.jpg': 'file', '.webp': 'file', '.svg': 'file', '.woff2': 'file', '.mp3': 'file', '.wav': 'file' },
    assetNames: 'assets/[name]-[hash]', plugins: [sdkExports, outputTracking], metafile: true,
    alias: { react: path.dirname(require.resolve('react/package.json')), 'react-dom': path.dirname(require.resolve('react-dom/package.json')) },
  };
  const shared = `import {createRoot} from 'react-dom/client';
import {parseChanceGame} from '@rarefriends/friendsdk/game';
import gameJson from ${JSON.stringify(definitionPath)};
import '@rarefriends/friendsdk/frame.css';
import '@rarefriends/friendsdk/runtime.css';
const definition = parseChanceGame(gameJson);`;
  const host = await context({ ...common, outfile: path.join(outdir, 'runtime.js'), stdin: {
    resolveDir: directory, sourcefile: 'runtime.tsx', loader: 'tsx', contents: `${shared}
import {GameHost} from '@rarefriends/friendsdk/runtime';
${hostStyleImport}
const deployment = ${JSON.stringify(liveDeployment) ?? 'undefined'};
if (deployment) deployment.deploymentBlock = BigInt(deployment.deploymentBlock);
createRoot(document.getElementById('root')).render(<GameHost definition={definition} frameUrl="./game.html" deployment={deployment}/>);`,
  } });
  let child;
  try {
    child = await context({ ...common, outfile: path.join(outdir, 'game.js'), stdin: {
      resolveDir: directory, sourcefile: 'game.tsx', loader: 'tsx', contents: `${shared}
import {GameSession} from '@rarefriends/friendsdk/runtime';
import Game from ${JSON.stringify(componentPath)};
createRoot(document.getElementById('root')).render(<GameSession definition={definition}>{props=><Game {...props}/>}</GameSession>);`,
    } });
    await Promise.all([host.rebuild(), child.rebuild()]);
    // Separate styles keep the game document full-size inside its single SDK frame.
    await writeFile(path.join(outdir, 'layout.css'), '*{box-sizing:border-box}html,body{margin:0;font-family:ui-monospace,monospace;background:#eee}#root{max-width:var(--rf-game-max-width,960px);margin:auto}');
    await writeFile(path.join(outdir, 'game-layout.css'), '*{box-sizing:border-box}html,body,#root{width:100%;height:100%;margin:0;overflow:hidden;font-family:ui-monospace,monospace}');
    await writeFile(path.join(outdir, 'index.html'), html('runtime', definition.name).replace('</head>', '<link rel="stylesheet" href="./layout.css"></head>'));
    await writeFile(path.join(outdir, 'game.html'), html('game', definition.name, true).replace('</head>', '<link rel="stylesheet" href="./game-layout.css"></head>'));
    for (const file of standardOutputs) generated.add(file);
    await checkOutputDirectory(outdir, generated);
    await writeFile(path.join(outdir, outputManifest), JSON.stringify({ version: 1, files: [...generated].sort() }) + '\n');
    if (watch) await Promise.all([host.watch(), child.watch()]);
    else await Promise.all([host.dispose(), child.dispose()]);
    return { outdir, close: async () => { await Promise.all([host.dispose(), child.dispose()]); } };
  } catch (error) {
    await host.dispose(); await child?.dispose(); throw error;
  }
}

/** Serve generated assets only; no project-source or parent-directory access. */
export function createGameServer(outdir) {
  const root = path.resolve(outdir);
  const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.woff2': 'font/woff2', '.mp3': 'audio/mpeg', '.wav': 'audio/wav' };
  return createServer(async (request, response) => {
    if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405).end(); return; }
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      const name = pathname === '/' ? 'index.html' : pathname.slice(1);
      if (!generatedName(name) || !(await recordedOutputs(root)).has(name)) { response.writeHead(404).end(); return; }
      const file = await realpath(path.join(root, name));
      const base = await realpath(root);
      if (file !== path.join(base, name) || !file.startsWith(base + path.sep) || !(await stat(file)).isFile()) { response.writeHead(404).end(); return; }
      response.writeHead(200, { 'Content-Type': types[path.extname(file)] ?? 'application/octet-stream',
        'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*', 'X-Content-Type-Options': 'nosniff' });
      response.end(request.method === 'HEAD' ? undefined : await readFile(file));
    } catch { response.writeHead(404).end('Not found'); }
  });
}

async function main() {
  const args = process.argv.slice(2), command = args.shift() ?? 'dev';
  const usage = 'Usage: friendsdk init|dev|build|check|test <game-directory>\nDev/build: --outdir directory --deployment public-deployment.json\nDev: --host 127.0.0.1 --port 4173\nTest (automated): --width 960 --screenshot image.png';
  if (command === '--help') { console.log(usage); return; }
  if (command === '--version') { console.log(packageJson.version); return; }
  if (!['init', 'dev', 'build', 'check', 'test'].includes(command)) throw new Error(usage);
  let directory, deploymentPath, outdir, screenshot, width = 960, host = '127.0.0.1', port = 4173;
  const allowed = command === 'dev' ? ['--deployment', '--outdir', '--host', '--port']
    : command === 'build' ? ['--deployment', '--outdir'] : command === 'test' ? ['--width', '--screenshot'] : [];
  const flags = new Set();
  while (args.length) {
    const arg = args.shift();
    if (!arg.startsWith('--')) { if (directory !== undefined) throw new Error(usage); directory = arg; continue; }
    if (!allowed.includes(arg) || flags.has(arg)) throw new Error(usage);
    flags.add(arg);
    const value = args.shift();
    if (!value || value.startsWith('--')) throw new Error(`Missing value for ${arg}.`);
    if (arg === '--deployment') deploymentPath = value;
    else if (arg === '--outdir') outdir = value;
    else if (arg === '--screenshot') screenshot = value;
    else if (arg === '--width') {
      if (!/^[1-9][0-9]*$/.test(value) || !Number.isSafeInteger(Number(value))) throw new Error('Width must be a positive integer in pixels.');
      width = Number(value);
    }
    else if (arg === '--host') { if (/[\s/]/.test(value)) throw new Error('Invalid listen host.'); host = value; }
    else {
      if (!/^[0-9]+$/.test(value) || Number(value) < 1 || Number(value) > 65535) throw new Error('Port must be between 1 and 65535.');
      port = Number(value);
    }
  }
  directory ??= command === 'init' ? 'games/my-game' : 'examples/starter';
  if (command === 'init') {
    // Reject existing destinations before copying any files.
    await mkdir(path.dirname(path.resolve(directory)), { recursive: true });
    await mkdir(path.resolve(directory), { recursive: false });
    await cp(path.join(sdkRoot, 'examples/starter'), path.resolve(directory), { recursive: true, errorOnExist: true,
      filter: source => !['.friendsdk', 'dist'].includes(path.basename(source)) });
    console.log(`Created ${directory}. Run: friendsdk dev ${directory}`);
    return;
  }
  if (command === 'check') {
    const { checkGame } = await import('./check-games.mjs');
    console.log(await checkGame(directory));
    return;
  }
  if (command === 'test') {
    const { testGame } = await import('./testing.mjs');
    const result = await testGame(directory, { width, screenshot });
    console.log(`PASS ${result.gameDirectory}: automated fixture at ${result.width}px${result.screenshot ? `; screenshot ${result.screenshot}` : ''}`);
    return;
  }
  const deployment = deploymentPath ? JSON.parse(await readFile(path.resolve(deploymentPath), 'utf8')) : undefined;
  const build = await buildGame(directory, { watch: command === 'dev', deployment, outdir });
  if (command === 'build') { console.log(`Built ${build.outdir}`); return; }
  const server = createGameServer(build.outdir);
  server.on('error', async error => { console.error(error.message); await build.close(); process.exitCode = 1; });
  server.listen(port, host, () => console.log(`${deployment ? 'Live game' : 'Game preview'}: http://${host.includes(':') ? `[${host}]` : host}:${port} — refresh after edits.`));
  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true; server.closeAllConnections(); server.close(); await build.close();
  };
  process.once('SIGINT', close); process.once('SIGTERM', close);
}
if (process.argv[1] && import.meta.url === pathToFileURL(await realpath(process.argv[1])).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
