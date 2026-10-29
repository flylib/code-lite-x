// 纯 Dart 的 LSP 客户端:替代原 Rust `code-lite-lsp`(ProcessSupervisor / LspClient / VirtualLspServer)。
//
// 设计要点:
//   - 每个服务端分组(rust / go / cpp / typescript / dart / python)一个进程,首次 didOpen 时懒启动,cwd = 工作区根;
//   - initialize 完成前不发文档同步:文档状态只记在本地,初始化成功后按当前内容统一 didOpen 重放
//     (崩溃重启走同一条路径),请求则排队等待;
//   - 找不到服务端、崩溃超过 3 次或初始化超时:该语言转入降级(括号诊断 + 正则大纲),绝不让 UI 卡住;
//   - 公共方法从不抛异常,也不往 stdout 打日志(Finder 启动的 app 没有终端,stdout 只会是噪音)。
//   - 省内存(jdtls 一个项目就要五六百 MB):
//       · Java 服务端启动时补上让 JVM 把空闲内存还给系统的参数([withJvmMemoryFlags]);
//       · 项目切走超过 [idleTimeout] 没回来,停掉它的服务端进程(挂起),切回来 / 有请求时再起,按当前内容重放打开的文档;
//       · 同一个项目组里的 Java 项目共用一个 jdtls(多个工作区目录),诊断按路径分回各自的项目。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ffi/rust_syntax.dart' show rustOutline;
import '../l10n/l10n.dart';
import 'lsp_common.dart';

export 'lsp_common.dart' show LspDiagnosticsEvent, LspTextChange, LspLaunch, LspLaunchResolver;

enum _State { starting, running, missing, crashed, suspended }

/// 一个打开的文档(本地真相;服务端重启后据此重放)。
class _Doc {
  _Doc(this.languageId, this.text);

  final String? languageId;
  String text;
  int version = 1;

  /// documentSymbols 为未打开文件临时打开的文档;用户随后真正 didOpen 时转正,不再被自动关闭。
  bool temporary = false;
}

/// 一次服务端进程实例。重启会换一个新的 [_Proc],旧实例的回调据此识别自己已过期。
class _Proc {
  _Proc(this.process);

  final Process process;
  final LspFrameParser parser = LspFrameParser();
  final Map<int, Completer<Object?>> pending = {};
  final List<String> stderrTail = [];
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
  int nextId = 1;
  bool initialized = false;
  bool exited = false;

  void send(Map<String, Object?> message) {
    if (exited) return;
    try {
      process.stdin.add(LspFrameParser.encode({'jsonrpc': '2.0', ...message}));
    } catch (_) {
      // 管道已断:由 exitCode 回调统一处理崩溃。
    }
  }

  void notify(String method, [Object? params]) => send({'method': method, if (params != null) 'params': params});

  Future<Object?> request(String method, Object? params, Duration timeout) {
    if (exited) return Future.value(null);
    final id = nextId++;
    final c = Completer<Object?>();
    pending[id] = c;
    send({'id': id, 'method': method, if (params != null) 'params': params});
    return c.future.timeout(timeout, onTimeout: () {
      pending.remove(id);
      return null;
    });
  }

  void failPending() {
    for (final c in pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    pending.clear();
  }
}

/// 一个服务端分组的生命周期状态。可以被几个项目(几个 [LspService])共用,见 [clients]。
class _Server {
  _Server(this.group);

  final String group;

  /// 共用这个进程的项目(每个项目一个 LspService);不共用时只有创建它的那个。
  final List<LspService> clients = [];

  /// 共用键(项目组的 id);不共用时为 null。
  String? shareKey;

  /// 定时看一眼是不是该挂起了(所有项目都切走超过 [LspService.idleTimeout])。
  Timer? idleTimer;

  /// 没有项目在用了:不再启动 / 重启。
  bool get closed => clients.isEmpty;

  /// 启动参数、工作目录取自第一个项目。
  LspService get host => clients.first;
  _State state = _State.starting;
  List<String> argv = const [];
  int restarts = 0;
  _Proc? proc;
  String? lastError;

  /// 服务端声明的文档同步方式(initialize 返回的 textDocumentSync):1 整篇,2 增量。
  int syncKind = 1;

  /// 插件提供的启动环境与超时(由插件接管时)。
  Map<String, String> env = const {};
  Duration? initializeTimeout;
  Duration? requestTimeout;
  String? source;
  bool get fromPlugin => source != null;

  /// 已被替换(插件装好后重启):它的退出回调不再触发自动重启。
  bool retired = false;

  /// initialize 完成前排队的请求;参数为 null 表示服务端不可用,应以 null 结束。
  final List<void Function(_Proc? proc)> queue = [];

  bool get fallback => state == _State.missing || state == _State.crashed;
  bool get suspended => state == _State.suspended;

  _Proc? get ready => state == _State.running && proc != null && proc!.initialized && !proc!.exited ? proc : null;
}

class LspService {
  LspService(
    this.root, {
    Map<String, List<String>>? serverOverrides,
    this.requestTimeout = const Duration(seconds: 10),
    this.initializeTimeout = const Duration(seconds: 30),
    this.jdtlsDataRoot,
    this.launchResolver,
    this.sharedLaunchResolver,
    this.disabled = false,
  }) : _overrides = serverOverrides ?? const {} {
    _resolvedRoot = _tryResolve(root);
  }

