import 'dart:typed_data';

/// web 预览没有 Rust 库:没有语法树,着色全用 Dart 的逐行分词。
class SyntaxTreeDoc {
  SyntaxTreeDoc._();

  static SyntaxTreeDoc? open(String grammar, List<String> lines) => null;

  void edit(int start, int oldCount, List<String> newLines) {}

  int get status => 0;

  SyntaxSlice? highlight(int from, int to) => null;

  List<FoldRange>? folds(int from, int to) => null;

  void close() {}
}

/// [from] 起每一行的着色:扁平的 `[起列, 止列, 种类, …]`(UTF-16 列);`null` = 这行语法树还没跟上。
class SyntaxSlice {
  const SyntaxSlice(this.generation, this.from, this.lines);
  final int generation;
  final int from;
  final List<Uint32List?> lines;
}

/// 一段可折叠的范围:收起时 [start] 行留着,[start]+1 ..= [end] 行藏起来。
class FoldRange {
  const FoldRange(this.start, this.end);
  final int start;
  final int end;

  @override
  bool operator ==(Object other) => other is FoldRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'FoldRange($start..$end)';
}

String? syntaxGrammarForPath(String path) => null;

/// web 预览没有 Rust 库:结构视图用正则大纲。
Future<List<Map<String, dynamic>>?> rustOutline(String path, String text) async => null;
