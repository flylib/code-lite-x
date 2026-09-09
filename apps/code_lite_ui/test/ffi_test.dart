import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_lite_ui/core/ffi/codelite_bindings.dart';
import 'package:code_lite_ui/core/client/api_client.dart';

void main() {
  group('CodeLiteX Rust C-ABI FFI & Client Tests', () {
    test('CodeLiteBindings initializes and calls C-ABI library', () {
      final ffi = CodeLiteBindings.instance;
      final ok = ffi.initialize('.');

      // If libcodelite.dylib is compiled in target/debug, verify direct FFI execution
      if (ok) {
        expect(ffi.isAvailable, isTrue);

        final version = ffi.getVersion();
        expect(version, equals('0.1.0'));

        final tree = ffi.scanWorkspace(maxDepth: 2);
        expect(tree.containsKey('name'), isTrue);

        final fileRes = ffi.openFile('pubspec.yaml');
        expect(fileRes['status'], equals('ok'));
        expect((fileRes['content'] as String).contains('code_lite_ui'), isTrue);

        final events = ffi.fetchEvents();
        expect(events, isA<List>());

        final symbols = ffi.fetchSymbols();
        expect(symbols, isA<List>());

        final promptRes = ffi.sendAgentPrompt('test-sess', 'buffer');
        expect(promptRes['status'], equals('ok'));
        expect(promptRes.containsKey('task_id'), isTrue);

        final restoreRes = ffi.restoreAgent('test-sess');
        expect(restoreRes['status'], equals('ok'));

        // Test Phase 1 CodeGraph bindings
        final indexRes = ffi.indexFile('lib/main.dart');
        expect(indexRes['status'], equals('ok'));

        final outline = ffi.queryOutline('lib/main.dart');
        expect(outline, isA<List>());
        expect(outline.isNotEmpty, isTrue);

        final defs = ffi.findDefinition('main');
        expect(defs, isA<List>());

        final ctx = ffi.getCodeContext('main');
        expect(ctx.containsKey('symbol_key'), isTrue);
        expect(ctx['name'], equals('main'));

        final callers = ffi.findCallers('main');
        expect(callers, isA<List>());

        // Test Phase 2 LSP bindings (P2.1 - P2.6)
        const sampleCode = 'pub fn add(a: i32, b: i32) -> i32 { a + b }\nfn test() { let r = add(1, 2); }';
        final lspDiags = ffi.lspDidOpen('src/math.rs', 'rust', sampleCode);
        expect(lspDiags, isA<List>());

        final lspDef = ffi.lspGotoDefinition('src/math.rs', 1, 23);
        expect(lspDef, isA<List>());

        final lspRefs = ffi.lspFindReferences('src/math.rs', 0, 8);
        expect(lspRefs, isA<List>());

        final lspHover = ffi.lspHover('src/math.rs', 0, 8);
        expect(lspHover, isNotNull);

        final lspComps = ffi.lspCompletion('src/math.rs', 1, 20);
        expect(lspComps, isA<List>());

        final lspRename = ffi.lspRename('src/math.rs', 0, 8, 'sum');
        expect(lspRename, isNotNull);

        // Test Phase 3 Agent Closed Loop & Three-Tier Permissions
        final testTargetFile = 'src/test_mul_${DateTime.now().microsecondsSinceEpoch}.rs';
        final planRes = ffi.agentPlanTask('sess-test-dart', {
          'prompt': 'Add safe multiplier',
          'target_file': testTargetFile,
          'code_patch': 'pub fn mul(a: i32, b: i32) -> i32 { a * b }\n',
        });
        expect(planRes['status'], equals('ok'));
        expect(planRes.containsKey('plan'), isTrue);
        final planId = planRes['plan']['id'] as String;

        // Execute step 1 (read baseline)
        final step1 = ffi.agentExecuteNextStep(planId);
        expect(step1['status'], equals('ok'));

        // Execute step 2 (apply patch -> Suspended for Medium risk approval)
        final step2Pending = ffi.agentExecuteNextStep(planId);
        expect(step2Pending['status'], equals('ok'));
        final execRes = step2Pending['result'] as Map<String, dynamic>;
        expect(execRes['type'], equals('SuspendedForApproval'));
        final reqId = execRes['payload']['request_id'] as String;

        // Approve step 2
        final approveRes = ffi.agentApproveStep(reqId, true);
        expect(approveRes['status'], equals('ok'));

        // Re-execute step 2 (apply patch with undo snapshot & verify)
        final step2 = ffi.agentExecuteNextStep(planId);
        expect(step2['status'], equals('ok'));
        final step2Res = step2['result'] as Map<String, dynamic>;
        expect(step2Res['type'], equals('Completed'));

        // Diff review
        final diffRes = ffi.agentGetDiffReview('sess-test-dart');
        expect(diffRes['status'], equals('ok'));
        expect((diffRes['unified_diff'] as String).contains('pub fn mul'), isTrue);

        // Test Phase 4 Viewport Tokens, Search & Terminal
        final tokens = ffi.getViewportTokens('pubspec.yaml', 0, 10);
        expect(tokens['status'], equals('ok'));
        expect(tokens['lines'], isA<List>());

        final searchRes = ffi.searchWorkspace('dependencies');
        expect(searchRes['status'], equals('ok'));
        expect(searchRes['matches'], isA<List>());

        final termRes = ffi.terminalExec('echo', ['hello_from_dart_ffi']);
        expect(termRes['status'], equals('ok'));
        expect((termRes['stdout'] as String).contains('hello_from_dart_ffi'), isTrue);

        // Test Phase 5 LLM Streaming, Chat Sessions & Git
        final streamStart = ffi.sendPromptStream('test-stream-sess', 'Hello CodeLite');
        expect(streamStart['status'], equals('started'));

        final polledEvents = ffi.pollStreamEvents('test-stream-sess');
        expect(polledEvents, isA<List>());

        final msgs = ffi.listMessages('test-stream-sess');
        expect(msgs, isA<List>());

        final clearRes = ffi.clearMessages('test-stream-sess');
        expect(clearRes['status'], equals('ok'));

        final gitStat = ffi.getGitStatus();
        expect(gitStat.containsKey('branch'), isTrue);
        expect(gitStat.containsKey('changes'), isTrue);

        final gitDiff = ffi.getGitDiff();
        expect(gitDiff.containsKey('diff'), isTrue);

        try {
          final f = File(testTargetFile);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    });

    test('ApiClient connects seamlessly via FFI or fallback', () async {
      final client = ApiClient();
      final tree = await client.fetchWorkspaceTree();
      expect(tree.containsKey('name'), isTrue);

      final file = await client.fetchFile('Cargo.toml');
      expect(file.containsKey('content'), isTrue);

      final events = await client.fetchEvents();
      expect(events, isA<List>());

      final promptRes = await client.sendAgentPrompt('Implement auth token');
      expect(promptRes['status'], equals('ok'));

      // Test ApiClient LSP methods
      final diags = await client.lspGetDiagnostics('src/math.rs');
      expect(diags, isA<List>());

      final completions = await client.lspCompletion('src/math.rs', 0, 0);
      expect(completions, isA<List>());

      // Test ApiClient Phase 3 methods
      final plan = await client.agentPlanTask('Refactor tests');
      expect(plan.containsKey('status'), isTrue);

      final diff = await client.agentGetDiffReview();
      expect(diff.containsKey('status'), isTrue);

      // Test ApiClient Phase 4 methods
      final vp = await client.getViewportTokens('pubspec.yaml', 0, 5);
      expect(vp.containsKey('status'), isTrue);

      final search = await client.searchWorkspace('flutter');
      expect(search.containsKey('status'), isTrue);

      final term = await client.terminalExec('echo', ['hello_apiclient']);
      expect(term.containsKey('status'), isTrue);

      // Test ApiClient Phase 5 methods
      final streamSess = await client.sendPromptStream('test-stream-sess', 'Hello AI streaming');
      expect(streamSess.containsKey('status'), isTrue);

      final sessionMsgs = await client.listMessages('test-stream-sess');
      expect(sessionMsgs, isA<List>());

      final clearSess = await client.clearMessages('test-stream-sess');
      expect(clearSess.containsKey('status'), isTrue);

      final gitInfo = await client.getGitStatus();
      expect(gitInfo.containsKey('branch'), isTrue);

      final gitDiffText = await client.getGitDiff();
      expect(gitDiffText.containsKey('diff'), isTrue);
    });
  });
}
