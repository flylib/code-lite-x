// 读构建文件(pom.xml)用的极简 XML 解析:只要元素树和文本。
//
// 不处理命名空间、DTD 与属性值里的实体;注释、CDATA、处理指令照规矩跳过。
// 写坏的文件尽量容错(不配对的结束标签忽略,没闭合的元素在文件末尾自动闭合),
// 实在读不下去才抛 [FormatException]。

class XmlElement {
  XmlElement(this.name);

  final String name;
  final List<XmlElement> children = [];
  final StringBuffer _text = StringBuffer();

  /// 直接包含的文本(不含子元素的),去掉首尾空白。
  String get text => _text.toString().trim();

  /// 第一个名为 [name] 的直接子元素。
  XmlElement? child(String name) {
    for (final c in children) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// 所有名为 [name] 的直接子元素。
  Iterable<XmlElement> childrenNamed(String name) => children.where((c) => c.name == name);

  /// 直接子元素 [name] 的文本;没有或为空时 null。
  String? childText(String name) {
    final t = child(name)?.text;
    return t == null || t.isEmpty ? null : t;
  }
}

/// 解析 [source],返回根元素。
XmlElement parseXml(String source) {
  final root = XmlElement('#document');
  final stack = <XmlElement>[root];
  var i = 0;
  final n = source.length;

  int find(String token, int from, String what) {
    final at = source.indexOf(token, from);
    if (at < 0) throw FormatException('XML 未结束的$what', source, from);
    return at;
  }

  while (i < n) {
    final lt = source.indexOf('<', i);
    final textEnd = lt < 0 ? n : lt;
    if (textEnd > i) stack.last._text.write(_decode(source.substring(i, textEnd)));
    if (lt < 0) break;
    if (source.startsWith('<!--', lt)) {
      i = find('-->', lt + 4, '注释') + 3;
    } else if (source.startsWith('<![CDATA[', lt)) {
      final end = find(']]>', lt + 9, 'CDATA');
      stack.last._text.write(source.substring(lt + 9, end));
      i = end + 3;
    } else if (source.startsWith('<?', lt)) {
      i = find('?>', lt + 2, '处理指令') + 2;
    } else if (source.startsWith('<!', lt)) {
      i = find('>', lt + 2, '声明') + 1; // <!DOCTYPE ...>(不支持内部子集)
    } else if (source.startsWith('</', lt)) {
      final end = find('>', lt + 2, '结束标签');
      final name = source.substring(lt + 2, end).trim();
      // 往回找同名元素闭合;找不到(多余的结束标签)就忽略
      final at = stack.lastIndexWhere((e) => e.name == name);
      if (at > 0) stack.removeRange(at, stack.length);
      i = end + 1;
    } else {
      final end = _tagEnd(source, lt + 1);
      if (end < 0) throw FormatException('XML 未结束的标签', source, lt);
      var body = source.substring(lt + 1, end);
      final selfClosing = body.endsWith('/');
      if (selfClosing) body = body.substring(0, body.length - 1);
      final name = RegExp(r'^[^\s/>]+').stringMatch(body.trimLeft()) ?? '';
      if (name.isEmpty) throw FormatException('XML 标签没有名字', source, lt);
      final e = XmlElement(name);
      stack.last.children.add(e);
      if (!selfClosing) stack.add(e);
      i = end + 1;
    }
  }
  final top = root.children.isEmpty ? null : root.children.first;
  if (top == null) throw const FormatException('XML 里没有元素');
  return top;
}

/// 开始标签的 `>` 位置(跳过属性值里的 `>`)。
int _tagEnd(String s, int from) {
  String? quote;
  for (var i = from; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == quote) quote = null;
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '>') {
      return i;
    }
  }
  return -1;
}

final RegExp _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|amp|quot|apos);');

String _decode(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entity, (m) {
    final e = m.group(1)!;
    if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
    if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
    return const {'lt': '<', 'gt': '>', 'amp': '&', 'quot': '"', 'apos': "'"}[e]!;
  });
}
