// サブパス配信 (GitHub Pages 等) は NEXT_PUBLIC_BASE_PATH=/repo-name で指定。
// 実行時 fetch する public/ 資産の URL は src/lib/baseUrl.ts が同じ値を前置する。
const basePath = process.env.NEXT_PUBLIC_BASE_PATH || '';

/** @type {import('next').NextConfig} */
const nextConfig = {
  // React + SSG: `next build` が out/ に完全静的なサイトを出力する。
  // 推論は全てクライアント (WebGPU / wasm) なのでサーバは不要。
  output: 'export',
  ...(basePath ? { basePath } : {}),
};

export default nextConfig;
