import 'dart:io';

import 'package:code_lite_ui/core/fs/workspace_fs_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  void write(String rel, String content) {
    final f = File('${root.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  String read(String rel) => File('${root.path}/$rel').readAsStringSync();

  setUp(() => root = Directory.systemTemp.createTempSync('clx_fs_'));
  tearDown(() => root.deleteSync(recursive: true));

  group('scanTree', () {
    test('dirs first, sorted, ignored entries skipped, depth limited', () async {
      write('src/deep/inner/x.rs', 'x');
      write('src/lib.rs', 'lib');
      write('b.txt', 'bb');
      write('a.txt', 'a');
      write('.git/HEAD', 'ref');
      write('target/debug/out', 'o');
      write('node_modules/m/index.js', 'm');

      final tree = await scanTree(root.path, maxDepth: 2);
      expect(tree['is_dir'], isTrue);
      expect(tree['path'], root.path);

      final names = [for (final c in tree['children'] as List) c['name']];
      expect(names, ['src', 'a.txt', 'b.txt']); // 目录在前,忽略 .git / target / node_modules

      final a = (tree['children'] as List).firstWhere((c) => c['name'] == 'a.txt');
      expect(a['is_dir'], isFalse);
      expect(a['size_bytes'], 1);
      expect(a['modified_ms'], greaterThan(0));
      expect(a['children'], isNull);
      expect(a['path'], '${root.path}/a.txt');

      // maxDepth=2:root(0) → src(1) → deep(2) 已到深度上限,不再展开:标成未加载,文件树展开时再读。
      final src = (tree['children'] as List).first as Map;
      final deep = (src['children'] as List).firstWhere((c) => c['name'] == 'deep') as Map;
      expect(deep['children'], isNull);
      expect(deep['loaded'], isFalse);
      expect(src['loaded'], isTrue);
    });

    test('a missing root yields an empty directory node instead of throwing', () async {
      final tree = await scanTree('${root.path}/nope');
      expect(tree['is_dir'], isTrue);
      expect(tree['children'], isEmpty);
    });
  });

  group('searchWorkspace / replaceWorkspace', () {
    // 与原 Rust test_workspace_search_and_replace 相同的场景。
    test('whole word vs partial search, then replace', () async {
      write('src/lib.rs', 'pub fn calculate_price(qty: i32) -> i32 { qty * 10 }\n');
      write('README.md', '# Price Service\nCalculate price accurately.\n');

      final whole = await searchWorkspace(root.path, 'calculate', {'whole_word': true, 'max_results': 50});
      expect(whole['status'], 'ok');
      expect(whole['total'], 1); // 只有 README 的 "Calculate" 是整词

      final partial = await searchWorkspace(root.path, 'price', {'max_results': 50});
      expect(partial['total'], 3); // lib.rs 1 处,README 2 处
      final first = (partial['matches'] as List).firstWhere((m) => m['file_path'] == 'src/lib.rs') as Map;
      expect(first['line_number'], 1);
      expect(first['line_snippet'], 'pub fn calculate_price(qty: i32) -> i32 { qty * 10 }');
      expect(
        (first['line_snippet'] as String).substring(first['col_start'] as int, first['col_end'] as int),
        'price',
      );

      final replaced = await replaceWorkspace(root.path, 'price', 'amount', {'max_results': 50});
      expect(replaced, {'status': 'ok', 'replaced_count': 3});
      expect(read('src/lib.rs'), contains('calculate_amount'));
      expect(read('README.md'), contains('# amount Service'));
    });

    test('case sensitivity, regex, extension filter and max_results', () async {
      write('a.dart', 'Foo foo FOO\n');
      write('b.rs', 'foo42 foo7\n');

      expect((await searchWorkspace(root.path, 'foo', {'case_sensitive': true}))['total'], 3); // foo(a) + foo42 + foo7
      expect((await searchWorkspace(root.path, 'foo'))['total'], 5);
      expect((await searchWorkspace(root.path, r'foo\d+', {'is_regex': true}))['total'], 2);
      expect((await searchWorkspace(root.path, 'foo', {'file_extension': 'dart'}))['total'], 3);
      expect((await searchWorkspace(root.path, 'foo', {'max_results': 2}))['total'], 2);
      expect((await searchWorkspace(root.path, ''))['total'], 0);
    });

    test('skips hidden / build dirs and binary files', () async {
      write('src/main.rs', 'needle\n');
      write('.hidden/x.rs', 'needle\n');
      write('build/out.txt', 'needle\n');
      write('.dart_tool/cache', 'needle\n');
      File('${root.path}/blob.bin').writeAsBytesSync([110, 101, 101, 100, 108, 101, 0, 1, 2]); // "needle\0.."

      final res = await searchWorkspace(root.path, 'needle');
      expect([for (final m in res['matches'] as List) m['file_path']], ['src/main.rs']);
    });

    test('invalid regex is reported as an error, not thrown', () async {
      write('a.txt', 'x');
      final res = await searchWorkspace(root.path, '(unclosed', {'is_regex': true});
      expect(res['status'], 'error');
      expect(res['error'], startsWith('Search failed:'));
    });

    test('replacement expands capture groups like Rust regex', () async {
      write('a.txt', 'name=alice name=bob\n');
      final res = await replaceWorkspace(
        root.path,
        r'name=(?<who>\w+)',
        r'${who}:$1 $$',
        {'is_regex': true},
      );
      expect(res['replaced_count'], 2);
      expect(read('a.txt'), r'alice:alice $ bob:bob $' '\n');
    });

    test('no matches leaves files untouched', () async {
      write('a.txt', 'keep me\n');
      final res = await replaceWorkspace(root.path, 'absent', 'x');
      expect(res['replaced_count'], 0);
      expect(read('a.txt'), 'keep me\n');
    });
  });
}
