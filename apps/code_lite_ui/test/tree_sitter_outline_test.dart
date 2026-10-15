import 'package:code_lite_ui/core/ffi/rust_syntax.dart';
import 'package:flutter_test/flutter_test.dart';

/// 大纲压成 `kind name@line` 的缩进文本。
List<String> flat(List<Map<String, dynamic>> nodes, [int depth = 0]) => [
      for (final n in nodes) ...[
        '${'  ' * depth}${n['kind']} ${n['name']}@${n['line_start']}',
        ...flat((n['children'] as List).cast<Map<String, dynamic>>(), depth + 1),
      ],
    ];

void main() {
  test('grammar by extension', () {
    expect(syntaxGrammarForPath('a/B.java'), 'java');
    expect(syntaxGrammarForPath('x.TSX'), 'tsx');
    expect(syntaxGrammarForPath('m.mjs'), 'javascript');
    expect(syntaxGrammarForPath('Cargo.toml'), isNull);
  });

  test('Java outline from the syntax tree: members nested, method bodies skipped, name positions', () async {
    const src = '''
package p;

/** Doc. */
@Service
public class OrderService {
    private final Repo repo;
    public OrderService(Repo repo) { this.repo = repo; }
    public void place(Order o) {
        Runnable r = new Runnable() { public void run() {} };
        int local = 1;
    }
    enum State { NEW, PAID }
}
''';
    final outline = await rustOutline('src/OrderService.java', src);
    expect(outline, isNotNull);
    expect(flat(outline!), [
      'class OrderService@4',
      '  field repo@5',
      '  constructor OrderService@6',
      '  method place@7',
      '  enum State@11',
      '    variant NEW@11',
      '    variant PAID@11',
    ]);
    // 跳转落在名字上,不在注解 / 文档注释上
    expect(outline.first['col_start'], 'public class '.length);
    expect(outline.first['line_end'], 12);
  });

  test('Dart outline: named constructors, getters, top-level functions', () async {
    const src = 'class A {\n  final int n;\n  A(this.n);\n  A.zero() : n = 0;\n  int get twice => n * 2;\n}\nvoid main() {}\n';
    expect(flat((await rustOutline('lib/a.dart', src))!), [
      'class A@0',
      '  field n@1',
      '  constructor A@2',
      '  constructor A.zero@3',
      '  method twice@4',
      'function main@6',
    ]);
  });

  test('files without a grammar fall back (null)', () async {
    expect(await rustOutline('a.kt', 'class A'), isNull);
  });
}
