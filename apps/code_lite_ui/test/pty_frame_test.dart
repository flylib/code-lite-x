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

  /// 等 shell 安静下来(50 ms 内没有新输出),返回那时的整屏帧。之后用它的 seq 取下一帧就是增量。
  /// 不等的话,机器忙时 shell 还在画提示符,「没变」的判断和「只带变了的行」都会被新输出打乱。
  Future<PtyFrame> settle() async {
    for (var i = 0; i < 100; i++) {
      final full = client.ptyFrame(id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (client.ptyFrame(id, sinceSeq: full.seq).unchanged) return full;
    }
    fail('shell 一直有输出');
  }

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

    // 安静下来后整屏同步一次;settle 里已经确认了没新输出时只回「没变」
    final full = await settle();
    expect(full.full, isTrue);
    expect(full.changed, hasLength(10));

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
    final frame = await settle();
    final snap = PtyFrame.fromSnapshot(client.ptySnapshot(id));
    String text(PtyFrame f) => [for (var i = 0; i < f.rows; i++) f.changed[i]!.runs.map((r) => '${r.col}:${r.text}:${r.fg}:${r.attrs}').join('|')].join('\n');
    expect(text(frame), text(snap));
    expect((frame.cursorRow, frame.cursorCol, frame.history), (snap.cursorRow, snap.cursorCol, snap.history));
    // 帧比 JSON 小
    expect(jsonEncode(client.ptySnapshot(id)).length, greaterThan(0));
  });
}