  /// 项目组共用的服务端怎么启动:第二个参数是这个组的缓存目录名用的路径(插件按它展开 `${dataDir}`)。
  /// 没有时退回 [launchResolver](缓存放在第一个项目名下)。
  final LspLaunch? Function(String group, String dataRoot)? sharedLaunchResolver;

  // -------------------------------------------------------------------------
  // 省内存:共用 / 挂起(进程级设置,由 ProjectManager 接上)
  // -------------------------------------------------------------------------

  /// 项目根目录 → 共用键(它所在项目组的 id);不在组里返回 null。ProjectManager 设置。
  static String? Function(String root)? shareKeyFor;

  /// 哪些分组的服务端可以被项目组共用。jdtls 支持一个进程管多个工作区目录(Maven / Gradle 项目各自导入)。
  static const Set<String> sharedGroups = {'java'};

  /// 项目切走多久后停掉它的服务端。
  static Duration idleTimeout = const Duration(minutes: 15);

  /// 多久检查一次(测试里调小)。
  static Duration idleCheckInterval = const Duration(minutes: 1);

  /// 正在共用的服务端:`分组|共用键` → 服务端。
  static final Map<String, _Server> _shared = {};

  /// 这个项目现在是不是正在显示的那个(ProjectManager 切换时设置)。
  bool _active = true;
  DateTime _inactiveSince = DateTime.now();

  /// 项目切到前台 / 后台。切回来时把挂起的服务端重新拉起。
  void setActive(bool active) {
    if (_disposed || active == _active) return;
    _active = active;
    if (!active) {
      _inactiveSince = DateTime.now();
      return;
    }
    for (final server in _servers.values) {
      if (server.suspended) _wake(server);
    }
  }

  /// Java 服务端(jdtls)的 JVM 参数:换成 ParallelGC 并调低垃圾回收的时间占比,空闲时把堆还给系统
  /// (默认的 G1 撑大了就不太还);不用内存映射读 jar,依赖多的项目常驻内存少一截。同 VS Code 的 Java 插件。
  static const List<String> jvmMemoryFlags = [
    '-XX:+UseParallelGC',
    '-XX:GCTimeRatio=4',
    '-XX:AdaptiveSizePolicyWeight=90',
    '-Dsun.zip.disableMemoryMapping=true',
  ];

  /// 给 Java 服务端的启动命令补上 [jvmMemoryFlags]:直接跑 `java` 的(插件)插在 java 后面,
  /// Homebrew 的 `jdtls` 启动脚本用 `--jvm-arg=`;已经指定了垃圾回收器 / 同名参数的不重复加。其它命令原样返回。
  static List<String> withJvmMemoryFlags(List<String> argv) {
    if (argv.isEmpty) return argv;
    final exe = argv.first.split(RegExp(r'[/\\]')).last.toLowerCase();
    final isJava = exe == 'java' || exe == 'java.exe';
    final isScript = exe == 'jdtls' || exe == 'jdtls.bat' || exe == 'jdtls.cmd';
    if (!isJava && !isScript) return argv;
    String bare(String a) => a.startsWith('--jvm-arg=') ? a.substring(10) : a;
    final given = argv.map(bare).toList();
    final hasGc = given.any((a) => RegExp(r'^-XX:\+Use\w*GC$').hasMatch(a));
    final missing = [
      for (final f in jvmMemoryFlags)
        if (!(f.endsWith('GC') && hasGc) && !given.any((a) => a.split('=').first == f.split('=').first)) f,
    ];
    if (missing.isEmpty) return argv;
    return [argv.first, ...isJava ? missing : missing.map((f) => '--jvm-arg=$f'), ...argv.sublist(1)];
  }

  /// 工作区根目录(绝对路径)。
  final String root;

  /// 不起任何语言服务端(单独打开一个文件时:不能拿它所在的目录当工程去索引),全部走降级(语法树大纲、括号检查)。
  final bool disabled;

  /// 单个请求的超时;超时后结果按 null 处理(documentSymbols 随即降级到正则大纲)。
  final Duration requestTimeout;

  /// initialize 的超时;超时视为服务端不可用,该语言转入降级。
  final Duration initializeTimeout;

  /// jdtls 工作区缓存的父目录;默认 ~/.codelitex/jdtls(测试里换成临时目录)。
  final String? jdtlsDataRoot;

  /// 插件提供的启动方式(优先于系统里找到的命令;serverOverrides 仍最优先)。
  final LspLaunchResolver? launchResolver;

  /// 崩溃后最多重启次数,超过即停在降级模式。
  static const int maxRestarts = 3;

  final Map<String, List<String>> _overrides;
  final Map<String, _Server> _servers = {};
  final Map<String, _Doc> _docs = {};
  final Map<String, String> _uriToRel = {};
  final StreamController<LspDiagnosticsEvent> _events = StreamController<LspDiagnosticsEvent>.broadcast();
  String? _resolvedRoot;
  bool _disposed = false;

  /// 诊断推送(广播流)。path 为工作区相对路径,与编辑器使用的路径一致。
  Stream<LspDiagnosticsEvent> get diagnostics => _events.stream;

  /// 按扩展名给出 languageId;只覆盖会路由到语言服务端的语言。
  static String? languageIdFor(String path) => lspLanguageIdFor(path);

  // =========================================================================
  // 文档同步
  // =========================================================================

