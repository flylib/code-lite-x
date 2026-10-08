// 性能测量:在 profile 模式下驱动真实应用跑几个典型场景,记录每帧构建 / 光栅化耗时和内存。
// 结果由 test_driver/perf_driver.dart 写到 build/perf/。
//
// 编辑器场景用生成的 2 万行 Kotlin 文件:有语法高亮,但没有语言服务器,测的是界面本身。
// 文件树与 Git 日志用一个真实的大仓库(PERF_REPO,默认 bcpoker_game_server)。
//
// 会动 ~/.codelitex/recent_projects.json(打开项目会记进最近项目):开始前备份、结束后还原。

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:code_lite_ui/app.dart';
import 'package:code_lite_ui/core/platform/process_stats.dart';
import 'package:code_lite_ui/core/state/scopes.dart';
import 'package:code_lite_ui/features/bottom_tools/bottom_tools_widget.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/git/git_log_window.dart';
import 'package:code_lite_ui/features/project_explorer/project_explorer_widget.dart';
import 'package:code_lite_ui/features/title_bar/title_bar_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vm_service/vm_service.dart' as vms;
import 'package:vm_service/vm_service_io.dart';

/// false:只量内存。不录时间线 —— traceAction 会把时间线数据解码后存在应用进程里,
/// 堆统计里就分不清哪些是应用的、哪些是测量自己的。
const _trace = bool.fromEnvironment('PERF_TRACE', defaultValue: true);

const _repo = String.fromEnvironment('PERF_REPO', defaultValue: '/Users/dev/Worker/java/bcpoker_game_server');

