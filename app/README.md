# raspicat_vla_app — OmniVLA-edge スマホアプリ

スマホがカメラ取得と **OmniVLA-edge のオンデバイス推論** を担い、Raspberry Pi
(raspicat) はモーター制御だけを行う構成のクライアント。既存 Path 3 の Jetson を
スマホへ置き換えたもの。設計は [`../docs/mobile_port_spec.md`](../docs/mobile_port_spec.md)。

- 対象: Android / iOS (Flutter クロスプラットフォーム)
- 推論: ONNX Runtime Mobile (`onnxruntime` プラグイン)
- ゴール: text / pose / image
- Pi 送信: gRPC (`../proto/edge_action.proto`, coalesce+pace)

## 現状

Phase 3 (アプリ骨組み) 実装済み。ONNX モデルと CLIP 語彙が **未配置でも起動する**
— その場合は推論がダミー軌道になり、ステータスに「ダミー」と表示される。

配置すべきもの (詳細は各 README):
- `assets/models/omnivla_edge.onnx`, `assets/models/clip_text.onnx` (Phase 1)
- `assets/clip/bpe_simple_vocab_16e6.txt.gz` (Phase 2)

## 開発環境 (このリポジトリで構築済み)

- Flutter 3.44.4 stable → `~/flutter` (fish の PATH に追加済み)
- JDK 21 → `/usr/lib/jvm/java-21-openjdk` (`JAVA_HOME`)
- Android SDK → `~/Android/Sdk` (platform 36 / build-tools 36 / platform-tools)

新しいシェルでは fish 設定が読み込まれ `flutter` が使える。bash で使う場合:

```bash
export PATH="$HOME/flutter/bin:$PATH"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
export ANDROID_SDK_ROOT=$HOME/Android/Sdk ANDROID_HOME=$HOME/Android/Sdk
```

## コマンド

```bash
cd app
flutter pub get
flutter analyze
flutter test                 # 前処理コアの単体テスト
flutter build apk --debug    # Android
flutter run                  # 実機/エミュレータ接続時
```

iOS ビルドは macOS + Xcode が必要 (この WSL 環境では不可)。

## コード構成

`lib/src/` の各ファイルの役割は仕様書 §6「Phase 3 実装マップ」を参照。