  Future<void> didOpen(String relPath, String text) async {
    try {
      if (_disposed) return;
      final existing = _docs[relPath];
      if (existing != null) {
        // 重复打开等价于整篇更新,避免服务端收到同一 URI 的第二次 didOpen 而报错。
        existing.temporary = false;
        await didChange(relPath, text);
        return;
      }
      final lang = languageIdFor(relPath);
      _docs[relPath] = _Doc(lang, text);
      if (lang == null) {
        _emitFallback(relPath, text, lspFallbackLanguageFor(relPath));
        return;
      }
      final server = _serverFor(lang);
      if (server == null || server.fallback) {
        _emitFallback(relPath, text, lang);
        return;
      }
      final proc = server.ready;
      if (proc != null) _sendDidOpen(proc, relPath, _docs[relPath]!);
      // 挂起着:拉起来(启动后重放全部打开的文档)
      if (server.suspended) _wake(server);
      // 仍在启动中:initialize 成功后统一重放。
    } catch (_) {}
  }

  /// 整篇同步(TextDocumentSyncKind.Full),version 递增。
  Future<void> didChange(String relPath, String text) async {
    try {
      if (_disposed) return;
      final doc = _docs[relPath];
      if (doc == null) {
        await didOpen(relPath, text);
        return;
      }
      doc.text = text;
      doc.version++;
      final lang = doc.languageId;
      if (lang == null) {
        _emitFallback(relPath, text, lspFallbackLanguageFor(relPath));
        return;
      }
      final server = _servers[lspServerGroupFor(lang)];
      if (server == null || server.fallback) {
        _emitFallback(relPath, text, lang);
        return;
      }
      server.ready?.notify('textDocument/didChange', {
        'textDocument': {'uri': _uriFor(relPath), 'version': doc.version},
        'contentChanges': [
          {'text': text},
        ],
      });
    } catch (_) {}
  }

