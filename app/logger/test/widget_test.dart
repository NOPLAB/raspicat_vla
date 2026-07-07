// セッション書き出しの最小テスト。UI/センサはデバイス依存なので、ここでは
// プラットフォーム非依存な SessionWriter のレイアウト生成のみ検証する。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vla_logger/src/config.dart';
import 'package:vla_logger/src/session/mono_clock.dart';
import 'package:vla_logger/src/session/session_writer.dart';

void main() {
  test('SessionWriter がレイアウトと meta.json を生成する', () async {
    final base = await Directory.systemTemp.createTemp('vla_logger_test');
    final clock = MonoClock();
    final w = await SessionWriter.create(
      baseDir: base,
      config: const LoggerConfig(),
      clock: clock,
    );

    await w.addFrame(<int>[0xFF, 0xD8, 0xFF, 0xD9], clock.nowNs(), 640, 480);
    w.addImu(clock.nowNs(), 0, 0, 9.8, 0, 0, 0, 0, 0, 0);
    w.addGnss(clock.nowNs(), 35.0, 139.0, 10, 5, 0, 0);
    w.addLabel(
      tStartNs: 0,
      tEndNs: clock.nowNs(),
      prompt: '前へ進む',
      source: 'app',
    );
    await w.finish(platform: 'test', appVersion: '0.0.0');

    final dir = w.dir;
    expect(await File('${dir.path}/camera/frames/00000000.jpg').exists(), true);
    expect(await File('${dir.path}/camera/frames.csv').exists(), true);
    expect(await File('${dir.path}/imu/imu.csv').exists(), true);
    expect(await File('${dir.path}/gnss/gnss.csv').exists(), true);
    expect(await File('${dir.path}/labels.jsonl').exists(), true);

    final meta = jsonDecode(
        await File('${dir.path}/meta.json').readAsString()) as Map;
    expect(meta['frame_count'], 1);
    expect(meta['embodiment'], 'raspicat');

    await base.delete(recursive: true);
  });
}
