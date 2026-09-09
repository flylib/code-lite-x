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

        // Phase 9: Multi-file planning & Worktree C-ABI
        final mfRes = ffi.agentPlanMultiFile('ffi-session', {
          'prompt': 'Multi-file ffi test',
          'patches': [
            {'file_path': 'src/a.rs', 'patch': '// a', 'description': 'a'},
            {'file_path': 'src/b.rs', 'patch': '// b', 'description': 'b'},
          ]
        });
        expect(mfRes['status'], equals('ok'));
        expect(mfRes.containsKey('plan'), isTrue);
        expect(mfRes.containsKey('summary'), isTrue);

        final mfPlanId = mfRes['plan']['id'] as String;
        final rbRes = ffi.agentRollbackStep(mfPlanId, 'non-existent-step');
        expect(rbRes.containsKey('status'), isTrue);

        final wtCreateRes = ffi.worktreeCreate('test-wt-task-ffi');
        expect(wtCreateRes.containsKey('status'), isTrue);
        if (wtCreateRes['status'] == 'ok') {
          final wtDiscardRes = ffi.worktreeDiscard('test-wt-task-ffi');
          expect(wtDiscardRes.containsKey('status'), isTrue);
        }

        // Phase 10: Context Engine, Instructions, Memory & Skills C-ABI
        final promptBuild = ffi.buildTaskPrompt('Refactor math logic', focusFile: 'src/math.rs');
        expect(promptBuild.containsKey('status'), isTrue);
        expect(promptBuild['status'], equals('ok'));
        expect(promptBuild.containsKey('prompt'), isTrue);
        expect(promptBuild.containsKey('insights'), isTrue);

        final recDec = ffi.recordDecisionMemory('test-sess', 'approval', 'Modify math.rs', 'Approved by user');
        expect(recDec['status'], equals('ok'));

        final recErr = ffi.recordErrorMemory('test-sess', 'syntax_error', 'Missing semicolon', 'Always check semicolons in Rust', targetPath: 'src/math.rs');
        expect(recErr['status'], equals('ok'));

        final memQuery = ffi.queryMemory('math', targetPath: 'src/math.rs');
        expect(memQuery.containsKey('status'), isTrue);
        expect(memQuery['status'], equals('ok'));

        final skills = ffi.listSkills();
        expect(skills, isA<List>());

        final mcpTools = ffi.listMcpTools();
        expect(mcpTools, isA<List>());

        // Test Phase 11 Auto-Updater bindings (codelite_updater_check, updater_stage, updater_apply)
        const updateManifest = '''
{
  "version": "0.1.1",
  "release_date": "2026-09-10",
  "release_notes": "Phase 11 updater release",
  "platforms": {
    "macos": {
      "strategy": "app_bundle_delta",
      "artifacts": [
        {
          "target_name": "CodeLiteX.app",
          "target_path": "CodeLiteX.app",
          "url": "https://example.com/CodeLiteX.dmg",
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "size_bytes": 2048
        }
      ]
    },
    "linux": {
      "strategy": "component_delta",
      "artifacts": [
        {
          "target_name": "libcodelite.so",
          "target_path": "lib/libcodelite.so",
          "url": "https://example.com/linux.tar.gz",
          "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          "size_bytes": 1024
        }
      ]
    }
  }
}
''';
        final checkRes = ffi.updaterCheck('0.1.0', updateManifest, platform: 'linux');
        expect(checkRes['status'], equals('ok'));
        expect(checkRes['has_update'], isTrue);
        expect(checkRes['latest_version'], equals('0.1.1'));
        expect(checkRes['strategy'], equals('component_delta'));

        const stageDir = '/tmp/test_stage_dart';
        final stageRes = ffi.updaterStage(stageDir, 'abc.bin', 'abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
        expect(stageRes['status'], equals('ok'));
        expect(stageRes['verified'], isTrue);

        const targetDir = '/tmp/test_target_dart';
        final applyRes = ffi.updaterApply(stageDir, targetDir, ['abc.bin'], platform: 'linux');
        expect(applyRes['status'], equals('ok'));

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

      // Test ApiClient Phase 9 methods
      final mfPlan = await client.agentPlanMultiFile('Multi-file refactor', [
        {'file_path': 'src/model.rs', 'patch': 'pub struct Model;', 'description': 'Define model'},
        {'file_path': 'src/service.rs', 'patch': 'use crate::model::Model;', 'description': 'Use model'},
      ]);
      expect(mfPlan.containsKey('status'), isTrue);
      expect(mfPlan['status'], equals('ok'));
      expect(mfPlan.containsKey('plan'), isTrue);

      final rbStep = await client.agentRollbackStep('plan-mock-mf', 'step_1');
      expect(rbStep.containsKey('status'), isTrue);

      final wtCreate = await client.worktreeCreate('task-wt-client');
      expect(wtCreate.containsKey('status'), isTrue);
      if (wtCreate['status'] == 'ok') {
        final wtDiscard = await client.worktreeDiscard('task-wt-client');
        expect(wtDiscard.containsKey('status'), isTrue);
      }

      // Test ApiClient Phase 10 methods
      final promptContext = await client.buildTaskPrompt('Implement neural search');
      expect(promptContext.containsKey('status'), isTrue);
      expect(promptContext['status'], equals('ok'));
      expect(promptContext.containsKey('insights'), isTrue);

      final recDecClient = await client.recordDecisionMemory(
        sessionId: 'test-client-sess',
        decisionType: 'approval',
        subject: 'Allow database migration',
        detail: 'User approved SQLite migration',
      );
      expect(recDecClient['status'], equals('ok'));

      final recErrClient = await client.recordErrorMemory(
        sessionId: 'test-client-sess',
        errorType: 'command_failed',
        summary: 'cargo check failed',
        lesson: 'cargo must use --offline flag',
      );
      expect(recErrClient['status'], equals('ok'));

      final memQueryClient = await client.queryMemory('offline');
      expect(memQueryClient.containsKey('status'), isTrue);
      expect(memQueryClient['status'], equals('ok'));

      final skillsList = await client.listSkills();
      expect(skillsList, isA<List>());
      expect(skillsList.isNotEmpty, isTrue);

      final mcpList = await client.listMcpTools();
      expect(mcpList, isA<List>());

      // Test ApiClient Phase 11 updater methods
      final updateCheck = await client.checkForUpdates(currentVersion: '0.1.0', forcedPlatform: 'linux');
      expect(updateCheck.containsKey('status'), isTrue);
      expect(updateCheck['has_update'], isTrue);
      expect(updateCheck['latest_version'], equals('0.1.1'));

      final updateStage = await client.stageUpdateArtifact(
        stagingDir: '/tmp/test_client_stage',
        fileName: 'libcodelite.so',
        content: 'CodeLiteX mock update payload',
        expectedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(updateStage.containsKey('status'), isTrue);

      final updateApply = await client.applyUpdate(
        stagingDir: '/tmp/test_client_stage',
        targetDir: '/tmp/test_client_target',
        files: ['libcodelite.so'],
        platform: 'linux',
      );
      expect(updateApply.containsKey('status'), isTrue);
      expect(updateApply['status'], equals('ok'));
    });
  });
}

