# VLA チューニング用ロガーアプリ 仕様書 (v0.1)

> 実装: `app/logger` (Flutter, パッケージ名 `vla_logger`)。`app/inference`
> (OmniVLA-edge オンデバイス推論) とは**別アプリ**で、推論はしない。
> 撮影者がスマホで **カメラ / VIO 姿勢 / IMU / GNSS / 音声** を設定周期で
> キャプチャし、**生ログのまま**保存 → 学習ボックス側の変換スクリプトで LeLaN /
> GNM / movla の LeRobotDataset v3 形式へ変換し、prompt で意味づけしてファイン
> チューニングに使う。**カメラと VIO 姿勢はどちらも AR (iOS=ARKit / Android=
> ARCore) から取得する**: AR が背面カメラを占有するため `camera` プラグインとは
> 同時起動できず、AR セッションを唯一のカメラ所有者とする。VIO 姿勢が学習の
> 正解ラベル (未来ウェイポイント列の元になる position/yaw) の一次データになる。

## 0. 目的とスコープ

VLA (OmniVLA-edge / movla) のファインチューニング用データを、専用機材なしに
スマホ単体で収集する。アプリは**「素直な生ログ収集器」に徹する**のが最重要方針:
形式変換・時刻同期・波形整形・crop/resize は一切やらず、生データ＋タイムスタンプ
だけを吐く。これにより `omnivla-edge.pth` の前処理定数(`app/inference/lib/src/config.dart`
と `web/src/lib/config.ts` が lockstep で持つ mirror)に**縛られず**、下流の学習
形式が変わってもアプリを触らずに済む。

### スコープ外
- オンデバイス推論 / gRPC・WS 送信 (それは `app/inference` の担当)
- ONNX モデル・CLIP 語彙の同梱 (ロガーは推論しないので不要)
- 形式変換・時刻同期・crop/resize (すべて学習ボックス側の変換スクリプト)

### 確定事項 (ユーザー合意済み)
- 出力: **汎用生ログ + 学習ボックス側の別変換スクリプト** (アプリは変換しない)
- カメラ: **連番 JPEG**、キャプチャは**アプリ内設定周期**、**中解像度フルフレーム**
  (例 640×480、生アスペクト、crop なし)
- 音声: **push-to-talk** (ボタン押下中のみ録音)、**言語アノテーションのメモ**用途。
  **端末内音声認識で文字起こし**(best-effort)、**生 wav も必ず保持**(真値は wav)
- 意味づけ(prompt): **アプリ内即時**と**オフライン後付け**の**両対応**
- プラットフォーム: **Android / iOS 両対応**
- 転送: **ローカル zip 保存** ＋ **Google Drive アップロード** の両方

## 1. モダリティとキャプチャモデル

| モダリティ | 取得方法 | 既定レート (アプリ内で可変) | 保存先 |
|---|---|---|---|
| カメラ | AR (ARKit/ARCore) セッションの CPU カメラ画像を native で JPEG 化・間引き | 4 Hz | `camera/frames/NNNNNNNN.jpg` ＋ `camera/frames.csv` |
| VIO 姿勢 | AR (ARKit/ARCore) の world 6DoF pose (位置 m + クォータニオン) | 30 Hz | `pose/pose.csv` |
| IMU | `sensors_plus` (加速度・ジャイロ・磁気) | 50 Hz | `imu/imu.csv` |
| GNSS | `geolocator` (lat/lon/alt/acc/speed/bearing) | 1 Hz (HW 上限) | `gnss/gnss.csv` |
| 音声 | `record`、**押下中のみ録音 (push-to-talk)** | 押下中連続 | `audio/NNNN.wav` |

- カメラ・VIO 姿勢は**同じ AR セッション**が供給源 (背面カメラの二重掴みを避けるため)。
  ネイティブ側は各 EventChannel にリスナが付いている間だけ間引いて流す (録画中のみ)。
- カメラは**中解像度フルフレームを生アスペクトで**保存。ネイティブが長辺 ~640 に縮小する
  範囲を除き crop はしない。96/160/448 等への resize は変換側。JPEG エンコードは端末で行う。