  /// 增量同步:把这段时间的改动按顺序发给服务端(服务端声明支持增量时只发改动的范围,
  /// 否则仍发全文)。本地保存的文档内容同步更新,服务端重启时据此重放。
  /// 文档还没打开时返回 false,调用方应改用整篇 [didChange]。
  Future<bool> didChangeIncremental(String relPath, List<LspTextChange> changes) async {
    try {
      if (_disposed) return true;
      final doc = _docs[relPath];
      if (doc == null) return false;
      if (changes.isEmpty) return true;
      doc.text = lspApplyChanges(doc.text, changes);
      doc.version++;
      final lang = doc.languageId;
      if (lang == null) {
        _emitFallback(relPath, doc.text, lspFallbackLanguageFor(relPath));
        return true;
      }
      final server = _servers[lspServerGroupFor(lang)];
      if (server == null || server.fallback) {
        _emitFallback(relPath, doc.text, lang);
        return true;
      }
      // 还在启动:initialize 后会按 doc.text 重放 didOpen。
      server.ready?.notify('textDocument/didChange', {
        'textDocument': {'uri': _uriFor(relPath), 'version': doc.version},
        'contentChanges': server.syncKind == 2
            ? [for (final c in changes) c.toJson()]
            : [
                {'text': doc.text},
              ],
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// initialize 结果里的 textDocumentSync:数字,或 `{change: 数字}`。
  static int _syncKindOf(Object? capabilities) {
    if (capabilities is! Map) return 1;
    final sync = capabilities['textDocumentSync'];
    final kind = sync is num ? sync : (sync is Map ? sync['change'] : null);
    return kind is num && kind.toInt() == 2 ? 2 : 1;
  }

  /// 重启某个分组的语言服务器(插件装好 / 卸载 / 启停之后):按新的启动方式重新拉起,
  /// 并为该分组已打开的文档重放 didOpen;没有可用服务端时这些文档转入降级诊断。
  ///
  /// 共用的服务端:旧进程先摘掉登记(之后接入的项目开新的),等共用它的项目都各自重启过(插件管理器对每个项目都会调一次)
  /// 才关掉 —— 整个组只重启一次。
  Future<void> reloadServer(String group) async {
    if (_disposed) return;
    final old = _servers[group];
    if (old != null && old.shareKey != null && identical(_shared['$group|${old.shareKey}'], old)) {
      _shared.remove('$group|${old.shareKey}');
    }
    await _rejoin(group, retire: true);
  }

  /// 项目换了项目组(或组删了):离开现在共用的服务端,接入新组的(或自己单开一个)。
  Future<void> reattachServer(String group) async {
    if (_disposed) return;
    final current = _servers[group];
    if (current != null && current.shareKey == _shareKey(group)) return; // 没变
    await _rejoin(group, retire: false);
  }

  Future<void> _rejoin(String group, {required bool retire}) async {
    final old = _servers.remove(group);
    if (old != null) await _leave(old, retire: retire);
    _Server? server;
    for (final e in _docs.entries) {
      final lang = e.value.languageId;
      if (lang == null || lspServerGroupFor(lang) != group) continue;
      server ??= _serverFor(lang);
      if (server == null || server.fallback) _emitFallback(e.key, e.value.text, lang);
    }
  }

  /// 这个项目不再用 [server]:最后一个离开的关掉进程;别的项目还在用时只撤回自己的文档和工作区目录。
  Future<void> _leave(_Server server, {bool retire = false}) async {
    server.clients.remove(this);
    if (server.closed) {
      server.retired = true;
      server.idleTimer?.cancel();
      final key = '${server.group}|${server.shareKey}';
      if (identical(_shared[key], server)) _shared.remove(key);
      await _shutdown(server);
      return;
    }
    final proc = server.ready;
    if (proc == null) return; // 没在跑:下次启动时本来就不会带上这个项目
    for (final e in _docs.entries) {
      final lang = e.value.languageId;
      if (lang == null || lspServerGroupFor(lang) != server.group) continue;
      proc.notify('textDocument/didClose', {
        'textDocument': {'uri': _uriFor(e.key)},
      });
    }
    proc.notify('workspace/didChangeWorkspaceFolders', {
      'event': {'added': const [], 'removed': [_folder()]},
    });
  }

  Future<void> didClose(String relPath) async {
    try {
      if (_disposed) return;
      final doc = _docs.remove(relPath);
      if (doc == null) return;
      final group = doc.languageId == null ? null : lspServerGroupFor(doc.languageId!);
      _servers[group]?.ready?.notify('textDocument/didClose', {
        'textDocument': {'uri': _uriFor(relPath)},
      });
      // 关闭后清掉该文件的诊断,避免 UI 残留过期标记。
      _emit(relPath, const []);
    } catch (_) {}
  }

  // =========================================================================
  // 大纲
  // =========================================================================

  /// LSP documentSymbol;服务端不可用、超时或返回空时退回语法树大纲(Rust 的 tree-sitter,
  /// Java / Dart / JS / TS / Python / Go / Rust),再不行用正则大纲。
  Future<List<Map<String, dynamic>>> documentSymbols(String relPath, String text) async {
    Future<List<Map<String, dynamic>>> fallback() async {
      try {
        final tree = await rustOutline(relPath, text);
        if (tree != null) return tree;
      } catch (_) {}
      try {
        return lspRegexOutline(text, lspFallbackLanguageFor(relPath));
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    }

    try {
      if (_disposed) return await fallback();
      final lang = languageIdFor(relPath);
      if (lang == null) return await fallback();
      final server = _serverFor(lang);
      if (server == null || server.fallback) return await fallback();

      // 服务端只认识已打开的文档(tsserver 尤其如此):未打开就临时打开,用完关闭。
      _Doc? temp;
      final doc = _docs[relPath];
      if (doc == null) {
        temp = _docs[relPath] = _Doc(lang, text)..temporary = true;
        final proc = server.ready;
        if (proc != null) _sendDidOpen(proc, relPath, temp);
      } else if (doc.text != text) {
        await didChange(relPath, text);
      }

      final result = await _request(server, 'textDocument/documentSymbol', {
        'textDocument': {'uri': _uriFor(relPath)},
      });

      if (temp != null && temp.temporary && identical(_docs[relPath], temp)) {
        _docs.remove(relPath);
        server.ready?.notify('textDocument/didClose', {
          'textDocument': {'uri': _uriFor(relPath)},
        });
      }

      final symbols = lspParseDocumentSymbols(result, languageId: lang);
      return symbols.isEmpty ? await fallback() : symbols;
    } catch (_) {
      return await fallback();
    }
  }

  // =========================================================================
  // 状态 / 释放
  // =========================================================================

  /// `{"servers":[{"language","command","state":"running|missing|crashed", ...}]}`。
  /// 启动/重启中的服务端也报 running(附 initialized=false)。
  Future<Map<String, dynamic>> status() async {
    try {
      final servers = <Map<String, dynamic>>[];
      for (final s in _servers.values) {
        final proc = s.proc;
        servers.add({
          'language': s.group,
          'command': s.argv.join(' '),
          'state': switch (s.state) {
            _State.starting || _State.running => 'running',
            _State.missing => 'missing',
            _State.crashed => 'crashed',
            _State.suspended => 'suspended',
          },
          if (s.shareKey != null) 'shared': s.shareKey,
          'projects': s.clients.length,
          'initialized': s.ready != null,
          'restarts': s.restarts,
          if (s.source != null) 'source': s.source,
          if (proc != null && !proc.exited) 'pid': proc.process.pid,
          if (s.lastError != null) 'error': s.lastError,
        });
      }
      return {'servers': servers};
    } catch (_) {
      return {'servers': <Map<String, dynamic>>[]};
    }
  }

  /// 对所有服务端 shutdown + exit;不配合的进程超时后强杀。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await Future.wait([for (final s in _servers.values) _leave(s)]);
    } catch (_) {}
    _servers.clear();
    try {
      await _events.close();
    } catch (_) {}
  }

  Future<void> _shutdown(_Server server) async {
    try {
      _failQueue(server);
      final proc = server.proc;
      if (proc == null || proc.exited) return;
      if (proc.initialized) {
        await proc.request('shutdown', null, const Duration(seconds: 2));
        proc.notify('exit');
      }
      try {
        await proc.process.stdin.close().timeout(const Duration(milliseconds: 500));
      } catch (_) {}
      final exited = await proc.process.exitCode
          .then((_) => true)
          .timeout(const Duration(milliseconds: 1500), onTimeout: () => false);
      if (!exited) {
        proc.process.kill(ProcessSignal.sigkill);
        await proc.process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
      }
      proc.failPending();
      await proc.stdoutSub?.cancel();
      await proc.stderrSub?.cancel();
    } catch (_) {}
  }

  // =========================================================================
  // 服务端生命周期
  // =========================================================================

  /// 取(必要时创建并启动)languageId 所属分组的服务端;未路由的语言返回 null。
  _Server? _serverFor(String languageId) {
    if (disabled) return null;
    final group = lspServerGroupFor(languageId);
    if (group == null) return null;
    final existing = _servers[group];
    if (existing != null) return existing;
    // 同一个项目组的已经开着一个:接进去(把这个项目的目录加进它的工作区)
    final key = _shareKey(group);
    if (key != null) {
      final shared = _shared['$group|$key'];
      if (shared != null && !shared.retired && !shared.closed) {
        shared.clients.add(this);
        _servers[group] = shared;
        shared.ready?.notify('workspace/didChangeWorkspaceFolders', {
          'event': {'added': [_folder()], 'removed': const []},
        });
        if (shared.suspended) _wake(shared);
        return shared;
      }
    }
    final server = _Server(group)..shareKey = key;
    server.clients.add(this);
    _servers[group] = server;
    if (key != null) _shared['$group|$key'] = server;
    final launch = _overrides.isEmpty
        ? (key != null && sharedLaunchResolver != null ? sharedLaunchResolver!(group, _sharedDataRoot(key)) : null) ??
            launchResolver?.call(group)
        : null;
    if (launch != null && launch.argv.isNotEmpty && _findExecutable(launch.argv.first) != null) {
      server
        ..argv = launch.argv
        ..env = launch.env
        ..initializeTimeout = launch.initializeTimeout
        ..requestTimeout = launch.requestTimeout
        ..source = launch.source ?? 'plugin';
      unawaited(_start(server));
      return server;
    }
    final argv = _resolveCommand(group);
    if (argv == null) {
      server.state = _State.missing;
      server.argv = _commandFor(group).first;
      server.lastError = tr('找不到语言服务器', 'language server not found');
      return server;
    }
    server.argv = argv;
    unawaited(_start(server));
    return server;
  }

  /// [group] 这个分组在这个项目里用的共用键;不共用返回 null。
  String? _shareKey(String group) => sharedGroups.contains(group) ? shareKeyFor?.call(root) : null;

  /// 项目组的服务端缓存目录名用的路径(只用来起名字,不是真的目录)。
  static String _sharedDataRoot(String key) => '/codelitex-project-group/group-$key';

  Map<String, String> _folder() {
    final name = root.split(RegExp(r'[/\\]')).lastWhere((s) => s.isNotEmpty, orElse: () => root);
    return {'uri': Uri.file(root).toString(), 'name': name};
  }

  /// 挂起的服务端重新拉起(切回项目 / 有请求 / 打开文件)。
  void _wake(_Server server) {
    if (!server.suspended || server.closed) return;
    server.state = _State.starting;
    unawaited(server.host._start(server));
  }

  /// 每隔一会儿看一眼:共用这个服务端的项目都切走超过 [idleTimeout] 了,就停掉进程(挂起)。
  void _armIdle(_Server server) {
    server.idleTimer?.cancel();
    server.idleTimer = Timer.periodic(idleCheckInterval, (_) => unawaited(_checkIdle(server)));
  }

  static Future<void> _checkIdle(_Server server) async {
    if (server.closed || server.state != _State.running) return;
    final now = DateTime.now();
    for (final c in server.clients) {
      if (c._active || now.difference(c._inactiveSince) < idleTimeout) return;
    }
    server.state = _State.suspended;
    server.idleTimer?.cancel();
    server.idleTimer = null;
    await server.host._shutdown(server);
  }

  Future<void> _start(_Server server) async {
    if (server.closed) return;
    server.state = _State.starting;
    final Process process;
    try {
      final env = <String, String>{'PATH': _searchDirs().join(Platform.isWindows ? ';' : ':'), ...server.env};
      var argv = server.argv;
      if (server.group == 'java' && !server.fromPlugin) {
        // jdtls 需要 Java 21+ 运行;找不到时交给它自己报错(会进入降级)。
        final javaHome = findJavaHome(minVersion: 21);
        if (javaHome != null) {
          env['JAVA_HOME'] = javaHome;
          env['PATH'] = '$javaHome/bin${Platform.isWindows ? ';' : ':'}${env['PATH']}';
        }
        if (!argv.contains('-data')) argv = [...argv, '-data', _jdtlsDataDir(server.shareKey)];
      }
      if (server.group == 'java') argv = withJvmMemoryFlags(argv);
      process = await Process.start(
        argv.first,
        argv.sublist(1),
        workingDirectory: root,
        environment: env,
        runInShell: Platform.isWindows && RegExp(r'\.(cmd|bat)$', caseSensitive: false).hasMatch(server.argv.first),
      );
    } catch (e) {
      server.lastError = tr('启动失败: $e', 'failed to start: $e');
      _onCrash(server);
      return;
    }
    final proc = _Proc(process);
    server.proc = proc;
    if (server.closed || server.retired) {
      process.kill(ProcessSignal.sigkill);
      return;
    }

    proc.stdoutSub = process.stdout.listen(
      (chunk) {
        for (final body in proc.parser.add(chunk)) {
          _onMessage(server, proc, body);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
    proc.stderrSub = process.stderr.listen(
      (chunk) {
        final text = utf8.decode(chunk, allowMalformed: true);
        for (final line in const LineSplitter().convert(text)) {
          if (line.trim().isEmpty) continue;
          proc.stderrTail.add(line);
          if (proc.stderrTail.length > 20) proc.stderrTail.removeAt(0);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
    unawaited(process.stdin.done.catchError((_) {}));
    unawaited(process.exitCode.then((code) => _onExit(server, proc, code)));

    // jdtls 首次打开大 Maven / Gradle 项目要先建索引,initialize 应答明显更慢。
    final timeout = server.initializeTimeout ?? (server.group == 'java' ? const Duration(minutes: 3) : initializeTimeout);
    final result = await proc.request('initialize', _initializeParams(server), timeout);
    if (server.closed || server.proc != proc || proc.exited) return; // 退出由 _onExit 处理
    if (result is! Map) {
      // 初始化超时或报错:服务端没救了,直接降级,不再重试。
      server.lastError = tr('初始化失败或超时', 'initialize failed or timed out');
      server.state = _State.crashed;
      proc.process.kill(ProcessSignal.sigkill);
      _enterFallback(server);
      return;
    }

    server.syncKind = _syncKindOf(result['capabilities']);
    proc.notify('initialized', <String, Object?>{});
    proc.initialized = true;
    server.state = _State.running;
    // 按当前内容重放该分组的全部打开文档(首次启动、崩溃重启、挂起后拉起共用;共用时是每个项目的)。
    for (final c in server.clients) {
      for (final e in c._docs.entries) {
        final lang = e.value.languageId;
        if (lang != null && lspServerGroupFor(lang) == server.group) c._sendDidOpen(proc, e.key, e.value);
      }
    }
    _armIdle(server);
    final queued = List.of(server.queue);
    server.queue.clear();
    for (final op in queued) {
      op(proc);
    }
  }

  void _onExit(_Server server, _Proc proc, int code) {
    proc.exited = true;
    proc.failPending();
    if (server.closed || server.retired || server.proc != proc || server.fallback || server.suspended) return;
    final tail = proc.stderrTail.isEmpty ? '' : ': ${proc.stderrTail.last}';
    server.lastError = tr('已退出(退出码 $code)$tail', 'exited with code $code$tail');
    // rustup 代理在组件未安装时以错误退出:本质是「没装」,不必反复重启。
    if (!proc.initialized && proc.stderrTail.any((l) => l.contains('Unknown binary') || l.contains('is not installed'))) {
      server.state = _State.missing;
      _enterFallback(server);
      return;
    }
    _onCrash(server);
  }

  void _onCrash(_Server server) {
    if (server.closed || server.retired) return;
    server.restarts++;
    if (server.restarts > maxRestarts) {
      server.state = _State.crashed;
      _enterFallback(server);
      return;
    }
    server.state = _State.starting;
    final delay = Duration(milliseconds: 200 * (1 << (server.restarts - 1)));
    Timer(delay, () {
      if (!server.closed && server.state == _State.starting) unawaited(server.host._start(server));
    });
  }

  /// 转入降级:排队请求以 null 结束,并为该分组已打开的文档补发降级诊断。
  void _enterFallback(_Server server) {
    _failQueue(server);
    for (final c in server.clients) {
      for (final e in c._docs.entries) {
        final lang = e.value.languageId;
        if (lang != null && lspServerGroupFor(lang) == server.group) c._emitFallback(e.key, e.value.text, lang);
      }
    }
  }

  void _failQueue(_Server server) {
    final queued = List.of(server.queue);
    server.queue.clear();
    for (final op in queued) {
      try {
        op(null);
      } catch (_) {}
    }
  }

  Future<Object?> _request(_Server server, String method, Object? params) {
    if (server.fallback || _disposed || server.closed) return Future.value(null);
    final c = Completer<Object?>();
    void op(_Proc? proc) {
      if (proc == null) {
        if (!c.isCompleted) c.complete(null);
        return;
      }
      proc.request(method, params, server.requestTimeout ?? requestTimeout).then((r) {
        if (!c.isCompleted) c.complete(r);
      });
    }

    final proc = server.ready;
    if (proc != null) {
      op(proc);
    } else {
      server.queue.add(op);
      if (server.suspended) _wake(server);
    }
    return c.future.timeout(server.requestTimeout ?? requestTimeout, onTimeout: () => null);
  }

  void _sendDidOpen(_Proc proc, String relPath, _Doc doc) {
    proc.notify('textDocument/didOpen', {
      'textDocument': {
        'uri': _uriFor(relPath),
        'languageId': doc.languageId,
        'version': doc.version,
        'text': doc.text,
      },
    });
  }

  Map<String, Object?> _initializeParams(_Server server) {
    final rootUri = Uri.file(root).toString();
    return {
      'processId': pid,
      'clientInfo': {'name': 'CodeLiteX'},
      'rootPath': root,
      'rootUri': rootUri,
      // 共用时是组里每个项目的目录
      'workspaceFolders': [for (final c in server.clients) c._folder()],
      'capabilities': {
        'general': {
          'positionEncodings': ['utf-16'],
        },
        'workspace': {
          'workspaceFolders': true,
          'configuration': true,
        },
        'window': {'workDoneProgress': false},
        'textDocument': {
          'synchronization': {'dynamicRegistration': false, 'willSave': false, 'didSave': false},
          // tagSupport:服务端据此才会给「未使用」的符号打 Unnecessary 标记(jdtls、rust-analyzer、gopls 都认)
          'publishDiagnostics': {
            'relatedInformation': false,
            'tagSupport': {'valueSet': [1, 2]},
          },
          'documentSymbol': {
            'dynamicRegistration': false,
            'hierarchicalDocumentSymbolSupport': true,
            'symbolKind': {'valueSet': List<int>.generate(26, (i) => i + 1)},
          },
        },
      },
    };
  }

  // =========================================================================
  // 消息处理
  // =========================================================================

  void _onMessage(_Server server, _Proc proc, String body) {
    try {
      final msg = jsonDecode(body);
      if (msg is! Map) return;
      final method = msg['method'];
      final id = msg['id'];
      if (method is String) {
        if (id != null) {
          _answerServerRequest(server, proc, id, method, msg['params']);
        } else if (method == 'textDocument/publishDiagnostics') {
          // 共用时每个项目只认自己目录下的文件
          for (final c in List.of(server.clients)) {
            c._onPublishDiagnostics(msg['params']);
          }
        }
        return;
      }
      if (id is num) {
        final c = proc.pending.remove(id.toInt());
        if (c != null && !c.isCompleted) c.complete(msg.containsKey('error') ? null : msg['result']);
      }
    } catch (_) {}
  }

  /// 服务端 → 客户端的请求必须应答,否则 rust-analyzer / gopls 等会一直等待。
  void _answerServerRequest(_Server server, _Proc proc, Object id, String method, Object? params) {
    Object? result;
    switch (method) {
      case 'workspace/configuration':
        final items = params is Map && params['items'] is List ? params['items'] as List : const [];
        result = List<Object?>.filled(items.length, null);
      case 'window/workDoneProgress/create':
      case 'client/registerCapability':
      case 'client/unregisterCapability':
      case 'window/showMessageRequest':
      case 'window/showDocument':
        result = null;
      case 'workspace/workspaceFolders':
        result = [for (final c in server.clients) c._folder()];
      case 'workspace/applyEdit':
        result = {'applied': false};
      default:
        proc.send({
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        });
        return;
    }
    proc.send({'id': id, 'result': result});
  }

  void _onPublishDiagnostics(Object? params) {
    if (params is! Map) return;
    final uri = params['uri'];
    final list = params['diagnostics'];
    if (uri is! String || list is! List) return;
    final rel = _relFromUri(uri);
    if (rel == null) return;
    final diags = <Map<String, dynamic>>[];
    for (final d in list) {
      if (d is Map) diags.add(Map<String, dynamic>.from(d));
    }
    _emit(rel, diags);
  }

  void _emit(String relPath, List<Map<String, dynamic>> diagnostics) {
    if (_disposed || _events.isClosed) return;
    _events.add(LspDiagnosticsEvent(relPath, diagnostics));
  }

  void _emitFallback(String relPath, String text, String? languageId) {
    if (languageId == null) return; // 非代码文件不做括号检查
    try {
      _emit(relPath, lspBracketDiagnostics(text, languageId));
    } catch (_) {}
  }

  // =========================================================================
  // 路径 / URI
  // =========================================================================

  String _absPath(String relPath) {
    if (relPath.startsWith('/') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(relPath)) return relPath;
    final base = root.endsWith('/') || root.endsWith('\\') ? root.substring(0, root.length - 1) : root;
    final rel = Platform.isWindows ? relPath.replaceAll('/', '\\') : relPath;
    return '$base${Platform.pathSeparator}$rel';
  }

  String _uriFor(String relPath) {
    final uri = Uri.file(_absPath(relPath)).toString();
    _uriToRel[uri] = relPath;
    return uri;
  }

  /// 服务端回传的 URI → 工作区相对路径。先查自己发出去的 URI;否则解码后去掉根前缀
  /// (macOS 上服务端常把 /var 规范化成 /private/var,所以也比对 resolve 过的根)。工作区外返回 null。
  String? _relFromUri(String uri) {
    final known = _uriToRel[uri];
    if (known != null) return known;
    String path;
    try {
      path = Uri.parse(uri).toFilePath();
    } catch (_) {
      return null;
    }
    for (final base in [root, _resolvedRoot]) {
      if (base == null || base.isEmpty) continue;
      final b = base.endsWith('/') || base.endsWith('\\') ? base.substring(0, base.length - 1) : base;
      if (path.startsWith(b) && path.length > b.length + 1 && (path[b.length] == '/' || path[b.length] == '\\')) {
        return path.substring(b.length + 1).replaceAll('\\', '/');
      }
    }
    return null;
  }

  static String? _tryResolve(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // 服务端二进制查找
  // =========================================================================

  List<List<String>> _commandFor(String group) {
    final override = _overrides[group] ??
        lspServerGroupLanguages[group]!.map((l) => _overrides[l]).firstWhere((o) => o != null, orElse: () => null);
    if (override != null && override.isNotEmpty) return [override];
    return lspServerCandidates[group] ?? const [];
  }

  /// 依次尝试候选命令,返回首个能找到可执行文件的 argv(argv[0] 已解析为绝对路径)。
  List<String>? _resolveCommand(String group) {
    for (final argv in _commandFor(group)) {
      final exe = _findExecutable(argv.first);
      if (exe != null) return [exe, ...argv.sublist(1)];
    }
    return null;
  }

  /// 搜索目录:PATH 之外补上常见安装位置。Finder 启动的 macOS app 的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin,
  /// 只靠 PATH 会找不到 cargo/homebrew/go/nvm 装的服务端。这份目录列表同时作为子进程的 PATH,
  /// 让 `#!/usr/bin/env node` 之类的脚本型服务端也能找到解释器。
  /// 找可执行文件用的目录:PATH 之外补上常见安装位置(插件安装器也用它找 go / npm 等)。
  static List<String> searchDirs() => _searchDirsImpl();

  /// 在 [searchDirs] 里找命令;传入路径时检查文件是否存在。
  static String? findExecutable(String name) => _findExecutableImpl(name);

  List<String> _searchDirs() => _searchDirsImpl();

  String? _findExecutable(String name) => _findExecutableImpl(name);

  static List<String> _searchDirsImpl() {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    final dirs = <String>[
      ...(env['PATH'] ?? '').split(sep).where((d) => d.isNotEmpty),
      if (home.isNotEmpty) '$home/.cargo/bin',
      '/opt/homebrew/bin',
      '/usr/local/bin',
      if (home.isNotEmpty) '$home/go/bin',
      if (env['GOPATH'] != null) '${env['GOPATH']}/bin',
      // gopls 运行时要调用 go 命令:官方安装包放在 /usr/local/go,Homebrew 的在 /opt/homebrew/bin
      if (env['GOROOT'] != null) '${env['GOROOT']}/bin',
      '/usr/local/go/bin',
      if (home.isNotEmpty) '$home/.local/bin',
      if (home.isNotEmpty) '$home/.npm-global/bin',
      ..._nvmBins(home),
      ..._dartDirs(env, home),
      '/usr/bin',
      '/bin',
    ];
    final seen = <String>{};
    return dirs.where(seen.add).toList();
  }

  /// jdtls 的工作区缓存(索引、项目导入结果):每个项目一份,放在 ~/.codelitex/jdtls 下,不写进项目目录。
  /// 项目组共用的服务端一个组一份([shareKey])。
  String _jdtlsDataDir([String? shareKey]) {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    final parent = jdtlsDataRoot ?? '$home/.codelitex/jdtls';
    final root = shareKey == null ? this.root : _sharedDataRoot(shareKey);
    final name = root.split(RegExp(r'[/\\]')).lastWhere((s) => s.isNotEmpty, orElse: () => 'workspace');
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    // 同名项目在不同位置时用路径哈希区分
    final hash = root.codeUnits.fold<int>(17, (h, c) => (h * 31 + c) & 0x7fffffff).toRadixString(16);
    final dir = Directory('$parent/$safe-$hash');
    try {
      dir.createSync(recursive: true);
    } catch (_) {}
    return dir.path;
  }

  /// 找一个版本 ≥ [minVersion] 的 JDK(JAVA_HOME → Homebrew → 系统安装位置),返回其 home 目录。
  /// 依据 JDK 根目录下 `release` 文件里的 JAVA_VERSION。
  static String? findJavaHome({int minVersion = 21}) {
    final env = Platform.environment;
    final candidates = <String>[
      if (env['JAVA_HOME'] != null) env['JAVA_HOME']!,
    ];
    void addJdks(String parent, String suffix) {
      try {
        final d = Directory(parent);
        if (!d.existsSync()) return;
        for (final e in d.listSync().whereType<Directory>()) {
          candidates.add('${e.path}$suffix');
        }
      } catch (_) {}
    }

    addJdks('/opt/homebrew/opt', '/libexec/openjdk.jdk/Contents/Home');
    addJdks('/usr/local/opt', '/libexec/openjdk.jdk/Contents/Home');
    addJdks('/Library/Java/JavaVirtualMachines', '/Contents/Home');
    addJdks('/usr/lib/jvm', '');
    String? best;
    var bestVersion = 0;
    for (final home in candidates) {
      final v = javaMajorVersion(home);
      if (v != null && v >= minVersion && v > bestVersion) {
        best = home;
        bestVersion = v;
      }
    }
    return best;
  }

  /// JDK 主版本号(读 `<home>/release` 的 JAVA_VERSION;1.8 记作 8)。读不到返回 null。
  static int? javaMajorVersion(String home) {
    try {
      final f = File('$home/release');
      if (!f.existsSync() || !File('$home/bin/java').existsSync()) return null;
      final m = RegExp(r'JAVA_VERSION="(\d+)(?:\.(\d+))?').firstMatch(f.readAsStringSync());
      if (m == null) return null;
      final major = int.parse(m.group(1)!);
      return major == 1 ? int.tryParse(m.group(2) ?? '') : major;
    } catch (_) {
      return null;
    }
  }

  /// nvm 安装的 node 及全局 npm 包(typescript-language-server / vtsls / pyright),新版本优先。
  static List<String> _nvmBins(String home) {
    if (home.isEmpty) return const [];
    try {
      final dir = Directory('$home/.nvm/versions/node');
      if (!dir.existsSync()) return const [];
      final versions = dir.listSync().whereType<Directory>().map((d) => d.path).toList()..sort();
      return versions.reversed.map((v) => '$v/bin').toList();
    } catch (_) {
      return const [];
    }
  }

  /// `dart language-server` 需要 Dart SDK:优先 FLUTTER_ROOT 自带的 SDK,其次 PATH/常见位置上的 flutter 旁边那份。
  static List<String> _dartDirs(Map<String, String> env, String home) {
    final roots = <String>[
      if (env['FLUTTER_ROOT'] != null) env['FLUTTER_ROOT']!,
      if (home.isNotEmpty) '$home/development/flutter',
      if (home.isNotEmpty) '$home/flutter',
      if (home.isNotEmpty) '$home/fvm/default',
    ];
    return [
      if (env['DART_SDK'] != null) '${env['DART_SDK']}/bin',
      for (final r in roots) ...['$r/bin/cache/dart-sdk/bin', '$r/bin'],
    ];
  }

  static String? _findExecutableImpl(String name) {
    try {
      if (name.contains('/') || name.contains('\\')) {
        return File(name).existsSync() ? name : null;
      }
      final exts = Platform.isWindows ? const ['.exe', '.cmd', '.bat', ''] : const [''];
      for (final dir in _searchDirsImpl()) {
        for (final ext in exts) {
          final candidate = '$dir${Platform.pathSeparator}$name$ext';
          final type = FileSystemEntity.typeSync(candidate);
          if (type == FileSystemEntityType.file || type == FileSystemEntityType.link) {
            if (type == FileSystemEntityType.link && !File(candidate).existsSync()) continue; // 断链
            return candidate;
          }
        }
      }
    } catch (_) {}
    return null;
  }
}
