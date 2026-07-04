// public/models/manifest.json (ファイル名 -> バイト数) を生成する。
// content-encoding: gzip 付き配信 (GitHub Pages) では content-length が
// 圧縮後サイズになり進捗率の分母が取れないため、展開後の総量をビルド時に
// 焼き込み、modelStore がダウンロード進捗の分母として使う。
import {
  existsSync,
  mkdirSync,
  readdirSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const modelsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'public',
  'models',
);
mkdirSync(modelsDir, { recursive: true });

const manifest = {};
if (existsSync(modelsDir)) {
  for (const f of readdirSync(modelsDir)) {
    if (f.endsWith('.onnx')) {
      manifest[f] = statSync(join(modelsDir, f)).size;
    }
  }
}
writeFileSync(
  join(modelsDir, 'manifest.json'),
  `${JSON.stringify(manifest)}\n`,
);
console.log(`manifest: ${JSON.stringify(manifest)}`);