- VIO 姿勢は**座標規約を正規化せず生のまま**保存する。ARKit は `worldAlignment=.gravity`、
  ARCore は既定の world 系で、いずれも重力整列・Y 上・原点=セッション開始位置だが軸の
  向きが異なる。変換側は `meta.platform` を見て position(水平面 tx,tz)/yaw(重力軸まわり)に
  落とす。`tracking_state` (normal/limited/notAvailable | TRACKING/PAUSED/STOPPED) を各行に
  持たせ、変換側が非追従区間を除外できるようにする。
- IMU は端末の生センサ値をそのまま。座標系変換・重力除去はしない (変換側)。
- 音声は**言語メモ**。録音停止時に端末内 STT で文字起こしし、transcript を prompt 候補
  として `labels.jsonl` に載せるが、**wav が一次データ**で文字起こしは後から差し替え可能。

## 2. 時刻同期

アプリ内では**同期しない**。全サンプルに**単調時計 `t_mono_ns`** (端末起動からの
ナノ秒、`Stopwatch`/`elapsedRealtimeNanos` 相当) を打ち、セッション開始時の壁時計
アンカーを 1 つだけ `meta.json` に記録する。カメラ基準の最近傍紐付け等モダリティ間の
整列は**変換スクリプトの責務**。これで両プラットフォームで実装が単純になる。

AR (カメラ/VIO 姿勢) はネイティブが自前の時刻を持つが、**ネイティブ時刻は使わず**、
Dart が EventChannel で受信した瞬間に他モダリティと同じ共有 `MonoClock` でスタンプする
(IMU/GNSS と同一流儀。クロック写像を避けるため)。フレームと姿勢は別チャネルで数 ms の
受信ジッタが乗るが、姿勢を密 (既定 30 Hz) に流すので変換側の最近傍整列で吸収できる。

## 3. セッション/エピソードと出力レイアウト

1 録画セッション = 1 ディレクトリ = (変換後の) 1 エピソード。

```
logger_sessions/<session_id>/
├── meta.json          # 端末情報 / アプリver / 設定レート / embodiment ヒント /
│                      #   session開始・終了 t_mono_ns / 壁時計アンカー / clock種別
├── camera/
│   ├── frames/00000000.jpg ...
│   └── frames.csv     # frame_no, t_mono_ns, width, height
├── pose/pose.csv      # t_mono_ns, tx, ty, tz, qx, qy, qz, qw, tracking_state
├── imu/imu.csv        # t_mono_ns, ax, ay, az, gx, gy, gz, mx, my, mz
├── gnss/gnss.csv      # t_mono_ns, lat, lon, alt, acc, speed, bearing
├── audio/0001.wav ...
└── labels.jsonl       # 意味づけ: 1行1ラベル (下記)
```

`labels.jsonl` の各行 (意味づけの単位):
```json
{"t_start_mono_ns": 123, "t_end_mono_ns": 456,
 "prompt": "廊下をまっすぐ進んで右のドアへ",
 "audio_clip": "audio/0001.wav", "transcript": "...", "source": "app|offline"}
```
- `prompt` はアプリ内即時入力 (テキスト or 音声メモ由来) か、オフライン後付け (空で
  保存 → 学習ボックスで付与)。`source` でどちらか判別。
- 時間範囲 (`t_*_mono_ns`) でカメラフレーム列に対応づく。全区間 1 ラベルでも、区間ごと
  複数ラベルでも可。

`session_id` は端末ID + セッション開始壁時計 (アプリ内では乱数/現在時刻を使えないため、
UI 操作で確定するタイムスタンプ or カウンタで採番) から生成する。

## 4. 転送

1. **zip 化**: `archive` でセッションディレクトリを丸ごと zip。ローカル (端末の
   ドキュメント/共有ストレージ) に保存。
2. **Google Drive アップロード**: `google_sign_in` ＋ `googleapis` の Drive v3、
   スコープ `drive.file`、**レジューム対応アップロード**で zip を送る。アップロード先
   フォルダはアプリ設定で指定。
   - OAuth クライアント登録が Android (SHA-1 / package名) と iOS (reversed client ID)
     で別途必要。CI/ヘッドレスでは動かないので手動セットアップ手順を README に書く。

## 5. 権限