/// 2 万行、像样的 Kotlin 代码(类、注释、字符串、数字、注解都有)。
String _bigKotlin(int classes) {
  final b = StringBuffer('package perf.sample\n\nimport kotlin.math.max\n\n');
  for (var i = 0; i < classes; i++) {
    b.writeln('/** Service number $i: keeps an eye on the tables. */');
    b.writeln('@Suppress("unused")');
    b.writeln('class Service$i(private val name: String = "service-$i", private val limit: Int = ${i * 7 % 1000}) {');
    b.writeln('    private val cache = mutableMapOf<String, Int>()');
    b.writeln('    fun handle(input: List<Int>): Int {');
    b.writeln('        var total = 0 // running sum');
    b.writeln('        for (value in input) {');
    b.writeln('            if (value > limit) total += value * 2 else total = max(total, value)');
    b.writeln('        }');
    b.writeln('        cache["\$name-last"] = total');
    b.writeln('        return total');
    b.writeln('    }');
    b.writeln('    override fun toString(): String = "Service$i(name=\$name, limit=\$limit, size=\${cache.size})"');
    b.writeln('}');
    b.writeln();
  }
  return b.toString();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  final sampler = ProcessStatsSampler();
  final memory = <String, Map<String, num>>{};

  /// 每个场景的起止时刻(VM 时间线的微秒),驱动端按它取这段时间的 CPU 采样和 Dart 堆用量。
  final marks = <String, Map<String, int>>{};

  /// 场景期间每 200 ms 采一次 IDE 自己的内存(和状态栏同一口径:phys_footprint)。
  Future<void> measure(String key, Future<void> Function() action) async {
    debugPrint('PERF scenario $key');
    final samples = <int>[];
    void sample() => samples.add(sampler.sample().processes.first.memoryBytes);
    sample();
    final startUs = developer.Timeline.now;
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) => sample());
    // 只录帧相关的流:默认的 'all' 里 Dart API 调用事件(Dart_StringToUTF8 ……)会把
    // 时间线缓冲冲掉,滚动 10 秒最后只剩零点几秒
    if (_trace) {
      await binding.traceAction(action, reportKey: key, streams: const ['Dart', 'Embedder', 'GC']);
    } else {
      await action();
    }
    timer.cancel();
    marks[key] = {'start_us': startUs, 'end_us': developer.Timeline.now};
    sample();
    num mb(int v) => (v / 1048576 * 10).round() / 10;
    memory[key] = {
      'start_mb': mb(samples.first),
      'end_mb': mb(samples.last),
      'peak_mb': mb(samples.reduce((a, b) => a > b ? a : b)),
      'mean_mb': mb(samples.reduce((a, b) => a + b) ~/ samples.length),
      'samples': samples.length,
    };
  }

  /// 什么都不做,只等真实时间过去:这期间的帧全是应用自己要画的(光标闪烁、状态栏刷新 ……)。
  /// 不能用 pump —— pump 本身就会画一帧。
  Future<void> idle(Duration d) => Future<void>.delayed(d);

  /// 强制 GC 后按类统计还活着的对象:看是谁占着 Dart 堆。
  final census = <String, Object>{};
  vms.VmService? service;
  Future<void> takeCensus(String label) async {
    final info = await developer.Service.getInfo();
    final uri = info.serverWebSocketUri;
    if (uri == null) {
      census[label] = 'VM service unavailable';
      return;
    }
    service ??= await vmServiceConnectUri(uri.toString());
    // 主 isolate(界面所在的那个);不用 Service.getIsolateId:它要 Dart 3.2,而 pubspec 写的下限是 3.0
    final vm = await service!.getVM();
    final isolateId = (vm.isolates ?? const []).firstWhere((i) => i.name == 'main', orElse: () => vm.isolates!.first).id!;
    final profile = await service!.getAllocationProfile(isolateId, gc: true);
    final usage = await service!.getMemoryUsage(isolateId);
    final members = [...?profile.members]..sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));
    census[label] = {
      'live_heap_mb': ((usage.heapUsage ?? 0) / 1048576 * 10).round() / 10,
      'footprint_mb': ((sampler.sample().processes.first.memoryBytes) / 1048576 * 10).round() / 10,
      'top': [
        for (final m in members.take(20))
          {
            'class': '${m.classRef?.name} (${m.classRef?.library?.uri?.split('/').last ?? ''})',
            'mb': ((m.bytesCurrent ?? 0) / 1048576 * 100).round() / 100,
            'instances': m.instancesCurrent,
          }
      ],
    };
  }

  Future<void> heapCensus(String label) async {
    debugPrint('PERF census $label');
    try {
      await takeCensus(label).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      census[label] = 'timed out'; // 不能让整轮测量挂死在这里
    }
  }

  Future<void> settle(WidgetTester tester, [Duration d = const Duration(seconds: 2)]) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// [within] 里纵向可滚动范围最大的那个滚动视图。
  ScrollableState biggestScroll(WidgetTester tester, Finder within) {
    final states = tester
        .stateList<ScrollableState>(find.descendant(of: within, matching: find.byType(Scrollable)))
        .where((s) => s.position.axis == Axis.vertical && s.position.hasContentDimensions)
        .toList()
      ..sort((a, b) => b.position.maxScrollExtent.compareTo(a.position.maxScrollExtent));
    return states.first;
  }

  final home = Platform.environment['HOME']!;
  final recentFile = File('$home/.codelitex/recent_projects.json');
  String? recentBackup;
  late Directory sample;

  setUpAll(() {
    if (recentFile.existsSync()) recentBackup = recentFile.readAsStringSync();
    recentFile.writeAsStringSync('[]'); // 从空状态启动,不自动打开上次的项目
    sample = Directory.systemTemp.createTempSync('clx_perf_');
    File('${sample.path}/Big.kt').writeAsStringSync(_bigKotlin(1450)); // ≈ 2 万行
  });

  tearDownAll(() {
    if (recentBackup != null) {
      recentFile.writeAsStringSync(recentBackup!);
    } else if (recentFile.existsSync()) {
      recentFile.deleteSync();
    }
    sample.deleteSync(recursive: true);
  });

  testWidgets('performance scenarios', (tester) async {
    await tester.pumpWidget(const CodeLiteApp());
    await settle(tester, const Duration(seconds: 3));
    final ctx = tester.element(find.byType(TitleBarWidget));
    final workspace = ctx.workspaceRead;
    final layout = ctx.layoutRead;
    final sessions = ctx.sessionRead;

    // 1. 刚启动、没有项目,什么都不做
    await measure('idle_no_project', () => idle(const Duration(seconds: 5)));
    await heapCensus('1_startup_no_project');

    // 2. 打开 2 万行文件,光标在编辑区闪烁,什么都不做
    await workspace.openFolder(sample.path);
    await settle(tester);
    await workspace.openFile('Big.kt');
    await settle(tester);
    await tester.tapAt(tester.getCenter(find.byType(EditorViewWidget)));
    await settle(tester, const Duration(seconds: 1));
    await measure('idle_editor_caret', () => idle(const Duration(seconds: 5)));

    // 3. 从头滚到尾再滚回来(各 5 秒)
    final editorScroll = biggestScroll(tester, find.byType(EditorViewWidget));
    await measure('editor_scroll', () async {
      await editorScroll.position.animateTo(editorScroll.position.maxScrollExtent, duration: const Duration(seconds: 5), curve: Curves.linear);
      await editorScroll.position.animateTo(0, duration: const Duration(seconds: 5), curve: Curves.linear);
    });

    // 4. 连续输入 300 个字符,每个字符一帧
    final controller = sessions.activeTab!.controller;
    await measure('editor_typing', () async {
      for (var i = 0; i < 300; i++) {
        controller.insertText(i % 40 == 39 ? '\n' : 'x');
        await tester.pump();
      }
    });
    // 别把改动留在样例文件里影响后面:撤销回去
    while (controller.undo()) {}
    await settle(tester, const Duration(seconds: 1));
    await heapCensus('2_big_file_open');

    // 5. 换到大仓库,展开前几个模块,滚动文件树
    await workspace.openFolder(_repo);
    await settle(tester, const Duration(seconds: 4));
    await heapCensus('3_switched_to_repo'); // 2 万行的文件已经随旧项目关掉,理应释放了
    final tree = find.byType(ProjectExplorerWidget);
    final topFolders = <String>['game-service', 'table-service', 'access-service', 'chat-service', 'rebate-service'];
    for (final name in topFolders) {
      final f = find.descendant(of: tree, matching: find.text(name));
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.first);
        await settle(tester, const Duration(milliseconds: 600));
      }
    }
    final treeScroll = biggestScroll(tester, tree);
    await measure('tree_scroll', () async {
      final end = treeScroll.position.maxScrollExtent;
      await treeScroll.position.animateTo(end, duration: Duration(milliseconds: (end * 3).clamp(1500, 5000).round()), curve: Curves.linear);
      await treeScroll.position.animateTo(0, duration: const Duration(seconds: 2), curve: Curves.linear);
    });

    // 6. 打开 Git 日志,滚过已加载的提交(滚近末尾会加载下一页)
    layout.selectBottomTab(BottomToolTab.git);
    final logReady = DateTime.now();
    GitLogWindow? window;
    while (DateTime.now().difference(logReady) < const Duration(seconds: 30)) {
      await tester.pump(const Duration(milliseconds: 100));
      final w = find.byType(GitLogWindow);
      if (w.evaluate().isNotEmpty) {
        window = tester.widget<GitLogWindow>(w);
        if (window.store.commits.isNotEmpty) break;
      }
    }
    final loadMs = DateTime.now().difference(logReady).inMilliseconds;
    await settle(tester, const Duration(seconds: 1));
    final logScroll = biggestScroll(tester, find.byType(GitLogWindow));
    final loadedBefore = window!.store.commits.length;
    await measure('git_log_scroll', () async {
      await logScroll.position.animateTo(logScroll.position.maxScrollExtent, duration: const Duration(seconds: 6), curve: Curves.linear);
      await settle(tester, const Duration(seconds: 2));
      await logScroll.position.animateTo(0, duration: const Duration(seconds: 3), curve: Curves.linear);
    });

    // 7. Git 窗口开着、什么都不做
    await measure('idle_git_window', () => idle(const Duration(seconds: 5)));
    await heapCensus('4_end_tree_and_git_log');
    await service?.dispose();

    binding.reportData = {
      ...?binding.reportData,
      'memory': memory,
      'marks': marks,
      'census': census,
      'facts': {
        'kotlin_lines': File('${sample.path}/Big.kt').readAsLinesSync().length,
        'git_log_first_page_ms': loadMs,
        'git_commits_loaded_before_scroll': loadedBefore,
        'git_commits_loaded_after_scroll': window.store.commits.length,
        'layout_bottom_open': layout.isBottomOpen,
        // 无障碍语义树开着时每帧都要更新它;正常只有 VoiceOver 等辅助工具连上时才开
        'semantics_enabled': binding.semanticsEnabled,
      },
    };
  });
}
