/// 语法高亮的语言定义:每种语言一份 [LanguageSpec],由 [LanguageRegistry] 按文件名识别。
///
/// 高亮引擎([tokenizeLine])只认这份声明,不再为某种语言写死规则 —— 加一种语言就是加一份定义。
/// 类 C 语言(Java、Kotlin、Go、JS/TS、Python……)共用通用的代码分词器;
/// XML/HTML、JSON、YAML、Markdown、INI/TOML/properties 这类结构不同的格式用各自的 [SyntaxMode]。
library;

/// 分词器种类。
enum SyntaxMode { code, markup, json, yaml, markdown, ini, plain }

/// 一种字符串字面量。
class StringRule {
  const StringRule(this.open, [String? close, this.multiline = false, this.escapes = true, this.maxLength])
      : close = close ?? open;

  final String open;
  final String close;

  /// 可以跨行(Java/Kotlin 的 `"""`、JS 的模板字符串、Go 的反引号)。
  final bool multiline;

  /// `\` 转义下一个字符。
  final bool escapes;

  /// 字符字面量:超过这个长度还没闭合就不当字符串(Rust 的生命周期 `'a`)。
  final int? maxLength;
}

class LanguageSpec {
  const LanguageSpec({
    required this.id,
    required this.name,
    this.mode = SyntaxMode.code,
    this.extensions = const [],
    this.fileNames = const [],
    this.shebangs = const [],
    this.keywords = const {},
    this.types = const {},
    this.constants = const {},
    this.builtins = const {},
    this.lineComments = const [],
    this.blockComments = const [],
    this.docComment,
    this.strings = const [],
    this.annotation,
    this.caseInsensitive = false,
    this.identifierExtra = '',
    this.upperCaseIsType = false,
    this.preprocessor = false,
    this.variableSigil,
  });

  /// 稳定标识(LSP 的 languageId 风格),如 `java`、`typescript`。
  final String id;

  /// 显示名,状态栏用。
  final String name;
  final SyntaxMode mode;

  /// 不带点、小写。
  final List<String> extensions;

  /// 整个文件名匹配(`Dockerfile`、`Makefile`、`pom.xml` 之类)。
  final List<String> fileNames;

  /// 没有扩展名时看首行 `#!`,如 `python`、`bash`。
  final List<String> shebangs;

  final Set<String> keywords;
  final Set<String> types;

  /// true / false / null 之类。
  final Set<String> constants;

  /// 内置函数(Python 的 print、len)。
  final Set<String> builtins;
  final List<String> lineComments;
  final List<(String, String)> blockComments;

  /// 文档注释的开头(`/**`、`///` 不算 —— 那是行注释),用另一种颜色。
  final String? docComment;

  /// 按顺序匹配,长的放前面(`"""` 在 `"` 前)。
  final List<StringRule> strings;

  /// 注解 / 装饰器前缀:`@`(Java、Kotlin、TS、Python)、`#[`(Rust)。
  final String? annotation;

  /// 关键字不区分大小写(SQL)。
  final bool caseInsensitive;

  /// 标识符里额外允许的字符(Java/JS 的 `$`、CSS 的 `-`)。
  final String identifierExtra;

  /// 大写开头的标识符当作类型(Java、Kotlin、Dart、Rust……)。
  final bool upperCaseIsType;

  /// 行首 `#` 是预处理指令(C/C++/C#/Objective-C)。
  final bool preprocessor;

  /// 变量前缀(Shell / PHP / Perl 的 `$`)。
  final String? variableSigil;

  @override
  String toString() => 'LanguageSpec($id)';
}

/// 按文件路径识别语言。
class LanguageRegistry {
  LanguageRegistry(this.languages)
      : _byExt = {
          for (final l in languages)
            for (final e in l.extensions) e: l,
        },
        _byName = {
          for (final l in languages)
            for (final n in l.fileNames) n.toLowerCase(): l,
        };

  final List<LanguageSpec> languages;
  final Map<String, LanguageSpec> _byExt;
  final Map<String, LanguageSpec> _byName;

  static const LanguageSpec plainText = LanguageSpec(id: 'plaintext', name: 'Plain Text', mode: SyntaxMode.plain);

  /// [firstLine] 用于没有扩展名的脚本(看 `#!`)。识别不了返回 [plainText]。
  LanguageSpec detect(String path, {String? firstLine}) {
    final name = path.split('/').last.split('\\').last;
    final lower = name.toLowerCase();
    final byName = _byName[lower];
    if (byName != null) return byName;
    // Dockerfile.dev、Makefile.inc 之类
    for (final entry in _byName.entries) {
      if (lower.startsWith('${entry.key}.')) return entry.value;
    }
    final dot = lower.lastIndexOf('.');
    if (dot > 0 && dot < lower.length - 1) {
      final byExt = _byExt[lower.substring(dot + 1)];
      if (byExt != null) return byExt;
    }
    if (firstLine != null && firstLine.startsWith('#!')) {
      for (final l in languages) {
        if (l.shebangs.any((s) => RegExp('[/ ]$s(\\d[\\d.]*)?(\\s|\$)').hasMatch(firstLine))) return l;
      }
    }
    return plainText;
  }

  LanguageSpec? byId(String id) {
    for (final l in languages) {
      if (l.id == id) return l;
    }
    return null;
  }
}
