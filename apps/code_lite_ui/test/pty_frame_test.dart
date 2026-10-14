import 'dart:convert';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/ffi/pty_frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// 终端画面的二进制帧:Rust 只发和上一帧不同的行,Dart 直接解码(不再每帧整屏 JSON)。
/// 用真的 Rust 库和真的 shell;没编出 dylib 时跳过。
void main() {
  late ApiClient client;
  late String id;
  var available = false;

  setUp(() {
    client = ApiClient();
    final open = client.ptyOpen(10, 60);
    available = open['status'] == 'ok';
    if (available) id = open['id'] as String;
  });

  tearDown(() async {
    if (available) client.ptyClose(id);
    await client.dispose();
  });

  /// 等到画面里出现 [text],返回那一帧和此前收到的各帧。
  Future<(PtyFrame, List<PtyFrame>)> waitFor(String text, {int sinceSeq = -1}) async {
    final seen = <PtyFrame>[];
    var seq = sinceSeq;
    for (var i = 0; i < 200; i++) {
      final f = client.ptyFrame(id, sinceSeq: seq);
      if (!f.unchanged) {
        seen.add(f);
        seq = f.seq;
        final all = f.changed.values.map((r) => r.runs.map((x) => x.text).join()).join('\n');
        if (all.contains(text)) return (f, seen);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('没等到「$text」');
  }

  test('first frame is the whole screen; unchanged polls are tiny; later frames carry only the changed rows', () async {
    if (!available) return;
    final (first, _) = await waitFor('%'); // shell 提示符
    expect(first.lost, isFalse);
    expect(first.alive, isTrue);
    expect(first.rows, 10);
    expect(first.cols, 60);

    // 整屏同步一次(之前几帧可能是增量),再看没变时只回头部
    final full = client.ptyFrame(id);
    expect(full.full, isTrue);
    expect(full.changed, hasLength(10));
    expect(client.ptyFrame(id, sinceSeq: full.seq).unchanged, isTrue);

    client.ptyWrite(id, "printf 'CLX\\033[31mRED\\033[0m 中文\\n'\r");
    final (hit, frames) = await waitFor('CLXRED 中文', sinceSeq: full.seq);
    for (final f in frames) {
      expect(f.full, isFalse, reason: '手里有上一帧:只带变了的行');
      expect(f.changed.length, lessThan(10));
    }
    final row = hit.changed.values.firstWhere((r) => r.runs.map((x) => x.text).join().contains('CLXRED'));
    final red = row.runs.firstWhere((r) => r.text.contains('RED'));
    expect(red.fg, 1, reason: '颜色跟着过来');
    expect(row.runs.any((r) => r.text == '中'), isTrue, reason: '宽字符单独一段');
  });

  test('a stale since_seq gets the full screen again; a closed session is reported as lost', () async {
    if (!available) return;
    final (f, _) = await waitFor('%');
    final again = client.ptyFrame(id, sinceSeq: f.seq - 1 < 0 ? 0 : f.seq - 1);
    expect(again.full, isTrue);
    expect(client.ptyFrame('no-such-session').lost, isTrue);
  });

  test('the binary frame and the JSON snapshot describe the same screen', () async {
    if (!available) return;
    client.ptyWrite(id, "echo same-screen\r");
    await waitFor('same-screen');
    final frame = client.ptyFrame(id);
    final snap = PtyFrame.fromSnapshot(client.ptySnapshot(id));
    String text(PtyFrame f) => [for (var i = 0; i < f.rows; i++) f.changed[i]!.runs.map((r) => '${r.col}:${r.text}:${r.fg}:${r.attrs}').join('|')].join('\n');
    expect(text(frame), text(snap));
    expect((frame.cursorRow, frame.cursorCol, frame.history), (snap.cursorRow, snap.cursorCol, snap.history));
    // 帧比 JSON 小
    expect(jsonEncode(client.ptySnapshot(id)).length, greaterThan(0));
  });
}
