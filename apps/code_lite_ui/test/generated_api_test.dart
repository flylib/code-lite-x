import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_lite_ui/core/api/generated/core_api_client.dart';
import 'package:code_lite_ui/core/ffi/codelite_bindings.dart';

class MockJsonRpcTransport implements JsonRpcTransport {
  final Map<String, dynamic> responses;
  final List<String> recordedCalls = [];

  MockJsonRpcTransport(this.responses);

  @override
  Future<dynamic> sendRequest(String method, Map<String, dynamic> params) async {
    recordedCalls.add('$method:${params.keys.join(',')}');
    if (responses.containsKey(method)) {
      final resp = responses[method];
      if (resp is Exception) {
        throw resp;
      }
      return resp;
    }
    throw JsonRpcException(-32601, 'Method not found: $method');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Generated CoreApiClient & JsonRpcTransport Tests', () {
    test('CoreApiClient maps typed requests and responses via MockTransport', () async {
      final mock = MockJsonRpcTransport({
        'file.open': {
          'path': 'src/main.rs',
          'content': 'fn main() {}',
          'line_count': 1,
          'version': 1,
        },
        'file.edit': {
          'success': true,
          'version': 2,
          'diagnostics_count': 0,
        },
        'file.undo': {
          'success': true,
          'version': 1,
          'content': 'fn main() {}',
        },
        'file.redo': {
          'success': true,
          'version': 2,
          'content': 'fn main() { println!(); }',
        },
        'lsp.completion': {
          'items': [
            {
              'label': 'println!',
              'kind': 'Function',
              'detail': 'macro',
              'insert_text': 'println!("{}")',
            }
          ],
        },
        'lsp.diagnostics': {
          'diagnostics': [
            {
              'line': 1,
              'start_col': 0,
              'end_col': 10,
              'severity': 'Warning',
              'message': 'unused variable',
            }
          ],
        },
        'agent.send_prompt': {
          'event_type': 'done',
          'payload': 'Task completed',
          'is_done': true,
        },
        'git.status': {
          'branch': 'main',
          'is_clean': true,
          'changes': [],
        },
      });

      final client = CoreApiClient(transport: mock);

      // 1. fileOpen
      final file = await client.fileOpen(path: 'src/main.rs');
      expect(file.path, 'src/main.rs');
      expect(file.content, 'fn main() {}');
      expect(file.lineCount, 1);
      expect(file.version, 1);

      // 2. fileEdit
      final edit = await client.fileEdit(
        path: 'src/main.rs',
        range: const Range(startLine: 1, startCol: 0, endLine: 1, endCol: 0),
        newText: ' println!();',
      );
      expect(edit.success, isTrue);
      expect(edit.version, 2);
      expect(edit.diagnosticsCount, 0);

      // 3. fileUndo
      final undo = await client.fileUndo(path: 'src/main.rs');
      expect(undo.success, isTrue);
      expect(undo.version, 1);
      expect(undo.content, 'fn main() {}');

      // 4. fileRedo
      final redo = await client.fileRedo(path: 'src/main.rs');
      expect(redo.success, isTrue);
      expect(redo.version, 2);

      // 5. lspCompletion
      final completions = await client.lspCompletion(
        path: 'src/main.rs',
        line: 1,
        character: 5,
      );
      expect(completions.items.length, 1);
      expect(completions.items.first.label, 'println!');
      expect(completions.items.first.kind, 'Function');

      // 6. lspDiagnostics
      final diags = await client.lspDiagnostics(path: 'src/main.rs');
      expect(diags.diagnostics.length, 1);
      expect(diags.diagnostics.first.severity, 'Warning');
      expect(diags.diagnostics.first.message, 'unused variable');

      // 7. agentSendPrompt (streaming)
      final events = await client.agentSendPrompt(prompt: 'Plan task').toList();
      expect(events.length, 1);
      expect(events.first.eventType, 'done');
      expect(events.first.payload, 'Task completed');
      expect(events.first.isDone, isTrue);

      // 8. gitStatus
      final git = await client.gitStatus(workspacePath: '/tmp/repo');
      expect(git.branch, 'main');
      expect(git.isClean, isTrue);
      expect(git.changes, isEmpty);

      // Verify all 8 methods were recorded
      expect(mock.recordedCalls.length, 8);
    });

    test('JsonRpcException handles error payloads properly', () async {
      final mock = MockJsonRpcTransport({
        'file.open': const JsonRpcException(-32602, 'Invalid params: missing path'),
      });
      final client = CoreApiClient(transport: mock);

      expect(
        () => client.fileOpen(path: ''),
        throwsA(isA<JsonRpcException>().having((e) => e.code, 'code', -32602)),
      );
    });

    test('Native FfiJsonRpcTransport integration with real libcodelite dylib', () async {
      final bindings = CodeLiteBindings.instance;
      final tempDir = Directory.systemTemp.createTempSync('codelite_dart_rpc_test');

      try {
        final initialized = bindings.initialize(tempDir.path);
        if (!initialized) {
          // Dynamic library not present in test runtime environment; skip native test gracefully
          return;
        }

        final ctxPtr = bindings.contextPointer;
        expect(ctxPtr, isNotNull);

        final client = CoreApiClient.fromBindings(bindings: bindings, ctxPtr: ctxPtr!);

        // Create a test file
        final testFile = File('${tempDir.path}/hello.txt');
        testFile.writeAsStringSync('Hello, CodeLiteX!');

        // 1. fileOpen
        final content = await client.fileOpen(path: 'hello.txt');
        expect(content.path, 'hello.txt');
        expect(content.content, 'Hello, CodeLiteX!');

        // 2. fileEdit
        final edit = await client.fileEdit(
          path: 'hello.txt',
          range: const Range(startLine: 0, startCol: 0, endLine: 0, endCol: 0),
          newText: ' Appended',
        );
        expect(edit.success, isTrue);

        // 3. fileUndo & redo
        final undo = await client.fileUndo(path: 'hello.txt');
        expect(undo.success, isTrue);

        final redo = await client.fileRedo(path: 'hello.txt');
        expect(redo.success, isTrue);

        // 4. agentSendPrompt
        final stream = await client.agentSendPrompt(prompt: 'Status check', stream: false).toList();
        expect(stream.isNotEmpty, isTrue);
        expect(stream.first.isDone, isTrue);

        // 5. gitStatus
        Process.runSync('git', ['-C', tempDir.path, 'init']);
        final git = await client.gitStatus(workspacePath: tempDir.path);
        expect(git.branch, isNotNull);

        bindings.dispose();
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
