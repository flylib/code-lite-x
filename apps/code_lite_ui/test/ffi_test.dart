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

        final termRes = ffi.terminalExec('echo', ['hello_from_dart_ffi']);
        expect(termRes['status'], equals('ok'));
        expect((termRes['stdout'] as String).contains('hello_from_dart_ffi'), isTrue);

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

      }
    });

    test('ApiClient connects seamlessly via FFI or fallback', () async {
      final client = ApiClient();
      final tree = await client.fetchWorkspaceTree();
      expect(tree.containsKey('name'), isTrue);

      final file = await client.fetchFile('pubspec.yaml');
      expect(file['status'], 'ok');
      expect(file['content'] as String, contains('code_lite_ui'));

      final search = await client.searchWorkspace('flutter');
      expect(search.containsKey('status'), isTrue);

      final term = await client.terminalExec('echo', ['hello_apiclient']);
      expect(term.containsKey('status'), isTrue);

      final gitInfo = await client.getGitStatus();
      expect(gitInfo.containsKey('branch'), isTrue);

      final gitDiffText = await client.getGitDiff();
      expect(gitDiffText.containsKey('diff'), isTrue);

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

    // File → Open 会多次切换工作区根。曾经二次 initialize 给 late final 函数指针
    // 重复赋值,抛 LateInitializationError 后 FFI 整体掉线,第二个项目永远打不开。
    test('reinitialize switches workspace root repeatedly without dropping FFI', () {
      final ffi = CodeLiteBindings.instance;
      if (!ffi.initialize('.')) return; // 没编出 dylib 时跳过

      final a = Directory.systemTemp.createTempSync('clx_ws_a_');
      final b = Directory.systemTemp.createTempSync('clx_ws_b_');
      addTearDown(() {
        ffi.reinitialize('.');
        a.deleteSync(recursive: true);
        b.deleteSync(recursive: true);
      });
      File('${a.path}/only_in_a.txt').writeAsStringSync('a');
      File('${b.path}/only_in_b.txt').writeAsStringSync('b');

      for (final dir in [a, b, a]) {
        expect(ffi.reinitialize(dir.path), isTrue, reason: 'reinitialize(${dir.path})');
        expect(ffi.isAvailable, isTrue);
        // Rust 上下文确实换了根:终端命令在新根目录下执行。
        final here = dir == a ? 'only_in_a.txt' : 'only_in_b.txt';
        final ls = ffi.terminalExec('ls', const []);
        expect(ls['status'], 'ok');
        expect(ls['stdout'] as String, contains(here));
      }
    });
  });
}

