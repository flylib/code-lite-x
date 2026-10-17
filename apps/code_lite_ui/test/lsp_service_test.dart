import 'dart:convert';
import 'dart:io';

import 'package:code_lite_ui/core/lsp/lsp_common.dart';
import 'package:code_lite_ui/core/lsp/lsp_service.dart';
import 'package:flutter_test/flutter_test.dart';

// 假语言服务端:真实的 Content-Length JSON-RPC。
//   - initialize 应答;initialized 后反向发 workspace/configuration、workDoneProgress/create 与一个未知请求,
//     三者都被正确应答后,documentSymbol 结果里会多出 `handshake_ok`;
//   - didOpen/didChange 发布诊断,消息回显正文首行(证明 didChange 的全文真的到了);
//     didOpen 时额外为「带空格+非 ASCII 的文件」和「resolve 过的根下文件」发布诊断,验证 URI → 相对路径;
//   - --crash-on-open:收到 didOpen 立即退出;--ignore-exit:不理 shutdown/exit,逼客户端强杀。
const _fakeServer = r'''
import 'dart:convert';
import 'dart:io';

final List<int> buf = [];
int? expected;
bool cfgOk = false, progressOk = false, unknownOk = false;
String rootPath = '';
late List<String> args;

/// 工作区目录数(initialize 的 workspaceFolders,随 didChangeWorkspaceFolders 增减):验证项目组共用。
int folders = 0;

/// --incremental 模式下服务端自己保存的文档内容(按收到的范围逐项应用)。
final Map<String, List<String>> docs = {};

void applyChange(String uri, Map change) {
  final range = change['range'] as Map?;
  final text = change['text'] as String;
  if (range == null) {
    docs[uri] = text.split('\n');
    return;
  }
  final lines = docs[uri]!;
  final s = range['start'] as Map, e = range['end'] as Map;
  final sl = s['line'] as int, el = e['line'] as int;
  final prefix = lines[sl].substring(0, s['character'] as int);
  final suffix = lines[el].substring(e['character'] as int);
  final pieces = text.split('\n');
  pieces[0] = '$prefix${pieces[0]}';
  pieces[pieces.length - 1] = '${pieces.last}$suffix';
  lines.replaceRange(sl, el + 1, pieces);
}

void send(Map<String, Object?> m) {
  final body = utf8.encode(jsonEncode({'jsonrpc': '2.0', ...m}));
  // 头与体分两次写,制造跨 chunk 的帧。
  stdout.add(ascii.encode('Content-Length: ${body.length}\r\n\r\n'));
  stdout.add(body);
}

Map<String, Object?> rng(int l1, int c1, int l2, int c2) => {
      'start': {'line': l1, 'character': c1},
      'end': {'line': l2, 'character': c2},
    };

void publish(String uri, String message) {
  send({
    'method': 'textDocument/publishDiagnostics',
    'params': {
      'uri': uri,
      'diagnostics': [
        {'range': rng(0, 0, 0, 3), 'severity': 2, 'source': 'fake', 'code': 'E1', 'message': message},
      ],
    },
  });
}

void handle(Map msg) {
  final method = msg['method'];
  final id = msg['id'];
  if (method == null) {
    if (id == 'cfg-1') {
      final r = msg['result'];
      cfgOk = r is List && r.length == 2 && r.every((e) => e == null);
    } else if (id == 'prog-1') {
      progressOk = msg.containsKey('result') && msg['result'] == null;
    } else if (id == 'unk-1') {
      unknownOk = (msg['error'] as Map?)?['code'] == -32601;
    }
    return;
  }
  final params = (msg['params'] as Map?) ?? const {};
  switch (method) {
    case 'initialize':
      rootPath = Uri.parse(params['rootUri'] as String).toFilePath();
      folders = (params['workspaceFolders'] as List?)?.length ?? 0;
      send({
        'id': id,
        'result': {
          'capabilities': {
            'textDocumentSync': args.contains('--incremental') ? {'openClose': true, 'change': 2} : 1,
            'documentSymbolProvider': true,
          },
          'serverInfo': {'name': 'fake'},
        },
      });
    case 'initialized':
      send({'method': 'window/logMessage', 'params': {'type': 3, 'message': 'hello'}});
      send({'id': 'cfg-1', 'method': 'workspace/configuration', 'params': {'items': [{'section': 'a'}, {'section': 'b'}]}});
      send({'id': 'prog-1', 'method': 'window/workDoneProgress/create', 'params': {'token': 't'}});
      send({'id': 'unk-1', 'method': 'custom/unknown', 'params': {}});
    case 'textDocument/didOpen':
      if (args.contains('--crash-on-open')) exit(3);
      final doc = params['textDocument'] as Map;
      docs[doc['uri'] as String] = (doc['text'] as String).split('\n');
      if (args.contains('-data')) {
        // 以 jdtls 方式启动:回报收到的 -data 目录与 JAVA_HOME
        publish(doc['uri'] as String, 'data=${args[args.indexOf('-data') + 1]} folders=$folders java=${Platform.environment['JAVA_HOME'] ?? ''}');
        return;
      }
      publish(doc['uri'] as String, 'echo: ${(doc['text'] as String).split('\n').first}');
      publish(Uri.file('$rootPath/other dir/ü.rs').toString(), 'decoded');
      final resolved = Directory(rootPath).resolveSymbolicLinksSync();
      publish(Uri.file('$resolved/resolved.rs').toString(), 'resolved');
    case 'textDocument/didChange':
      final doc = params['textDocument'] as Map;
      final changes = (params['contentChanges'] as List).cast<Map>();
      if (args.contains('--incremental')) {
        final uri = doc['uri'] as String;
        for (final c in changes) {
          applyChange(uri, c);
        }
        final kind = changes.every((c) => c.containsKey('range')) ? 'ranges' : 'full';
        publish(uri, 'doc v${doc['version']} $kind: ${docs[uri]!.join('\\n')}');
      } else {
        final text = changes.last['text'] as String;
        publish(doc['uri'] as String, 'echo: ${text.split('\n').first} v${doc['version']}');
      }
    case 'textDocument/documentSymbol':
      send({
        'id': id,
        'result': [
          {
            'name': 'Widget',
            'kind': 23,
            'detail': 'struct Widget',
            'range': rng(0, 0, 5, 1),
            'selectionRange': rng(1, 7, 1, 13),
            'children': [
              {'name': 'build', 'kind': 6, 'range': rng(2, 2, 4, 3), 'selectionRange': rng(2, 9, 2, 14)},
            ],
          },
          {
            'name': cfgOk && progressOk && unknownOk ? 'handshake_ok' : 'handshake_pending',
            'kind': 12,
            'range': rng(7, 0, 7, 10),
            'selectionRange': rng(7, 3, 7, 8),
          },
        ],
      });
    case 'workspace/didChangeWorkspaceFolders':
      final event = params['event'] as Map;
      folders += (event['added'] as List).length - (event['removed'] as List).length;
    case 'shutdown':
      if (!args.contains('--ignore-exit')) send({'id': id, 'result': null});
    case 'exit':
      if (!args.contains('--ignore-exit')) exit(0);
    default:
      if (id != null) send({'id': id, 'result': null});
  }
}

void main(List<String> a) {
  args = a;
  stdin.listen((chunk) {
    buf.addAll(chunk);
    while (true) {
      if (expected == null) {
        var sep = -1;
        for (var i = 0; i + 3 < buf.length; i++) {
          if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) {
            sep = i;
            break;
          }
        }
        if (sep < 0) return;
        final header = ascii.decode(buf.sublist(0, sep));
        buf.removeRange(0, sep + 4);
        expected = int.parse(RegExp(r'Content-Length:\s*(\d+)').firstMatch(header)!.group(1)!);
      }
      if (buf.length < expected!) return;
      final body = utf8.decode(buf.sublist(0, expected!));
      buf.removeRange(0, expected!);
      expected = null;
      handle(jsonDecode(body) as Map);
    }
  });
}
''';