- Android (`AndroidManifest.xml`): `CAMERA`, `RECORD_AUDIO`, `ACCESS_FINE_LOCATION`,
  `ACCESS_COARSE_LOCATION`, `INTERNET`, `HIGH_SAMPLING_RATE_SENSORS` (IMU 高レート),
  外部ストレージ書き出しが要るなら Scoped Storage 準拠。**AR 必須**:
  `<uses-feature android:name="android.hardware.camera.ar" required="true"/>` と
  `<meta-data com.google.ar.core value="required"/>` (`com.google.ar:core` 依存、minSdk 24)。
- iOS (`Info.plist`): `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription`,
  `NSSpeechRecognitionUsageDescription` (STT)。**AR 必須**: `UIRequiredDeviceCapabilities`
  に `arkit` (ARKit は iOS システムフレームワークで追加 pod 不要)。
- 起動時に `permission_handler` でまとめて要求。

## 6. アーキテクチャ (`lib/src` 構成、`app/inference` 踏襲)

```
lib/main.dart                         entry point (薄い)
lib/src/config.dart                   既定レート・解像度・保存先などの設定
lib/src/session/session_writer.dart   セッションディレクトリ生成・各csv/jsonl追記・meta.json
lib/src/session/mono_clock.dart       単調時計
lib/src/capture/ar_session.dart       AR (ARKit/ARCore) ブリッジ + プレビュー PlatformView
lib/src/capture/camera_capture.dart   AR フレーム購読 → 連番 JPEG 保存
lib/src/capture/pose_capture.dart     AR VIO 姿勢購読 → pose.csv
lib/src/capture/imu_capture.dart      sensors_plus → imu.csv
lib/src/capture/gnss_capture.dart     geolocator → gnss.csv
lib/src/capture/audio_capture.dart    push-to-talk 録音 + STT
ios/Runner/ArPosePlugin.swift         ARKit: EventChannel + ARSCNView PlatformView
android/.../ArCoreController.kt        ARCore: チャネル登録 + 可否判定
android/.../ArCoreView.kt              ARCore: GLSurfaceView + 背景描画 + CPU画像JPEG
lib/src/transfer/zip_exporter.dart    archive で zip
lib/src/transfer/drive_uploader.dart  google_sign_in + googleapis
lib/src/ui/home_page.dart             録画開始/停止・設定・push-to-talk・prompt・一覧
lib/src/ui/session_list.dart          セッション一覧と転送
```
コメントは日本語 (`app/inference` の規約に合わせる)。

## 7. 変換スクリプト (学習ボックス側、本アプリのスコープ外・別途)

`logger_sessions/<id>/` を読み、
- **`pose/pose.csv` (VIO 軌跡) を一次ソース**に position/yaw を得る: world 位置の水平面
  (tx,tz) を position、重力軸まわりの回転を yaw にし、`meta.platform` で ARKit/ARCore の
  座標規約差を吸収、`tracking_state` の非追従区間を除外して `traj_data.pkl
  {position:(T,2), yaw:(T,)}` (GNM 形式) or LeRobotDataset v3 エピソードへ。GNSS は屋外での
  絶対位置アンカー/スケール確認、IMU は補間の補助 (VIO が主)。
- カメラ frames を position/yaw に最近傍で紐付け (共有 `t_mono_ns` 軸)
- `labels.jsonl` の prompt を LeLaN の `prompt` として付与
を行う。`external/movla/docs/data_setup.md` / `DESIGN_v1.md` (P3 実機適応 = 自己収集
teleop の LeRobotDataset v3) が変換先の参照。**このスクリプトはこのアプリには含めない。**

## 8. 未確定 / TODO

- **AR 必須**: ARKit/ARCore 非対応端末では録画開始をブロックする (フォールバックなし)。
  起動時に `isSupported` を確認し、非対応なら初期化エラーを表示する。ネイティブフレームの
  向きは AR の native センサ向きのまま (端末実装依存) で、必要なら変換側で一定回転を当てる。
- STT の言語 (日本語固定か切替か)、オフライン STT 可否 (端末により差)。当面は端末標準
  STT の best-effort、wav 一次で後追い再文字起こし前提。
- Drive フォルダ運用 (撮影者ごと / 機体ごと)。
- embodiment メタ (raspicat / turtlebot2 等) をアプリ内で選ばせるか meta.json 固定か。
- session_id 採番方式 (乱数不可のため UI 操作時刻ベース)。
