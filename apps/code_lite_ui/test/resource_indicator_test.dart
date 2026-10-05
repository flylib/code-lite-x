import 'package:code_lite_ui/core/platform/process_stats.dart';
import 'package:code_lite_ui/features/status_bar/status_bar_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSampler implements ProcessStatsSampler {
  int calls = 0;

  @override
  bool get detailed => true;

  @override
  ResourceSnapshot sample() {
    calls++;
    final first = calls == 1;
    return ResourceSnapshot([
      ProcessUsage(pid: 1, name: 'CodeLiteX', memoryBytes: 300 * 1048576, cpuPercent: first ? null : 1.5),
      ProcessUsage(pid: 2, name: 'java', memoryBytes: 1100 * 1048576, cpuPercent: first ? null : 12.4),
      // 每次都是新 pid 的一次性命令(git status 之类)
      ProcessUsage(pid: 1000 + calls, name: 'git', memoryBytes: 200 * 1048576, cpuPercent: first ? null : 50),
    ]);
  }
}

void main() {
  testWidgets('label shows the IDE itself; language servers are in the tooltip; one-off commands are ignored', (tester) async {
    final sampler = _FakeSampler();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: ResourceIndicator(sampler: sampler, interval: const Duration(seconds: 2)))),
    ));
    expect(find.text('Mem 300 MB · CPU —'), findsOneWidget, reason: '第一次采样还没有 CPU 增量');
    await tester.pump(const Duration(seconds: 2));
    expect(sampler.calls, 2);
    expect(find.text('Mem 300 MB · CPU 1.5%'), findsOneWidget, reason: '语言服务器不算进标签');
    final tip = tester.widget<Tooltip>(find.byType(Tooltip)).message!;
    expect(tip, contains('CodeLiteX  300 MB · CPU 1.5%'));
    expect(tip, contains('java  1.1 GB · CPU 12%'));
    expect(tip, contains('合计  1.4 GB · CPU 14%'));
    expect(tip, isNot(contains('git')), reason: '只出现一次的子进程不计入');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    expect(sampler.calls, 2, reason: '卸载后停止采样');
  });

  test('real sampler reports this process', () {
    final s = ProcessStatsSampler().sample();
    expect(s.processes, isNotEmpty);
    expect(s.processes.first.memoryBytes, greaterThan(10 * 1048576));
  });
}