/// 找一个能跑脚本的 dart:FLUTTER_ROOT → 本机 Flutter SDK → flutter_tester 所在 SDK 的 cache。
String? _findDart() {
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] != null)
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart',
    '/Users/dev/development/flutter/bin/cache/dart-sdk/bin/dart',
  ];
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    candidates.add('${dir.path}/dart-sdk/bin/dart');
    candidates.add('${dir.path}/cache/dart-sdk/bin/dart');
    dir = dir.parent;
  }
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

Future<bool> _pidAlive(int pid) async {
  final r = await Process.run('ps', ['-p', '$pid']);
  return r.exitCode == 0;
}

Future<T> _waitFor<T>(Future<T> Function() probe, bool Function(T) ok, {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final v = await probe();
    if (ok(v) || DateTime.now().isAfter(deadline)) return v;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<Map<String, dynamic>> _serverStatus(LspService lsp) async {
  final servers = (await lsp.status())['servers'] as List;
  return servers.isEmpty ? <String, dynamic>{} : servers.first as Map<String, dynamic>;
}

List<String> _names(List<Map<String, dynamic>> nodes) => nodes.map((n) => n['name'] as String).toList();

Map<String, dynamic> _find(List<Map<String, dynamic>> nodes, String name) =>
    nodes.firstWhere((n) => n['name'] == name, orElse: () => throw StateError('no symbol $name in ${_names(nodes)}'));

List<Map<String, dynamic>> _children(Map<String, dynamic> node) => (node['children'] as List).cast<Map<String, dynamic>>();

void main() {
  // =========================================================================
  // 纯逻辑
  // =========================================================================

  group('LspFrameParser', () {
    test('roundtrip, byte-by-byte split and merged chunks', () {
      final a = LspFrameParser.encode({'id': 1, 'result': 'a'});
      final b = LspFrameParser.encode({'method': 'x', 'params': [1, 2]});
      final p = LspFrameParser();
      final out = <String>[];
      for (final byte in [...a, ...b]) {
        out.addAll(p.add([byte]));
      }
      expect(out.map(jsonDecode).toList(), [
        {'id': 1, 'result': 'a'},
        {'method': 'x', 'params': [1, 2]},
      ]);

      final merged = LspFrameParser().add([...a, ...b, ...a]);
      expect(merged, hasLength(3));
    });

    test('Content-Length counts UTF-8 bytes; split inside a multibyte char', () {
      final frame = LspFrameParser.encode({'m': '中文😀'});
      final header = ascii.decode(frame.sublist(0, frame.indexOf(13)));
      final body = utf8.encode(jsonEncode({'m': '中文😀'}));
      expect(header, 'Content-Length: ${body.length}');
      expect(body.length, greaterThan(jsonEncode({'m': '中文😀'}).length));

      final p = LspFrameParser();
      final cut = frame.length - 4; // 切在 😀 的 4 字节中间
      expect(p.add(frame.sublist(0, cut)), isEmpty);
      final out = p.add(frame.sublist(cut));
      expect(jsonDecode(out.single), {'m': '中文😀'});
    });

    test('extra headers, case-insensitive name, header without length is skipped', () {
      final body = utf8.encode('{"ok":true}');
      final p = LspFrameParser();
      final out = p.add([
        ...ascii.encode('X-Junk: 1\r\n\r\n'),
        ...ascii.encode('content-length: ${body.length}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n'),
        ...body,
      ]);
      expect(out, ['{"ok":true}']);
    });
  });

  group('bracket diagnostics', () {
    test('balanced code has no diagnostics', () {
      expect(lspBracketDiagnostics('fn main() { let v = [1, (2)]; }', 'rust'), isEmpty);
    });

    test('unclosed bracket reported at the opener', () {
      final d = lspBracketDiagnostics('fn main() {\n  let x = 1;\n', 'rust');
      expect(d, hasLength(1));
      expect(d.single['code'], 'unclosed_bracket');
      expect(d.single['severity'], 1);
      expect(d.single['range'], {
        'start': {'line': 0, 'character': 10},
        'end': {'line': 0, 'character': 11},
      });
    });

    test('unmatched closing bracket', () {
      final d = lspBracketDiagnostics('let a = 1;\nfoo());', 'typescript');
      expect(d.single['code'], 'unmatched_bracket');
      expect((d.single['range'] as Map)['start'], {'line': 1, 'character': 5});
    });

    test('mismatched bracket recovers without cascading', () {
      final d = lspBracketDiagnostics('fn x() {\n  foo(a, {b);\n}\n', 'rust');
      expect(d, hasLength(1));
      expect(d.single['code'], 'mismatched_bracket');
      expect((d.single['range'] as Map)['start'], {'line': 1, 'character': 11});
      expect(d.single['message'], contains("expected '}'"));
    });

    test('brackets inside strings, chars and comments are ignored', () {
      const rust = 'fn f<\'a>(s: &\'a str) -> char {\n'
          '  let s = "{(["; // ) ] }\n'
          '  /* { /* nested ( */ ] */\n'
          '  let r = r#"}"#;\n'
          "  let c = '{';\n"
          "  let e = '\\'';\n"
          '  c\n'
          '}\n';
      expect(lspBracketDiagnostics(rust, 'rust'), isEmpty);

      const dart = "var a = '\${m['k']}';\n"
          'var b = "\${f(")")}";\n'
          "var c = r'(\\';\n"
          "var d = '''\n(\n''';\n";
      expect(lspBracketDiagnostics(dart, 'dart'), isEmpty);

      const ts = r"const t = `(${ {a: 1}.a }[`;" '\n' r"const s = '{'; // (" '\n';
      expect(lspBracketDiagnostics(ts, 'typescript'), isEmpty);

      // 正则字面量(含 `//`、`[`、`(`)与 JSX 的 `</tag>` / `/>`;除号不是正则。
      const js = r"if (/^https?:\/\//.test(u)) { const m = s.match(/(.+)\[([^\]]+)\]/); }" '\n'
          r'const el = <A x={{ a: 1 }} />; const t = <b>{n / 2}</b>;' '\n';
      expect(lspBracketDiagnostics(js, 'javascriptreact'), isEmpty);

      const go = 'var s = `{\n(`\nvar r = \'(\'\n';
      expect(lspBracketDiagnostics(go, 'go'), isEmpty);

      const py = "x = '(' # )\ny = '''\n[\n'''\nz = r'\\'\n";
      expect(lspBracketDiagnostics(py, 'python'), isEmpty);

      const c = "char c = '{'; const char *s = \"(\\\"\"; /* [ */\n";
      expect(lspBracketDiagnostics(c, 'c'), isEmpty);
    });

    test('an unterminated single-line string does not swallow the file', () {
      final d = lspBracketDiagnostics('let s = "oops;\nfn f() {\n', 'typescript');
      expect(d.single['code'], 'unclosed_bracket');
      expect((d.single['range'] as Map)['start'], {'line': 1, 'character': 7});
    });
  });

  group('regex outline', () {
    test('rust', () {
      const src = '''
use std::fmt;

/// docs mentioning fn fake()
pub struct EditorService {
    pub root_dir: String,
    count: HashMap<String, u32>,
}

pub enum Mode {
    Insert,
    Normal(u8),
    Visual { start: usize },
}

pub trait Render {
    fn render(&self) -> String;
}

impl<T: Into<String>> fmt::Display for Wrapper<T> where T: Clone {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let inner = || { 1 };
        Ok(())
    }
}

pub(crate) async fn main_init() {
    fn nested() {}
}

const MAX: usize = 10;
mod tests {
    fn helper() {}
}
''';
      final o = lspRegexOutline(src, 'rust');
      expect(_names(o), ['EditorService', 'Mode', 'Render', 'impl fmt::Display for Wrapper<T>', 'main_init', 'MAX', 'tests']);
      final svc = _find(o, 'EditorService');
      expect(svc['kind'], 'struct');
      expect(svc['line_start'], 3);
      expect(svc['col_start'], 11);
      expect(svc['line_end'], 6);
      expect(_names(_children(svc)), ['root_dir', 'count']);
      expect(_children(svc).first['kind'], 'field');
      expect(_names(_children(_find(o, 'Mode'))), ['Insert', 'Normal', 'Visual']);
      expect(_children(_find(o, 'Mode')).first['kind'], 'variant');
      expect(_find(o, 'Render')['kind'], 'trait');
      expect(_children(_find(o, 'Render')).single['kind'], 'method');
      final impl = _find(o, 'impl fmt::Display for Wrapper<T>');
      expect(impl['kind'], 'impl');
      expect(_names(_children(impl)), ['fmt']);
      expect(_children(impl).single['kind'], 'method');
      expect(_find(o, 'main_init')['kind'], 'function');
      expect(_children(_find(o, 'main_init')), isEmpty); // 函数体内不进大纲
      expect(_find(o, 'MAX')['kind'], 'constant');
      expect(_names(_children(_find(o, 'tests'))), ['helper']);
    });

    test('dart', () {
      const src = '''
import 'package:flutter/widgets.dart';

const kLimit = 3;
final registry = <String, int>{};

class Counter extends StatelessWidget {
  const Counter({super.key, required this.value});
  Counter.zero() : value = 0;
  factory Counter.parse(String s) => Counter(value: int.parse(s));

  final int value;
  static const String label = 'n';

  int get doubled => value * 2;

  @override
  Widget build(BuildContext context) {
    final x = foo(1);
    return Text('\$value {');
  }

  Future<List<Map<String, dynamic>>> load<T>() async {
    return [];
  }
}

enum Color {
  red('r'),
  green('g');

  const Color(this.code);
  final String code;
}

void main() => runApp(Counter(value: 1));
''';
      final o = lspRegexOutline(src, 'dart');
      expect(_names(o), ['kLimit', 'registry', 'Counter', 'Color', 'main']);
      expect(_find(o, 'kLimit')['kind'], 'constant');
      expect(_find(o, 'registry')['kind'], 'variable');
      final counter = _find(o, 'Counter');
      expect(counter['kind'], 'class');
      final members = _children(counter);
      expect(_names(members), ['Counter', 'Counter.zero', 'Counter.parse', 'value', 'label', 'doubled', 'build', 'load']);
      expect(members.map((m) => m['kind']).toList(),
          ['constructor', 'constructor', 'constructor', 'field', 'constant', 'property', 'method', 'method']);
      expect(_find(members, 'build')['line_start'], 16);
      expect(_find(members, 'build')['line_end'], 19);
      final color = _find(o, 'Color');
      expect(_names(_children(color)), ['red', 'green', 'Color', 'code']);
      expect(_children(color).map((m) => m['kind']).toList(), ['variant', 'variant', 'constructor', 'field']);
      expect(_find(o, 'main')['kind'], 'function');
    });

    test('go', () {
      const src = '''
package main

import "fmt"

type Server struct {
	Name string `json:"name {"`
	port int
}

type Handler interface {
	Serve(req string) error
}

type ID int

const Version = "1"

func (s *Server) Start() error {
	if true {
		return nil
	}
	return nil
}

func main() {
	fmt.Println("}")
}
''';
      final o = lspRegexOutline(src, 'go');
      expect(_names(o), ['Server', 'Handler', 'ID', 'Version', 'Start', 'main']);
      expect(_find(o, 'Server')['kind'], 'struct');
      expect(_names(_children(_find(o, 'Server'))), ['Name', 'port']);
      expect(_find(o, 'Handler')['kind'], 'interface');
      expect(_children(_find(o, 'Handler')).single['name'], 'Serve');
      expect(_find(o, 'ID')['kind'], 'type');
      expect(_find(o, 'Version')['kind'], 'constant');
      expect(_find(o, 'Start')['kind'], 'method');
      expect(_find(o, 'main')['kind'], 'function');
      expect(_find(o, 'main')['line_end'], 26);
    });

    test('typescript', () {
      const src = '''
import { x } from './x';

export interface Shape {
  readonly id: string;
  area(): number;
}

export enum Kind { A, B }

export type Point = { x: number };

export class Circle implements Shape {
  private radius: number;
  static count = 0;
  constructor(radius: number) {
    this.radius = radius;
  }
  area(): number {
    const helper = () => 1;
    return Math.PI;
  }
  get size() { return 1; }
}

export function makeCircle(r: number): Circle {
  return new Circle(r);
}

export const render = async (p: Point) => {
  return p;
};

const LIMIT = 3;
''';
      final o = lspRegexOutline(src, 'typescript');
      expect(_names(o), ['Shape', 'Kind', 'Point', 'Circle', 'makeCircle', 'render', 'LIMIT']);
      expect(_find(o, 'Shape')['kind'], 'interface');
      expect(_names(_children(_find(o, 'Shape'))), ['id', 'area']);
      expect(_find(o, 'Point')['kind'], 'type');
      final circle = _find(o, 'Circle');
      expect(_names(_children(circle)), ['radius', 'count', 'constructor', 'area', 'size']);
      expect(_children(circle).map((m) => m['kind']).toList(), ['property', 'property', 'constructor', 'method', 'method']);
      expect(_find(o, 'makeCircle')['kind'], 'function');
      expect(_find(o, 'render')['kind'], 'function');
      expect(_find(o, 'LIMIT')['kind'], 'constant');
    });

    test('python and c++', () {
      const py = '''
MAX_SIZE = 10

class Repo(Base):
    """docstring with def fake():"""

    def __init__(self, path):
        def inner():
            pass
        self.path = path

    async def fetch(self,
            url):
        return url

def main():
    pass
''';
      final o = lspRegexOutline(py, 'python');
      expect(_names(o), ['MAX_SIZE', 'Repo', 'main']);
      expect(_names(_children(_find(o, 'Repo'))), ['__init__', 'fetch']);
      expect(_children(_find(o, 'Repo')).first['kind'], 'method');
      expect(_find(o, 'Repo')['line_end'], 12);

      const cpp = '''
namespace app {
class Widget : public Base {
public:
  Widget(int w);
  int width() const { return w_; }
private:
  int w_;
};

struct Fwd;

int Widget::area(int h) {
  if (h) { return 1; }
  return 0;
}
}

int main(int argc, char **argv) {
  return 0;
}
''';
      final c = lspRegexOutline(cpp, 'cpp');
      expect(_names(c), ['app', 'main']);
      final app = _find(c, 'app');
      expect(app['kind'], 'namespace');
      expect(_names(_children(app)), ['Widget', 'Widget::area']);
      final widget = _find(_children(app), 'Widget');
      expect(widget['kind'], 'class');
      expect(_names(_children(widget)), ['Widget', 'width', 'w_']);
      expect(_children(widget).map((m) => m['kind']).toList(), ['constructor', 'method', 'field']);
    });

    test('unknown languages give an empty outline', () {
      expect(lspRegexOutline('# title\n', null), isEmpty);
    });
  });

  group('symbols', () {
    test('SymbolKind mapping', () {
      expect(lspSymbolKindName(5), 'class');
      expect(lspSymbolKindName(6), 'method');
      expect(lspSymbolKindName(9), 'constructor');
      expect(lspSymbolKindName(11), 'interface');
      expect(lspSymbolKindName(11, languageId: 'rust'), 'trait');
      expect(lspSymbolKindName(12), 'function');
      expect(lspSymbolKindName(19, name: 'impl Foo'), 'impl');
      expect(lspSymbolKindName(22), 'variant');
      expect(lspSymbolKindName(23), 'struct');
      expect(lspSymbolKindName(26), 'type');
      expect(lspSymbolKindName(99), 'variable');
    });

    test('hierarchical DocumentSymbol[]', () {
      final out = lspParseDocumentSymbols([
        {
          'name': 'Foo',
          'kind': 23,
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 4, 'character': 1},
          },
          'selectionRange': {
            'start': {'line': 1, 'character': 11},
            'end': {'line': 1, 'character': 14},
          },
          'children': [
            {
              'name': 'x',
              'kind': 8,
              'range': {
                'start': {'line': 2, 'character': 4},
                'end': {'line': 2, 'character': 10},
              },
              'selectionRange': {
                'start': {'line': 2, 'character': 4},
                'end': {'line': 2, 'character': 5},
              },
            },
          ],
        },
      ]);
      expect(out.single, {
        'name': 'Foo',
        'kind': 'struct',
        'line_start': 1,
        'col_start': 11,
        'line_end': 4,
        'col_end': 1,
        'children': [
          {'name': 'x', 'kind': 'field', 'line_start': 2, 'col_start': 4, 'line_end': 2, 'col_end': 10, 'children': []},
        ],
      });
    });

    test('flat SymbolInformation[] is nested by range', () {
      Map<String, dynamic> info(String name, int kind, int l1, int l2) => {
            'name': name,
            'kind': kind,
            'location': {
              'uri': 'file:///x.ts',
              'range': {
                'start': {'line': l1, 'character': 0},
                'end': {'line': l2, 'character': 1},
              },
            },
          };
      final out = lspParseDocumentSymbols([info('bar', 6, 2, 3), info('Foo', 5, 1, 5), info('top', 12, 7, 8)]);
      expect(_names(out), ['Foo', 'top']);
      expect(_names(_children(out.first)), ['bar']);
      expect(lspParseDocumentSymbols(null), isEmpty);
      expect(lspParseDocumentSymbols(<Object>[]), isEmpty);
    });

    test('languageIdFor', () {
      expect(LspService.languageIdFor('src/main.rs'), 'rust');
      expect(LspService.languageIdFor('a/b.go'), 'go');
      expect(LspService.languageIdFor('x.c'), 'c');
      expect(LspService.languageIdFor('x.h'), 'c');
      expect(LspService.languageIdFor('x.CPP'), 'cpp');
      expect(LspService.languageIdFor('x.hpp'), 'cpp');
      expect(LspService.languageIdFor('x.ts'), 'typescript');
      expect(LspService.languageIdFor('x.tsx'), 'typescriptreact');
      expect(LspService.languageIdFor('x.mjs'), 'javascript');
      expect(LspService.languageIdFor('x.jsx'), 'javascriptreact');
      expect(LspService.languageIdFor('lib/main.dart'), 'dart');
      expect(LspService.languageIdFor('x.py'), 'python');
      expect(LspService.languageIdFor('README.md'), isNull);
      expect(LspService.languageIdFor('Makefile'), isNull);
      expect(LspService.languageIdFor('dir.rs/file'), isNull);
      expect(LspService.languageIdFor('A.java'), 'java');
      expect(lspServerGroupFor('java'), 'java');
      expect(lspServerCandidates['java']!.first.first, 'jdtls');
      expect(LspService.languageIdFor('A.kt'), isNull);
      expect(lspFallbackLanguageFor('A.kt'), 'kotlin');
      expect(lspServerGroupFor('c'), 'cpp');
      expect(lspServerGroupFor('javascriptreact'), 'typescript');
    });
  });

  // =========================================================================
  // 集成:假语言服务端
  // =========================================================================

  group('JVM memory flags', () {
    test('java gets them after the binary, the jdtls script as --jvm-arg, other commands untouched', () {
      expect(LspService.withJvmMemoryFlags(['/jdk/bin/java', '-Xmx1G', '-jar', 'x.jar']), [
        '/jdk/bin/java',
        ...LspService.jvmMemoryFlags,
        '-Xmx1G',
        '-jar',
        'x.jar',
      ]);
      expect(LspService.withJvmMemoryFlags(['/opt/homebrew/bin/jdtls']), [
        '/opt/homebrew/bin/jdtls',
        for (final f in LspService.jvmMemoryFlags) '--jvm-arg=$f',
      ]);
      expect(LspService.withJvmMemoryFlags(['dart', 'fake.dill']), ['dart', 'fake.dill']);
    });

    test('a GC or flag already given is not added twice', () {
      final argv = LspService.withJvmMemoryFlags(['java', '-XX:+UseG1GC', '-XX:GCTimeRatio=9', '-jar', 'x.jar']);
      expect(argv.where((a) => a.contains('GC') && a.startsWith('-XX:+Use')), ['-XX:+UseG1GC']);
      expect(argv.where((a) => a.startsWith('-XX:GCTimeRatio')), ['-XX:GCTimeRatio=9']);
      expect(argv, contains('-Dsun.zip.disableMemoryMapping=true'));
      final twice = LspService.withJvmMemoryFlags(LspService.withJvmMemoryFlags(['java', '-jar', 'x.jar']));
      expect(twice.length, 3 + LspService.jvmMemoryFlags.length);
    });
  });

  group('LspService with a fake server', () {
    final dart = _findDart();
    late Directory tmp;
    late Directory root;
    late List<String> serverCmd;

    setUpAll(() async {
      if (dart == null) return;
      tmp = await Directory.systemTemp.createTemp('lsp_fake_');
      root = await Directory('${tmp.path}/ws').create();
      final script = File('${tmp.path}/fake_server.dart')..writeAsStringSync(_fakeServer);
      // 预编译成 kernel,启动更快(崩溃重启用例会起多次进程)。
      final dill = '${tmp.path}/fake_server.dill';
      final r = await Process.run(dart, ['compile', 'kernel', script.path, '-o', dill]);
      serverCmd = r.exitCode == 0 ? [dart, dill] : [dart, script.path];
    });

    tearDownAll(() async {
      if (dart == null) return;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('diagnostics, didChange, documentSymbols, server requests, status, dispose', () async {
      final lsp = LspService(root.path, serverOverrides: {'rust': serverCmd});
      final events = <LspDiagnosticsEvent>[];
      final sub = lsp.diagnostics.listen(events.add);

      await lsp.didOpen('src/main.rs', 'first line\nfn main() {}\n');
      // 启动中就发起的请求会排队,初始化后照常拿到服务端结果。
      final early = await lsp.documentSymbols('src/main.rs', 'first line\nfn main() {}\n');
      expect(_names(early).first, 'Widget');

      await _waitFor(() async => events, (e) => e.any((x) => x.path == 'src/main.rs'));
      final opened = events.firstWhere((e) => e.path == 'src/main.rs');
      expect(opened.diagnostics.single['message'], 'echo: first line');
      expect(opened.diagnostics.single['source'], 'fake');
      expect(opened.diagnostics.single['severity'], 2);

      // 非 ASCII + 空格(百分号编码)与 resolve 过的根(macOS /var → /private/var)都要还原成相对路径。
      await _waitFor(() async => events, (e) => e.any((x) => x.path == 'resolved.rs'));
      expect(events.any((e) => e.path == 'other dir/ü.rs' && e.diagnostics.single['message'] == 'decoded'), isTrue);
      expect(events.any((e) => e.path == 'resolved.rs'), isTrue);

      await lsp.didChange('src/main.rs', 'changed line\n');
      await _waitFor(() async => events, (e) => e.any((x) => x.diagnostics.any((d) => d['message'] == 'echo: changed line v2')));
      expect(events.any((e) => e.path == 'src/main.rs' && e.diagnostics.single['message'] == 'echo: changed line v2'), isTrue);

      final symbols = await lsp.documentSymbols('src/main.rs', 'changed line\n');
      expect(_names(symbols), ['Widget', 'handshake_ok']);
      final widget = symbols.first;
      expect(widget['kind'], 'struct');
      expect(widget['line_start'], 1);
      expect(widget['col_start'], 7);
      expect(widget['line_end'], 5);
      expect(widget['detail'], 'struct Widget');
      expect(_children(widget).single['name'], 'build');
      expect(_children(widget).single['kind'], 'method');

      final st = await _serverStatus(lsp);
      expect(st['language'], 'rust');
      expect(st['state'], 'running');
      expect(st['initialized'], isTrue);
      expect(st['command'], contains('fake_server'));
      final pid = st['pid'] as int;
      expect(await _pidAlive(pid), isTrue);

      await lsp.didClose('src/main.rs');
      expect(events.last.path, 'src/main.rs');
      expect(events.last.diagnostics, isEmpty);

      await lsp.dispose();
      expect(await _pidAlive(pid), isFalse);
      await sub.cancel();
      // dispose 之后调用公共方法不抛异常。
      await lsp.didOpen('src/main.rs', 'x');
      expect(await lsp.documentSymbols('a.rs', 'fn a() {}'), isNotEmpty);
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));

    test('dispose kills a server that ignores shutdown/exit', () async {
      final lsp = LspService(root.path, serverOverrides: {'rust': [...serverCmd, '--ignore-exit']});
      await lsp.didOpen('a.rs', 'fn a() {}');
      final st = await _waitFor(() => _serverStatus(lsp), (s) => s['initialized'] == true);
      final pid = st['pid'] as int;
      final sw = Stopwatch()..start();
      await lsp.dispose();
      expect(sw.elapsed, lessThan(const Duration(seconds: 8)));
      expect(await _pidAlive(pid), isFalse);
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));

    test('incremental sync: ranges when the server supports it, full text otherwise', () async {
      for (final incremental in [true, false]) {
        final lsp = LspService(root.path, serverOverrides: {
          'rust': [...serverCmd, if (incremental) '--incremental'],
        });
        final events = <LspDiagnosticsEvent>[];
        final sub = lsp.diagnostics.listen(events.add);
        expect(await lsp.didChangeIncremental('src/x.rs', const [LspTextChange(0, 0, 0, 0, 'x')]), isFalse,
            reason: '没打开的文档要求调用方改发全文');
        await lsp.didOpen('src/x.rs', 'fn a() {}\nlet b = 1;\n中文 c');
        await _waitFor(() async => events, (e) => e.any((x) => x.path == 'src/x.rs'));
        const changes = [
          LspTextChange(1, 4, 1, 5, 'beta'), // b → beta
          LspTextChange(0, 9, 1, 0, ' // joined '), // 合并前两行
          LspTextChange(1, 2, 1, 3, 'D\nE'), // 中文 c 的 ' ' → 'D\nE'(按 UTF-16 列)
        ];
        expect(await lsp.didChangeIncremental('src/x.rs', changes), isTrue);
        final expected = lspApplyChanges('fn a() {}\nlet b = 1;\n中文 c', changes);
        expect(expected, 'fn a() {} // joined let beta = 1;\n中文D\nEc');
        if (incremental) {
          await _waitFor(() async => events, (e) => e.any((x) => x.diagnostics.any((d) => (d['message'] as String).startsWith('doc v2'))));
          final msg = events.lastWhere((x) => x.path == 'src/x.rs').diagnostics.single['message'] as String;
          expect(msg, 'doc v2 ranges: ${expected.replaceAll('\n', '\\n')}', reason: '服务端按范围应用后与编辑器内容一致');
        } else {
          await _waitFor(() async => events, (e) => e.any((x) => x.diagnostics.any((d) => d['message'] == 'echo: fn a() {} // joined let beta = 1; v2')));
        }
        await lsp.dispose();
        await sub.cancel();
      }
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));

    test('java: jdtls gets a per-project -data dir and a Java 21+ JAVA_HOME', () async {
      final dataRoot = Directory('${tmp.path}/jdtls-data')..createSync();
      final lsp = LspService(root.path, serverOverrides: {'java': serverCmd}, jdtlsDataRoot: dataRoot.path);
      final events = <LspDiagnosticsEvent>[];
      final sub = lsp.diagnostics.listen(events.add);
      await lsp.didOpen('src/main/java/A.java', 'class A {}\n');
      await _waitFor(() async => events, (e) => e.any((x) => x.path == 'src/main/java/A.java'));
      final msg = events.firstWhere((x) => x.path == 'src/main/java/A.java').diagnostics.single['message'] as String;
      final data = RegExp(r'data=(\S+)').firstMatch(msg)!.group(1)!;
      expect(data, startsWith(dataRoot.path), reason: '缓存放在指定目录,不写进项目');
      expect(Directory(data).existsSync(), isTrue);
      final javaHome = LspService.findJavaHome(minVersion: 21);
      if (javaHome != null) expect(msg, endsWith('java=$javaHome'));
      expect((await _serverStatus(lsp))['language'], 'java');
      await lsp.dispose();
      await sub.cancel();
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));

    test('plugin launch: resolver supplies the command; reloadServer switches the running server', () async {
      var launch = LspLaunch(serverCmd, source: 'plugin.one');
      final lsp = LspService(root.path, launchResolver: (g) => g == 'rust' ? launch : null);
      final events = <LspDiagnosticsEvent>[];
      final sub = lsp.diagnostics.listen(events.add);
      await lsp.didOpen('src/p.rs', 'first\n');
      final st1 = await _waitFor(() => _serverStatus(lsp), (s) => s['initialized'] == true);
      expect(st1['source'], 'plugin.one');
      final pid1 = st1['pid'] as int;
      await _waitFor(() async => events, (e) => e.any((x) => x.path == 'src/p.rs'));
      final before = events.where((x) => x.path == 'src/p.rs').length;

      launch = LspLaunch([...serverCmd, '--incremental'], source: 'plugin.two');
      await lsp.reloadServer('rust');
      final st2 = await _waitFor(() => _serverStatus(lsp), (s) => s['initialized'] == true && s['source'] == 'plugin.two');
      expect(st2['pid'], isNot(pid1));
      expect(await _pidAlive(pid1), isFalse, reason: '旧进程已停,也不会被自动重启');
      await _waitFor(() async => events, (e) => e.where((x) => x.path == 'src/p.rs').length > before);
      await lsp.dispose();
      await sub.cancel();
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));

    test('project group: Java projects share one server; diagnostics go back to the right project', () async {
      final dataRoot = Directory('${tmp.path}/jdtls-shared')..createSync();
      final rootA = await Directory('${tmp.path}/svc-a').create();
      final rootB = await Directory('${tmp.path}/svc-b').create();
      final rootC = await Directory('${tmp.path}/other').create();
      LspService.shareKeyFor = (r) => r == rootC.path ? null : 'g1';
      addTearDown(() => LspService.shareKeyFor = null);
      LspService make(Directory r) => LspService(r.path, serverOverrides: {'java': serverCmd}, jdtlsDataRoot: dataRoot.path);
      final a = make(rootA), b = make(rootB), c = make(rootC);
      final ea = <LspDiagnosticsEvent>[], eb = <LspDiagnosticsEvent>[];
      final subs = [a.diagnostics.listen(ea.add), b.diagnostics.listen(eb.add)];

      await a.didOpen('A.java', 'class A {}\n');
      final st = await _waitFor(() => _serverStatus(a), (s) => s['initialized'] == true);
      await b.didOpen('B.java', 'class B {}\n');
      await c.didOpen('C.java', 'class C {}\n');
      final stB = await _waitFor(() => _serverStatus(b), (s) => s['initialized'] == true);
      final stC = await _waitFor(() => _serverStatus(c), (s) => s['initialized'] == true);
      expect(stB['pid'], st['pid'], reason: '同组共用一个进程');
      expect(stB['projects'], 2);
      expect(stB['shared'], 'g1');
      expect(stC['pid'], isNot(st['pid']), reason: '不在组里的自己一个');

      await _waitFor(() async => eb, (e) => e.any((x) => x.path == 'B.java'));
      final msgB = eb.firstWhere((x) => x.path == 'B.java').diagnostics.single['message'] as String;
      expect(msgB, contains('folders=2'), reason: 'B 的目录加进了共用服务端的工作区');
      expect(RegExp(r'data=(\S+)').firstMatch(msgB)!.group(1), contains('group-g1'), reason: '缓存按组放');
      expect(ea.where((x) => x.path == 'B.java'), isEmpty, reason: '别的项目的诊断不串过来');
      expect(eb.where((x) => x.path == 'A.java'), isEmpty);

      // 一个项目关掉:进程还在给另一个用;最后一个关掉才停
      final pid = st['pid'] as int;
      await a.dispose();
      expect(await _pidAlive(pid), isTrue);
      await b.didChange('B.java', 'class B { int x; }\n');
      await b.dispose();
      expect(await _pidAlive(pid), isFalse);
      await c.dispose();
      for (final s in subs) {
        await s.cancel();
      }
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));

    test('project group: reloading (plugin changed) restarts the shared server once; leaving a group gets its own', () async {
      final rootA = await Directory('${tmp.path}/re-a').create();
      final rootB = await Directory('${tmp.path}/re-b').create();
      var key = <String, String?>{rootA.path: 'g2', rootB.path: 'g2'};
      LspService.shareKeyFor = (r) => key[r];
      addTearDown(() => LspService.shareKeyFor = null);
      final dataRoot = '${tmp.path}/jdtls-re';
      final a = LspService(rootA.path, serverOverrides: {'java': serverCmd}, jdtlsDataRoot: dataRoot);
      final b = LspService(rootB.path, serverOverrides: {'java': serverCmd}, jdtlsDataRoot: dataRoot);
      await a.didOpen('A.java', 'class A {}\n');
      await b.didOpen('B.java', 'class B {}\n');
      final old = (await _waitFor(() => _serverStatus(b), (s) => s['initialized'] == true && s['projects'] == 2))['pid'] as int;

      // 插件管理器对每个项目各调一次:整个组只重启一次
      await a.reloadServer('java');
      await b.reloadServer('java');
      final sa = await _waitFor(() => _serverStatus(a), (s) => s['initialized'] == true);
      final sb = await _waitFor(() => _serverStatus(b), (s) => s['initialized'] == true);
      expect(sa['pid'], sb['pid']);
      expect(sa['pid'], isNot(old));
      expect(await _pidAlive(old), isFalse);

      // B 移出项目组:自己开一个,A 那个照旧
      key = {rootA.path: 'g2', rootB.path: null};
      await b.reattachServer('java');
      final sb2 = await _waitFor(() => _serverStatus(b), (s) => s['initialized'] == true);
      expect(sb2['pid'], isNot(sa['pid']));
      expect(sb2['shared'], isNull);
      expect((await _serverStatus(a))['projects'], 1);
      expect(await _pidAlive(sa['pid'] as int), isTrue);
      await a.dispose();
      await b.dispose();
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));

    test('idle: a project in the background long enough has its server stopped; coming back restarts it', () async {
      final saved = (LspService.idleTimeout, LspService.idleCheckInterval);
      LspService.idleTimeout = const Duration(milliseconds: 300);
      LspService.idleCheckInterval = const Duration(milliseconds: 50);
      addTearDown(() {
        LspService.idleTimeout = saved.$1;
        LspService.idleCheckInterval = saved.$2;
      });
      // 全量并发跑时机器很忙:唤醒后重启 + 初始化可能超过默认的 10 秒请求超时
      final lsp = LspService(root.path, serverOverrides: {'rust': serverCmd}, requestTimeout: const Duration(seconds: 40));
      final events = <LspDiagnosticsEvent>[];
      final sub = lsp.diagnostics.listen(events.add);
      await lsp.didOpen('src/idle.rs', 'fn idle() {}\n');
      final st = await _waitFor(() => _serverStatus(lsp), (s) => s['initialized'] == true);
      final pid = st['pid'] as int;

      // 在前台:不挂起
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await _pidAlive(pid), isTrue);

      lsp.setActive(false);
      final suspended = await _waitFor(() => _serverStatus(lsp), (s) => s['state'] == 'suspended');
      expect(suspended['state'], 'suspended');
      expect(await _pidAlive(pid), isFalse, reason: '进程停了,内存还给系统');
      final before = events.length;
      await lsp.didChange('src/idle.rs', 'fn changed() {}\n');
      expect(events.length, before, reason: '挂起时不换成降级诊断,原来的留着');

      // 后台里有请求(比如结构视图):拉起来,按当前内容重放
      final symbols = await lsp.documentSymbols('src/idle.rs', 'fn changed() {}\n');
      expect(_names(symbols).first, 'Widget');
      final woke = await _waitFor(() => _serverStatus(lsp), (s) => s['initialized'] == true);
      expect(woke['pid'], isNot(pid));
      expect(woke['restarts'], 0, reason: '挂起不算崩溃');
      await _waitFor(() async => events, (e) => e.any((x) => x.diagnostics.any((d) => d['message'] == 'echo: fn changed() {}')));

      // 再挂起一次,切回前台时拉起
      final pid2 = woke['pid'] as int;
      await _waitFor(() => _serverStatus(lsp), (s) => s['state'] == 'suspended');
      expect(await _pidAlive(pid2), isFalse);
      lsp.setActive(true);
      final back = await _waitFor(() => _serverStatus(lsp), (s) => s['initialized'] == true);
      expect(back['state'], 'running');
      await lsp.dispose();
      await sub.cancel();
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));

    test('javaMajorVersion reads the JDK release file', () {
      final jdk = Directory('${tmp.path}/fake-jdk')..createSync();
      File('${jdk.path}/bin/java')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      File('${jdk.path}/release').writeAsStringSync('JAVA_VERSION="21.0.4"\n');
      expect(LspService.javaMajorVersion(jdk.path), 21);
      File('${jdk.path}/release').writeAsStringSync('JAVA_VERSION="1.8.0_402"\n');
      expect(LspService.javaMajorVersion(jdk.path), 8);
      expect(LspService.javaMajorVersion('${tmp.path}/nope'), isNull);
    });

    test('crashing server restarts at most 3 times, then falls back', () async {
      final lsp = LspService(root.path, serverOverrides: {'rust': [...serverCmd, '--crash-on-open']});
      final events = <LspDiagnosticsEvent>[];
      final sub = lsp.diagnostics.listen(events.add);
      await lsp.didOpen('src/lib.rs', 'fn broken( {\n');
      final st = await _waitFor(() => _serverStatus(lsp), (s) => s['state'] == 'crashed', timeout: const Duration(seconds: 40));
      expect(st['state'], 'crashed');
      expect(st['restarts'], LspService.maxRestarts + 1);
      await _waitFor(() async => events, (e) => e.isNotEmpty);
      expect(events.last.path, 'src/lib.rs');
      expect(events.last.diagnostics.map((d) => d['code']), everyElement('unclosed_bracket'));
      // 降级后的后续编辑直接给括号诊断。
      await lsp.didChange('src/lib.rs', 'fn ok() {}\n');
      await _waitFor(() async => events, (e) => e.last.diagnostics.isEmpty);
      expect(events.last.diagnostics, isEmpty);
      expect(_names(await lsp.documentSymbols('src/lib.rs', 'fn ok() {}\n')), ['ok']);
      await lsp.dispose();
      await sub.cancel();
    }, skip: dart == null ? 'no dart binary found' : false, timeout: const Timeout(Duration(seconds: 60)));
  });

  // =========================================================================
  // 降级:找不到服务端 / 未路由语言
  // =========================================================================

  group('fallback', () {
    late Directory root;

    setUp(() async => root = await Directory.systemTemp.createTemp('lsp_fallback_'));
    tearDown(() async {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });

    test('missing binary: status missing, bracket diagnostics, regex outline', () async {
      final lsp = LspService(root.path, serverOverrides: {'rust': ['/nonexistent/bin/rust-analyzer-xyz']});
      final events = <LspDiagnosticsEvent>[];
      final sub = lsp.diagnostics.listen(events.add);

      await lsp.didOpen('src/main.rs', 'struct A {\n    x: u32,\n}\nfn main() {\n');
      await _waitFor(() async => events, (e) => e.isNotEmpty);
      expect(events.single.path, 'src/main.rs');
      expect(events.single.diagnostics.single['code'], 'unclosed_bracket');
      expect((events.single.diagnostics.single['range'] as Map)['start'], {'line': 3, 'character': 10});

      final st = await _serverStatus(lsp);
      expect(st['language'], 'rust');
      expect(st['state'], 'missing');
      expect(st['command'], '/nonexistent/bin/rust-analyzer-xyz');

      final outline = await lsp.documentSymbols('src/main.rs', 'struct A {\n    x: u32,\n}\nfn main() {}\n');
      expect(_names(outline), ['A', 'main']);
      expect(_names(_children(outline.first)), ['x']);

      await lsp.dispose();
      await sub.cancel();
    });

    test('unrouted languages: C-like files get bracket checks, others nothing, no servers started', () async {
      final lsp = LspService(root.path);
      final events = <LspDiagnosticsEvent>[];
      final sub = lsp.diagnostics.listen(events.add);
      await lsp.didOpen('src/A.kt', 'class A { fun f() { }\n');
      await lsp.didOpen('README.md', '# (unbalanced\n');
      await _waitFor(() async => events, (e) => e.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events.map((e) => e.path), ['src/A.kt']);
      expect(events.single.diagnostics.single['code'], 'unclosed_bracket');
      expect((await lsp.status())['servers'], isEmpty);
      expect(await lsp.documentSymbols('README.md', '# x'), isEmpty);
      await lsp.dispose();
      await sub.cancel();
    });
  });

  // =========================================================================
  // 可选:真实 rust-analyzer(本机没有可用的 rust-analyzer 时跳过)
  // =========================================================================

  final home = Platform.environment['HOME'] ?? '';
  final hasRa = home.isNotEmpty && File('$home/.cargo/bin/rust-analyzer').existsSync();
  test('real rust-analyzer: documentSymbol from the server', () async {
    final root = await Directory.systemTemp.createTemp('lsp_ra_');
    final lsp = LspService(root.path);
    try {
      File('${root.path}/Cargo.toml').writeAsStringSync('[package]\nname = "ra_probe"\nversion = "0.1.0"\nedition = "2021"\n');
      Directory('${root.path}/src').createSync();
      const text = 'struct Probe { a: u32 }\nfn main() {\n    let _p = Probe { a: 1 };\n}\n';
      File('${root.path}/src/main.rs').writeAsStringSync(text);
      await lsp.didOpen('src/main.rs', text);
      final st = await _waitFor(() => _serverStatus(lsp), (s) => s['initialized'] == true || s['state'] != 'running',
          timeout: const Duration(seconds: 60));
      if (st['initialized'] != true) {
        markTestSkipped('rust-analyzer did not initialize: ${st['state']} ${st['error'] ?? ''}');
        return;
      }
      final symbols = await _waitFor(() => lsp.documentSymbols('src/main.rs', text), (s) => s.any((n) => n['detail'] != null),
          timeout: const Duration(seconds: 60));
      expect(_names(symbols), containsAll(['Probe', 'main']));
      expect(symbols.any((n) => n['detail'] != null), isTrue, reason: 'symbols should come from rust-analyzer, not the regex fallback');
    } finally {
      await lsp.dispose();
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    }
  }, skip: hasRa ? false : 'rust-analyzer not installed', timeout: const Timeout(Duration(seconds: 150)));

  // =========================================================================
  // 可选:真实 dart language-server / clangd(机器上有才跑)。用默认的服务器查找,
  // 所以同时验证了 Finder 启动场景下靠固定目录找到二进制这条路径。
  // =========================================================================

  Future<void> realServerCheck({
    required String file,
    required String text,
    required String expectSymbol,
    required Pattern expectMessage,
  }) async {
    final root = await Directory.systemTemp.createTemp('lsp_real_');
    final lsp = LspService(root.path);
    final events = <LspDiagnosticsEvent>[];
    final sub = lsp.diagnostics.listen(events.add);
    try {
      File('${root.path}/$file').writeAsStringSync(text);
      await lsp.didOpen(file, text);
      final st = await _waitFor(() => _serverStatus(lsp), (s) => s['initialized'] == true || s['state'] != 'running',
          timeout: const Duration(seconds: 60));
      expect(st['initialized'], isTrue, reason: 'server status: $st');

      // 真实服务器推送的诊断(source 不是兜底的 codelite)。
      final diag = await _waitFor(
        () async => events
            .where((e) => e.path == file)
            .expand((e) => e.diagnostics)
            .where((d) => d['source'] != 'codelite')
            .toList(),
        (ds) => ds.isNotEmpty,
        timeout: const Duration(seconds: 60),
      );
      expect(diag.map((d) => d['message'] as String).join('\n'), contains(expectMessage));
      expect(diag.first['severity'], 1);

      final symbols = await lsp.documentSymbols(file, text);
      expect(_names(symbols), contains(expectSymbol));
    } finally {
      await sub.cancel();
      await lsp.dispose();
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    }
  }

  final hasDart = [
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/dart-sdk/bin/dart',
    '$home/development/flutter/bin/cache/dart-sdk/bin/dart',
  ].any((p) => File(p).existsSync());
  test('real dart language-server: pushed diagnostics + documentSymbol', () async {
    await realServerCheck(
      file: 'probe.dart',
      text: "class Probe {}\nvoid main() {\n  int x = 'not an int';\n  print(x);\n}\n",
      expectSymbol: 'Probe',
      expectMessage: 'String',
    );
  }, skip: hasDart ? false : 'dart SDK not found', timeout: const Timeout(Duration(seconds: 150)));

  final hasClangd = File('/usr/bin/clangd').existsSync();
  test('real clangd: pushed diagnostics + documentSymbol', () async {
    await realServerCheck(
      file: 'probe.c',
      text: 'struct Probe { int a; };\nint main(void) {\n  return undeclared_thing;\n}\n',
      expectSymbol: 'main',
      expectMessage: 'undeclared',
    );
  }, skip: hasClangd ? false : 'clangd not installed', timeout: const Timeout(Duration(seconds: 150)));
}
