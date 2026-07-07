# vla_logger — VLA チューニング用ロガー

カメラ / IMU / GNSS / 音声を**アプリ内設定周期**でキャプチャし、**生ログのまま**
端末に保存するデータ収集アプリ。後段の変換スクリプト (学習ボックス側、本アプリの
スコープ外) で LeLaN / GNM / movla の LeRobotDataset 形式へ変換し、prompt で
意味づけしてファインチューニングに使う。

`app/inference` (OmniVLA-edge オンデバイス推論) とは**別アプリ**で、推論はしない。
設計の一次情報は [`docs/design/logger_app_spec.md`](../../docs/design/logger_app_spec.md)。

## できること

- **カメラ**: `startImageStream` の最新フレームを設定周期 (既定 4Hz) で連番 JPEG 保存。
  中解像度フルフレーム・生アスペクト (crop/resize は変換側)。
- **IMU**: 加速度・ジャイロ・磁気を設定レート (既定 50Hz) で `imu.csv`。
- **GNSS**: 位置を設定レート (既定 1Hz) で `gnss.csv`。
- **音声 (push-to-talk)**: ボタン押下中のみ wav 録音 (一次データ)。端末 STT で
  文字起こしは best-effort (マイクを掴めた時のみ)。言語アノテーションのメモ用途。
- **意味づけ**: アプリ内で prompt を即時付与、または空のままオフライン後付け。
- **転送**: セッションを zip 化してローカル保存＋ Google Drive アップロード。

出力レイアウトは spec §3 を参照 (`logger_sessions/<id>/` 以下に
`meta.json` / `camera/frames/*.jpg` / `imu/imu.csv` / `gnss/gnss.csv` /
`audio/*.wav` / `labels.jsonl`)。全サンプルに単調時計 `t_mono_ns` を打ち、
モダリティ間整列は変換側で行う (アプリ内同期はしない)。

## ビルド / 実行

```bash
cd app/logger
flutter pub get
flutter run                 # 実機推奨 (カメラ/センサ/GNSS はエミュレータで限定的)
flutter build apk --debug   # Android
flutter test                # SessionWriter の最小テスト
```

Android は `minSdk 24` (record / google_sign_in v7 の下限)。iOS は Mac 上で
`flutter build ios` (iOS ビルド環境の構築先はプロジェクトのメモ参照)。

## Google Drive アップロードのセットアップ

`drive.file` スコープ (このアプリが作成したファイルのみ) を使う。OAuth クライアント
登録が必要:

- **Android**: Google Cloud Console で OAuth クライアント (Android) を作成し、
  package 名 `com.raspicat.vla_logger` と署名鍵の SHA-1 を登録。
- **iOS**: OAuth クライアント (iOS) を作成し、`ios/Runner/Info.plist` に
  reversed client ID を `CFBundleURLTypes` として追加。

未登録でもアプリは動く (録画・zip 保存まで)。Drive 送信ボタンだけがサインインで失敗する。
CI / ヘッドレスでは Drive 連携は動かない。
