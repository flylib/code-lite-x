// 性能测量的驱动端。和 integrationDriver 一样等测试跑完、收结果,另外:
//   * 每 0.5 秒记一次 Dart 堆用量(和 phys_footprint 对照,拆出「Dart 对象」占多少);
//   * 测试结束后取几个场景时间窗里的 CPU 采样,按函数汇总(自身耗时 / 含子调用耗时)。
// 结果写到 build/perf/。
//
//   flutter drive --profile -d macos \
//     --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/common.dart';
import 'package:vm_service/vm_service.dart' as vms;

const _profiled = ['editor_typing', 'editor_scroll', 'git_log_scroll', 'tree_scroll'];

Future<void> main() async {
  final out = Directory('build/perf')..createSync(recursive: true);
  void write(String name, Object? value) =>
      File('${out.path}/$name.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(value));

  final driver = await FlutterDriver.connect();
  final svc = driver.serviceClient;
  final isolateId = driver.appIsolate.id!;

  // Dart 堆用量的时间序列
  final heap = <Map<String, int>>[];
  var done = false;
  final polling = () async {
    while (!done) {
      try {
        final u = await svc.getMemoryUsage(isolateId);
        final t = await svc.getVMTimelineMicros();
        heap.add({'t': t.timestamp!, 'heap': u.heapUsage!, 'capacity': u.heapCapacity!, 'external': u.externalUsage!});
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }();

  final raw = await driver.requestData(null, timeout: const Duration(minutes: 20));
  done = true;
  await polling;
  final response = Response.fromJson(raw);
  final data = response.data ?? const <String, dynamic>{};

  for (final entry in data.entries) {
    final value = entry.value;
    if (value is Map<String, dynamic> && value.containsKey('traceEvents')) {
      final summary = TimelineSummary.summarize(Timeline.fromJson(value));
      await summary.writeTimelineToFile(entry.key, destinationDirectory: out.path, pretty: true, includeSummary: true);
    } else {
      write(entry.key, value);
    }
  }

  // 每个场景:Dart 堆的起止 / 峰值,和这段时间的 CPU 热点
  final marks = (data['marks'] as Map?)?.cast<String, dynamic>() ?? const {};
  final perScenario = <String, Object?>{};
  for (final e in marks.entries) {
    final start = (e.value as Map)['start_us'] as int;
    final end = (e.value as Map)['end_us'] as int;
    final inside = heap.where((h) => h['t']! >= start && h['t']! <= end).toList();
    final scenario = <String, Object?>{
      'duration_ms': (end - start) ~/ 1000,
      if (inside.isNotEmpty) ...{
        'dart_heap_start_mb': inside.first['heap']! / 1048576,
        'dart_heap_end_mb': inside.last['heap']! / 1048576,
        'dart_heap_peak_mb': inside.map((h) => h['heap']!).reduce((a, b) => a > b ? a : b) / 1048576,
        'dart_heap_capacity_end_mb': inside.last['capacity']! / 1048576,
        'dart_external_end_mb': inside.last['external']! / 1048576,
      },
    };
    if (_profiled.contains(e.key)) {
      try {
        final samples = await svc.getCpuSamples(isolateId, start, end - start);
        scenario['cpu'] = _hotspots(samples);
      } catch (err) {
        scenario['cpu_error'] = '$err';
      }
    }
    perScenario[e.key] = scenario;
  }
  write('scenarios', perScenario);
  write('dart_heap_series', heap);

  await driver.close();
  exit(response.allTestsPassed ? 0 : 1);
}

/// 自身耗时和含子调用耗时最多的函数(各取前 25),以采样数和占比表示。
Map<String, Object?> _hotspots(vms.CpuSamples s) {
  final total = s.sampleCount ?? 0;
  String name(vms.ProfileFunction f) {
    final fn = f.function;
    final n = fn is vms.FuncRef ? _qualified(fn) : (fn is vms.NativeFunction ? '[native] ${fn.name}' : '$fn');
    final url = f.resolvedUrl ?? '';
    final lib = url.contains('/lib/') ? url.substring(url.lastIndexOf('/lib/') + 5) : url.split('/').last;
    return '$n  ($lib)';
  }

  List<Map<String, Object?>> top(int Function(vms.ProfileFunction) ticks) {
    final fns = [...?s.functions]..sort((a, b) => ticks(b).compareTo(ticks(a)));
    return [
      for (final f in fns.take(25))
        {'fn': name(f), 'ticks': ticks(f), 'pct': total == 0 ? 0 : (ticks(f) * 1000 ~/ total) / 10},
    ];
  }

  return {
    'samples': total,
    'sample_period_us': s.samplePeriod,
    'top_self': top((f) => f.exclusiveTicks ?? 0),
    'top_inclusive': top((f) => f.inclusiveTicks ?? 0),
  };
}

String _qualified(vms.FuncRef f) {
  final owner = f.owner;
  if (owner is vms.ClassRef) return '${owner.name}.${f.name}';
  if (owner is vms.FuncRef) return '${_qualified(owner)}.${f.name}';
  return f.name ?? '?';
}
