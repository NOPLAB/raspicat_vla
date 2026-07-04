# clip/

CLIP BPE 語彙 `bpe_simple_vocab_16e6.txt.gz` をここに置く (git 管理外)。

```bash
pnpm sync-assets   # app/assets/clip/ からコピー
```

未配置なら text ゴールの特徴はゼロベクトル扱いになる (アプリ自体は動く)。
