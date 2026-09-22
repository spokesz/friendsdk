import { readFile, readdir, access, realpath } from 'node:fs/promises';
import { resolve, relative, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { parseChanceGame, expectedReward, maximumPrize } from '../dist/game.js';

const root = fileURLToPath(new URL('..', import.meta.url));
const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));

/** Check one game in either an SDK checkout or a consuming project, without writing output. */
export async function checkGame(path) {
  const directory = resolve(path);
  const game = parseChanceGame(JSON.parse(await readFile(resolve(directory, 'game.json'), 'utf8')));
  await access(resolve(directory, 'README.md'));
  const result = await build({
    absWorkingDir: root, entryPoints: [resolve(directory, 'index.tsx')], bundle: true,
    platform: 'browser', format: 'esm', target: 'es2022', jsx: 'automatic', write: false,
    outdir: 'unused', metafile: true, external: ['react', 'react/jsx-runtime', 'react-dom/client'],
    loader: { '.png': 'file', '.jpg': 'file', '.webp': 'file', '.svg': 'file', '.woff2': 'file', '.mp3': 'file', '.wav': 'file' },
    assetNames: 'assets/[name]-[hash]',
    plugins: [{ name: 'game-boundary', setup(builder) {
      builder.onResolve({ filter: /^@rarefriends\/friendsdk\/host$/ }, () => ({ errors: [{ text: 'Wallet transport belongs to the SDK runtime, not game code.' }] }));
      builder.onResolve({ filter: /^@rarefriends\/friendsdk(?:\/|$)/ }, args => {
        const name = args.path.replace('@rarefriends/friendsdk', '.') || '.';
        const entry = packageJson.exports[name];
        if (!entry) return { errors: [{ text: `Unknown SDK export: ${args.path}` }] };
        return { path: resolve(root, typeof entry === 'string' ? entry : entry.import) };
      });
    } }],
  });
  for (const source of Object.keys(result.metafile.inputs)) {
    if (['src/chain.ts', 'dist/chain.js'].includes(relative(root, resolve(root, source)))) {
      throw new Error(`${path}: wallet transport belongs to the host, not the game frame`);
    }
  }
  // An optional game server compiles for Nakama's JavaScript runtime: no DOM, no Node.
  let server = '';
  try {
    await access(resolve(directory, 'server.ts'));
    const module = await build({ absWorkingDir: root, entryPoints: [resolve(directory, 'server.ts')], bundle: true,
      platform: 'browser', format: 'cjs', target: 'es2020', write: false, outdir: 'unused', metafile: true,
      plugins: [{ name: 'sdk', setup(builder) {
        builder.onResolve({ filter: /^@rarefriends\/friendsdk(?:\/|$)/ }, args => {
          const name = args.path.replace('@rarefriends/friendsdk', '.') || '.';
          const entry = packageJson.exports[name];
          if (!entry) return { errors: [{ text: `Unknown SDK export: ${args.path}` }] };
          return { path: resolve(root, typeof entry === 'string' ? entry : entry.import) };
        });
      } }] });
    Object.assign(result.metafile.inputs, module.metafile.inputs);
    server = `; server ${module.outputFiles.reduce((n, file) => n + file.contents.length, 0)} bytes`;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  // Submissions cannot silently pull private platform files into their build.
  for (const source of Object.keys(result.metafile.inputs)) {
    const full = resolve(root, source), local = relative(directory, full);
    if (!local.startsWith(`..${sep}`) && local !== '..') continue;
    // Public SDK stylesheet exports resolve into assets/ alongside src/ and dist/.
    if (['dist', 'src', 'assets', 'node_modules'].some(directory => full.startsWith(resolve(root, directory) + sep))) continue;
    if (full.split(sep).includes('node_modules')) continue;
    throw new Error(`${path}: undeclared source outside the game/SDK: ${source}`);
  }
  return `${path}: valid; expected reward ${expectedReward(game)}; maximum ${maximumPrize(game)} RF base units; build ${result.outputFiles.reduce((n, file) => n + file.contents.length, 0)} bytes${server}`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(await realpath(process.argv[1])).href) {
  for (const parent of ['examples', 'games']) {
    for (const entry of await readdir(resolve(root, parent), { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const path = `${parent}/${entry.name}`;
      if (parent === 'examples') {
        try { await access(resolve(root, path, 'game.json')); }
        catch (error) { if (error.code === 'ENOENT') continue; throw error; }
      }
      console.log(await checkGame(resolve(root, path)));
    }
  }
}
