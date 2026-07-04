// onnxruntime-web の wasm/mjs ランタイムを public/ort/ へコピーする。
// ブラウザ側は `ort.env.wasm.wasmPaths = '/ort/'` でここを参照する (ortRunner.ts)。
// postinstall で毎回走る (冪等)。
import { createRequire } from 'node:module';
import { cpSync, mkdirSync, readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '..');

function ortDistDir() {
  const require = createRequire(import.meta.url);
  try {
    return path.join(path.dirname(require.resolve('onnxruntime-web/package.json')), 'dist');
  } catch {
    // exports が package.json を公開していない場合のフォールバック (pnpm の実体を辿る)。
    const direct = path.join(webRoot, 'node_modules', 'onnxruntime-web', 'dist');
    if (existsSync(direct)) return direct;
    throw new Error('onnxruntime-web が見つかりません。pnpm install 後に実行してください。');
  }
}

const dist = ortDistDir();
const dest = path.join(webRoot, 'public', 'ort');
mkdirSync(dest, { recursive: true });
let n = 0;
for (const f of readdirSync(dist)) {
  if (/\.(wasm|mjs)$/.test(f)) {
    cpSync(path.join(dist, f), path.join(dest, f));
    n += 1;
  }
}
console.log(`[copy_ort_assets] ${n} files -> public/ort/`);
