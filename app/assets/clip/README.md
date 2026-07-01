# CLIP BPE 語彙配置場所 (Phase 2)

`bpe_simple_vocab_16e6.txt.gz` を OpenAI CLIP リポジトリから取得しここに置く:

    https://github.com/openai/CLIP/raw/main/clip/bpe_simple_vocab_16e6.txt.gz

未配置なら `ClipTokenizer.ready == false` となり、text ゴールの特徴はゼロ埋めに
フォールバックする (text ゴールは実質無効、pose/image は動作)。
