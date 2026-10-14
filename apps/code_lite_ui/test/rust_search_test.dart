import 'dart:io';

import 'package:code_lite_ui/core/fs/rust_search.dart';
import 'package:code_lite_ui/core/fs/workspace_fs.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全局搜索 / 替换交给 Rust(并行):结果要和原来 Dart 那份一模一样;Rust 不支持的正则回到 Dart。
void main() {
  late Directory root;

  void write(String rel, String text) {
    final f = File('${root.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('clx_rust_search_');
    write('src/Main.java', '  // 找不到符号 DataSource\r\nclass DataSource {}\r\n\tString dataSource = "x";\n');
    write('src/sub/a.kt', 'val dataSource = DataSourceFactory()\rlast DataSource');
    write('README.md', '# DataSource\nUse `dataSource` here. data-source too.\n');
    write('build/gen.java', 'DataSource\n');
    write('.idea/x.xml', 'DataSource\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('the Rust library is used here (not silently falling back)', () async {
    final r = await rustSearch({'op': 'search', 'root': root.path, 'query': 'DataSource', 'options': <String, dynamic>{}});
    expect(r, isNotNull, reason: '测试环境有 Rust 库(target/debug)');
    expect(r!['status'], 'ok');
  });

  test('Rust and Dart give identical results (order aside): CJK, CRLF / CR lines, indentation, regex, whole word, case', () async {
    List<String> norm(Map<String, dynamic> r) => [
          for (final m in r['matches'] as List)
            '${m['file_path']}:${m['line_number']}:${m['col_start']}-${m['col_end']}:${m['line_snippet']}',
        ]..sort();
    for (final (q, o) in <(String, Map<String, dynamic>)>[
      ('DataSource', {}),
      ('datasource', {'case_sensitive': true}),
      ('DataSource', {'whole_word': true}),
      (r'data\w*', {'is_regex': true}),
      (r'^\s*class', {'is_regex': true}),
      (r'Source$', {'is_regex': true}),
      ('DataSource', {'file_extension': 'kt'}),
      ('符号', {}),
    ]) {
      final rust = await searchWorkspace(root.path, q, o);
      final dart = await searchWorkspaceInDart(root.path, q, o);
      expect(rust['status'], 'ok', reason: q);
      expect(norm(rust), norm(dart), reason: '$q $o');
      expect(rust['total'], dart['total'], reason: '$q $o');
    }
  });

  test('regex features Rust lacks (lookaround, backreferences) fall back to Dart and still work', () async {
    final look = await searchWorkspace(root.path, r'(?<=val )dataSource', {'is_regex': true});
    expect(look['status'], 'ok');
    expect(look['total'], 1);
    final back = await searchWorkspace(root.path, r'(a)\1', {'is_regex': true});
    expect(back['status'], 'ok');
    final bad = await searchWorkspace(root.path, '(unclosed', {'is_regex': true});
    expect(bad['status'], 'error', reason: '真写错的正则:Dart 那份报错');
  });

  test('replace in Rust: every match in every file, capture groups, nothing outside the project scope', () async {
    final r = await replaceWorkspace(root.path, r'Data(Source)', r'Db$1', {'is_regex': true, 'case_sensitive': true});
    expect(r, {'status': 'ok', 'replaced_count': 5}); // Main.java 2 + a.kt 2 + README 1
    expect(File('${root.path}/src/Main.java').readAsStringSync(), '  // 找不到符号 DbSource\r\nclass DbSource {}\r\n\tString dataSource = "x";\n');
    expect(File('${root.path}/build/gen.java').readAsStringSync(), 'DataSource\n', reason: 'build/ 不在搜索范围');
  });
}
