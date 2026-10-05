/// 内置的语言定义。要支持新语言,在这里加一份 [LanguageSpec] 并放进 [builtinLanguages]。
library;

import 'language.dart';

const _cBlock = [('/*', '*/')];
const _cLine = ['//'];
const _dq = StringRule('"');
const _sq = StringRule("'");
const _charLit = StringRule("'", "'", false, true, 12);

const _javaKeywords = {
  'abstract', 'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum',
  'extends', 'final', 'finally', 'for', 'goto', 'if', 'implements', 'import', 'instanceof', 'interface', 'native',
  'new', 'package', 'private', 'protected', 'public', 'return', 'static', 'strictfp', 'super', 'switch',
  'synchronized', 'this', 'throw', 'throws', 'transient', 'try', 'volatile', 'while', 'var', 'record', 'sealed',
  'permits', 'non-sealed', 'yield',
};
const _javaTypes = {'boolean', 'byte', 'char', 'short', 'int', 'long', 'float', 'double', 'void'};
const _nullBool = {'true', 'false', 'null'};

const java = LanguageSpec(
  id: 'java',
  name: 'Java',
  extensions: ['java', 'jav'],
  keywords: _javaKeywords,
  types: _javaTypes,
  constants: _nullBool,
  lineComments: _cLine,
  blockComments: [('/**', '*/'), ('/*', '*/')],
  docComment: '/**',
  strings: [StringRule('"""', '"""', true), _dq, _charLit],
  annotation: '@',
  identifierExtra: r'$',
  upperCaseIsType: true,
);

const kotlin = LanguageSpec(
  id: 'kotlin',
  name: 'Kotlin',
  extensions: ['kt', 'kts'],
  keywords: {
    'as', 'break', 'class', 'continue', 'do', 'else', 'for', 'fun', 'if', 'in', 'interface', 'is', 'object',
    'package', 'return', 'super', 'this', 'throw', 'try', 'typealias', 'typeof', 'val', 'var', 'when', 'while',
    'by', 'catch', 'constructor', 'delegate', 'dynamic', 'field', 'file', 'finally', 'get', 'import', 'init',
    'param', 'property', 'receiver', 'set', 'setparam', 'where', 'actual', 'abstract', 'annotation', 'companion',
    'const', 'crossinline', 'data', 'enum', 'expect', 'external', 'final', 'infix', 'inline', 'inner', 'internal',
    'lateinit', 'noinline', 'open', 'operator', 'out', 'override', 'private', 'protected', 'public', 'reified',
    'sealed', 'suspend', 'tailrec', 'vararg', 'value',
  },
  constants: _nullBool,
  lineComments: _cLine,
  blockComments: [('/**', '*/'), ('/*', '*/')],
  docComment: '/**',
  strings: [StringRule('"""', '"""', true, false), _dq, _charLit],
  annotation: '@',
  upperCaseIsType: true,
);

const groovy = LanguageSpec(
  id: 'groovy',
  name: 'Groovy',
  extensions: ['groovy', 'gradle', 'gvy'],
  fileNames: ['Jenkinsfile'],
  keywords: {
    ..._javaKeywords, 'def', 'in', 'as', 'trait', 'it',
  },
  types: _javaTypes,
  constants: _nullBool,
  lineComments: _cLine,
  blockComments: [('/**', '*/'), ('/*', '*/')],
  docComment: '/**',
  strings: [StringRule('"""', '"""', true), StringRule("'''", "'''", true), _dq, _sq],
  annotation: '@',
  identifierExtra: r'$',
  upperCaseIsType: true,
);

const dart = LanguageSpec(
  id: 'dart',
  name: 'Dart',
  extensions: ['dart'],
  keywords: {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case', 'catch', 'class', 'const', 'continue',
    'covariant', 'default', 'deferred', 'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
    'external', 'factory', 'final', 'finally', 'for', 'Function', 'get', 'hide', 'if', 'implements', 'import',
    'in', 'interface', 'is', 'late', 'library', 'mixin', 'new', 'of', 'on', 'operator', 'part', 'required',
    'rethrow', 'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this', 'throw', 'try',
    'type', 'typedef', 'var', 'void', 'when', 'while', 'with', 'yield',
  },
  types: {'int', 'double', 'num', 'bool', 'String', 'List', 'Map', 'Set', 'Object', 'Future', 'Stream', 'Never'},
  constants: _nullBool,
  lineComments: _cLine,
  blockComments: _cBlock,
  strings: [
    StringRule("r'''", "'''", true, false), StringRule('r"""', '"""', true, false),
    StringRule("'''", "'''", true), StringRule('"""', '"""', true),
    StringRule("r'", "'", false, false), StringRule('r"', '"', false, false), _dq, _sq,
  ],
  annotation: '@',
  identifierExtra: r'$',
  upperCaseIsType: true,
);

const rust = LanguageSpec(
  id: 'rust',
  name: 'Rust',
  extensions: ['rs'],
  keywords: {
    'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn', 'else', 'enum', 'extern', 'fn', 'for',
    'if', 'impl', 'in', 'let', 'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return', 'self', 'Self',
    'static', 'struct', 'super', 'trait', 'type', 'union', 'unsafe', 'use', 'where', 'while', 'yield',
  },
  types: {
    'i8', 'i16', 'i32', 'i64', 'i128', 'isize', 'u8', 'u16', 'u32', 'u64', 'u128', 'usize', 'f32', 'f64', 'bool',
    'char', 'str',
  },
  constants: {'true', 'false', 'None', 'Some', 'Ok', 'Err'},
  lineComments: _cLine,
  blockComments: _cBlock,
  strings: [StringRule('r#"', '"#', true, false), StringRule('r"', '"', true, false), StringRule('"', '"', true), _charLit],
  annotation: '#[',
  upperCaseIsType: true,
);

const go = LanguageSpec(
  id: 'go',
  name: 'Go',
  extensions: ['go'],
  keywords: {
    'break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else', 'fallthrough', 'for', 'func', 'go',
    'goto', 'if', 'import', 'interface', 'map', 'package', 'range', 'return', 'select', 'struct', 'switch', 'type',
    'var',
  },
  types: {
    'bool', 'byte', 'complex64', 'complex128', 'error', 'float32', 'float64', 'int', 'int8', 'int16', 'int32',
    'int64', 'rune', 'string', 'uint', 'uint8', 'uint16', 'uint32', 'uint64', 'uintptr', 'any',
  },
  constants: {'true', 'false', 'nil', 'iota'},
  builtins: {'append', 'cap', 'close', 'copy', 'delete', 'len', 'make', 'new', 'panic', 'print', 'println', 'recover'},
  lineComments: _cLine,
  blockComments: _cBlock,
  strings: [StringRule('`', '`', true, false), _dq, _charLit],
);

const _cKeywords = {
  'auto', 'break', 'case', 'const', 'continue', 'default', 'do', 'else', 'enum', 'extern', 'for', 'goto', 'if',
  'inline', 'register', 'restrict', 'return', 'sizeof', 'static', 'struct', 'switch', 'typedef', 'union',
  'volatile', 'while',
};
const _cTypes = {
  'char', 'double', 'float', 'int', 'long', 'short', 'signed', 'unsigned', 'void', 'bool', 'size_t', 'int8_t',
  'int16_t', 'int32_t', 'int64_t', 'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t',
};

const c = LanguageSpec(
  id: 'c',
  name: 'C',
  extensions: ['c', 'h'],
  keywords: _cKeywords,
  types: _cTypes,
  constants: {'true', 'false', 'NULL'},
  lineComments: _cLine,
  blockComments: _cBlock,
  strings: [_dq, _charLit],
  preprocessor: true,
);

const cpp = LanguageSpec(
  id: 'cpp',
  name: 'C++',
  extensions: ['cpp', 'cc', 'cxx', 'hpp', 'hh', 'hxx', 'ipp', 'mm', 'm'],
  keywords: {
    ..._cKeywords, 'alignas', 'alignof', 'catch', 'class', 'constexpr', 'consteval', 'const_cast', 'decltype',
    'delete', 'dynamic_cast', 'explicit', 'export', 'friend', 'mutable', 'namespace', 'new', 'noexcept',
    'operator', 'override', 'final', 'private', 'protected', 'public', 'reinterpret_cast', 'static_assert',
    'static_cast', 'template', 'this', 'throw', 'try', 'typeid', 'typename', 'using', 'virtual', 'co_await',
    'co_return', 'co_yield', 'concept', 'requires',
  },
  types: {..._cTypes, 'wchar_t', 'char8_t', 'char16_t', 'char32_t', 'auto', 'string', 'vector', 'map'},
  constants: {'true', 'false', 'nullptr', 'NULL'},
  lineComments: _cLine,
  blockComments: _cBlock,
  strings: [StringRule('R"(', ')"', true, false), _dq, _charLit],
  preprocessor: true,
  upperCaseIsType: true,
);

const csharp = LanguageSpec(
  id: 'csharp',
  name: 'C#',
  extensions: ['cs', 'csx'],
  keywords: {
    'abstract', 'as', 'base', 'break', 'case', 'catch', 'checked', 'class', 'const', 'continue', 'default',
    'delegate', 'do', 'else', 'enum', 'event', 'explicit', 'extern', 'finally', 'fixed', 'for', 'foreach', 'goto',
    'if', 'implicit', 'in', 'interface', 'internal', 'is', 'lock', 'namespace', 'new', 'operator', 'out',
    'override', 'params', 'private', 'protected', 'public', 'readonly', 'ref', 'return', 'sealed', 'sizeof',
    'stackalloc', 'static', 'struct', 'switch', 'this', 'throw', 'try', 'typeof', 'unchecked', 'unsafe', 'using',
    'virtual', 'volatile', 'while', 'async', 'await', 'var', 'record', 'get', 'set', 'init', 'yield', 'where',
  },
  types: {
    'bool', 'byte', 'char', 'decimal', 'double', 'float', 'int', 'long', 'object', 'sbyte', 'short', 'string',
    'uint', 'ulong', 'ushort', 'void', 'dynamic',
  },
  constants: _nullBool,
  lineComments: _cLine,
  blockComments: _cBlock,
  strings: [StringRule('"""', '"""', true, false), StringRule('@"', '"', true, false), _dq, _charLit],
  preprocessor: true,
  upperCaseIsType: true,
);

const swift = LanguageSpec(
  id: 'swift',
  name: 'Swift',
  extensions: ['swift'],
  keywords: {
    'associatedtype', 'class', 'deinit', 'enum', 'extension', 'fileprivate', 'func', 'import', 'init', 'inout',
    'internal', 'let', 'open', 'operator', 'private', 'protocol', 'public', 'rethrows', 'static', 'struct',
    'subscript', 'typealias', 'var', 'break', 'case', 'continue', 'default', 'defer', 'do', 'else', 'fallthrough',
    'for', 'guard', 'if', 'in', 'repeat', 'return', 'switch', 'where', 'while', 'as', 'catch', 'is', 'super',
    'self', 'Self', 'throw', 'throws', 'try', 'async', 'await', 'some', 'any', 'actor', 'final', 'override',
    'mutating', 'lazy', 'weak', 'convenience', 'required',
  },
  constants: {'true', 'false', 'nil'},
  lineComments: _cLine,
  blockComments: _cBlock,
  strings: [StringRule('"""', '"""', true), _dq],
  annotation: '@',
  upperCaseIsType: true,
);

const _jsKeywords = {
  'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger', 'default', 'delete',
  'do', 'else', 'export', 'extends', 'finally', 'for', 'from', 'function', 'if', 'import', 'in', 'instanceof',
  'let', 'new', 'of', 'return', 'static', 'super', 'switch', 'this', 'throw', 'try', 'typeof', 'var', 'void',
  'while', 'with', 'yield', 'get', 'set',
};
const _jsConstants = {'true', 'false', 'null', 'undefined', 'NaN', 'Infinity'};
const _jsStrings = [StringRule('`', '`', true), _dq, _sq];

const javascript = LanguageSpec(
  id: 'javascript',
  name: 'JavaScript',
  extensions: ['js', 'mjs', 'cjs', 'jsx'],
  shebangs: ['node'],
  keywords: _jsKeywords,
  constants: _jsConstants,
  builtins: {'console', 'require', 'module', 'exports', 'window', 'document', 'process'},
  lineComments: _cLine,
  blockComments: [('/**', '*/'), ('/*', '*/')],
  docComment: '/**',
  strings: _jsStrings,
  annotation: '@',
  identifierExtra: r'$',
  upperCaseIsType: true,
);

const typescript = LanguageSpec(
  id: 'typescript',
  name: 'TypeScript',
  extensions: ['ts', 'tsx', 'mts', 'cts'],
  keywords: {
    ..._jsKeywords, 'abstract', 'as', 'declare', 'enum', 'implements', 'interface', 'keyof', 'namespace',
    'private', 'protected', 'public', 'readonly', 'type', 'is', 'infer', 'satisfies', 'override', 'module',
  },
  types: {'any', 'boolean', 'number', 'string', 'symbol', 'bigint', 'object', 'unknown', 'never', 'void'},
  constants: _jsConstants,
  builtins: {'console', 'require', 'window', 'document', 'process'},
  lineComments: _cLine,
  blockComments: [('/**', '*/'), ('/*', '*/')],
  docComment: '/**',
  strings: _jsStrings,
  annotation: '@',
  identifierExtra: r'$',
  upperCaseIsType: true,
);

const python = LanguageSpec(
  id: 'python',
  name: 'Python',
  extensions: ['py', 'pyw', 'pyi'],
  shebangs: ['python', 'python3'],
  keywords: {
    'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except',
    'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal', 'not', 'or', 'pass',
    'raise', 'return', 'try', 'while', 'with', 'yield', 'match', 'case', 'self', 'cls',
  },
  constants: {'True', 'False', 'None'},
  builtins: {
    'abs', 'all', 'any', 'bool', 'bytes', 'dict', 'dir', 'enumerate', 'filter', 'float', 'format', 'getattr',
    'hasattr', 'int', 'isinstance', 'iter', 'len', 'list', 'map', 'max', 'min', 'next', 'object', 'open', 'print',
    'range', 'repr', 'reversed', 'set', 'setattr', 'sorted', 'str', 'sum', 'super', 'tuple', 'type', 'zip',
  },
  lineComments: ['#'],
  strings: [StringRule('"""', '"""', true), StringRule("'''", "'''", true), _dq, _sq],
  annotation: '@',
  upperCaseIsType: true,
);

const ruby = LanguageSpec(
  id: 'ruby',
  name: 'Ruby',
  extensions: ['rb', 'rake', 'gemspec'],
  fileNames: ['Gemfile', 'Rakefile', 'Podfile'],
  shebangs: ['ruby'],
  keywords: {
    'alias', 'and', 'begin', 'break', 'case', 'class', 'def', 'defined?', 'do', 'else', 'elsif', 'end', 'ensure',
    'for', 'if', 'in', 'module', 'next', 'not', 'or', 'redo', 'rescue', 'retry', 'return', 'self', 'super', 'then',
    'undef', 'unless', 'until', 'when', 'while', 'yield', 'require', 'attr_accessor', 'attr_reader', 'puts',
  },
  constants: {'true', 'false', 'nil'},
  lineComments: ['#'],
  blockComments: [('=begin', '=end')],
  strings: [_dq, _sq],
  variableSigil: '@',
  upperCaseIsType: true,
);

const php = LanguageSpec(
  id: 'php',
  name: 'PHP',
  extensions: ['php', 'phtml'],
  keywords: {
    'abstract', 'and', 'array', 'as', 'break', 'callable', 'case', 'catch', 'class', 'clone', 'const', 'continue',
    'declare', 'default', 'do', 'echo', 'else', 'elseif', 'empty', 'enddeclare', 'endfor', 'endforeach', 'endif',
    'endswitch', 'endwhile', 'extends', 'final', 'finally', 'fn', 'for', 'foreach', 'function', 'global', 'if',
    'implements', 'include', 'include_once', 'instanceof', 'insteadof', 'interface', 'isset', 'list', 'match',
    'namespace', 'new', 'or', 'print', 'private', 'protected', 'public', 'readonly', 'require', 'require_once',
    'return', 'static', 'switch', 'throw', 'trait', 'try', 'unset', 'use', 'var', 'while', 'xor', 'yield',
  },
  constants: {'true', 'false', 'null', 'TRUE', 'FALSE', 'NULL'},
  lineComments: ['//', '#'],
  blockComments: [('/**', '*/'), ('/*', '*/')],
  docComment: '/**',
  strings: [_dq, _sq],
  variableSigil: r'$',
  upperCaseIsType: true,
);

const shell = LanguageSpec(
  id: 'shellscript',
  name: 'Shell Script',
  extensions: ['sh', 'bash', 'zsh', 'ksh', 'fish', 'command'],
  fileNames: ['.bashrc', '.zshrc', '.bash_profile', '.profile', '.zprofile', '.envrc'],
  shebangs: ['sh', 'bash', 'zsh', 'ksh', 'dash'],
  keywords: {
    'if', 'then', 'else', 'elif', 'fi', 'case', 'esac', 'for', 'while', 'until', 'do', 'done', 'in', 'function',
    'select', 'return', 'exit', 'local', 'export', 'readonly', 'declare', 'unset', 'shift', 'source', 'set',
    'trap', 'eval', 'exec', 'break', 'continue',
  },
  builtins: {'echo', 'printf', 'read', 'cd', 'test', 'cat', 'grep', 'sed', 'awk', 'mkdir', 'rm', 'cp', 'mv'},
  constants: {'true', 'false'},
  lineComments: ['#'],
  strings: [StringRule('"', '"', true), StringRule("'", "'", true, false)],
  variableSigil: r'$',
);

const sql = LanguageSpec(
  id: 'sql',
  name: 'SQL',
  extensions: ['sql', 'ddl', 'dml', 'hql', 'psql', 'mysql'],
  keywords: {
    'select', 'from', 'where', 'and', 'or', 'not', 'insert', 'into', 'values', 'update', 'set', 'delete', 'create',
    'table', 'drop', 'alter', 'add', 'column', 'index', 'view', 'primary', 'key', 'foreign', 'references', 'join',
    'inner', 'left', 'right', 'outer', 'full', 'cross', 'on', 'as', 'group', 'by', 'order', 'having', 'limit',
    'offset', 'union', 'all', 'distinct', 'case', 'when', 'then', 'else', 'end', 'is', 'null', 'like', 'in',
    'between', 'exists', 'default', 'unique', 'constraint', 'asc', 'desc', 'if', 'begin', 'commit', 'rollback',
    'transaction', 'with', 'recursive', 'returning', 'database', 'schema', 'grant', 'revoke', 'truncate',
    'auto_increment', 'engine', 'charset', 'comment', 'unsigned', 'cascade', 'over', 'partition', 'interval',
  },
  types: {
    'int', 'integer', 'bigint', 'smallint', 'tinyint', 'decimal', 'numeric', 'float', 'double', 'real', 'char',
    'varchar', 'text', 'longtext', 'date', 'datetime', 'timestamp', 'time', 'boolean', 'bool', 'blob', 'json',
    'uuid', 'serial',
  },
  constants: {'true', 'false', 'null'},
  builtins: {'count', 'sum', 'avg', 'min', 'max', 'coalesce', 'ifnull', 'now', 'concat', 'substring', 'cast', 'round'},
  lineComments: ['--', '#'],
  blockComments: _cBlock,
  strings: [StringRule("'", "'", true), StringRule('"', '"'), StringRule('`', '`', false, false)],
  caseInsensitive: true,
);

const css = LanguageSpec(
  id: 'css',
  name: 'CSS',
  extensions: ['css', 'scss', 'sass', 'less'],
  keywords: {'important', 'media', 'import', 'keyframes', 'font-face', 'supports', 'include', 'mixin', 'extend', 'use'},
  constants: {'none', 'auto', 'inherit', 'initial', 'unset'},
  lineComments: _cLine,
  blockComments: _cBlock,
  strings: [_dq, _sq],
  annotation: '@',
  identifierExtra: '-',
  variableSigil: r'$',
);

const dockerfile = LanguageSpec(
  id: 'dockerfile',
  name: 'Dockerfile',
  extensions: ['dockerfile'],
  fileNames: ['Dockerfile', 'Containerfile'],
  keywords: {
    'from', 'run', 'cmd', 'label', 'maintainer', 'expose', 'env', 'add', 'copy', 'entrypoint', 'volume', 'user',
    'workdir', 'arg', 'onbuild', 'stopsignal', 'healthcheck', 'shell', 'as',
  },
  lineComments: ['#'],
  strings: [_dq, _sq],
  caseInsensitive: true,
  variableSigil: r'$',
);

const makefile = LanguageSpec(
  id: 'makefile',
  name: 'Makefile',
  extensions: ['mk', 'mak'],
  fileNames: ['Makefile', 'makefile', 'GNUmakefile'],
  keywords: {'ifeq', 'ifneq', 'ifdef', 'ifndef', 'else', 'endif', 'include', 'define', 'endef', 'export', 'override', '.PHONY'},
  lineComments: ['#'],
  strings: [_dq, _sq],
  variableSigil: r'$',
);

// ---- 非类 C 结构的格式 ----

const xml = LanguageSpec(
  id: 'xml',
  name: 'XML',
  mode: SyntaxMode.markup,
  extensions: ['xml', 'xsd', 'xsl', 'xslt', 'svg', 'plist', 'wsdl', 'xaml', 'csproj', 'fxml', 'iml', 'storyboard', 'xib'],
);

const html = LanguageSpec(
  id: 'html',
  name: 'HTML',
  mode: SyntaxMode.markup,
  extensions: ['html', 'htm', 'xhtml', 'vue', 'svelte', 'jsp', 'ftl', 'hbs', 'mustache'],
);

const jsonLang = LanguageSpec(
  id: 'json',
  name: 'JSON',
  mode: SyntaxMode.json,
  extensions: ['json', 'jsonc', 'json5', 'arb', 'har', 'webmanifest'],
  fileNames: ['.babelrc', '.eslintrc', '.prettierrc', 'composer.lock'],
);

const yaml = LanguageSpec(
  id: 'yaml',
  name: 'YAML',
  mode: SyntaxMode.yaml,
  extensions: ['yaml', 'yml'],
  fileNames: ['.clang-format', 'pubspec.lock'],
);

const markdown = LanguageSpec(
  id: 'markdown',
  name: 'Markdown',
  mode: SyntaxMode.markdown,
  extensions: ['md', 'markdown', 'mdx', 'mdown'],
);

const toml = LanguageSpec(
  id: 'toml',
  name: 'TOML',
  mode: SyntaxMode.ini,
  extensions: ['toml'],
  fileNames: ['Cargo.lock', 'Pipfile'],
  lineComments: ['#'],
);

const ini = LanguageSpec(
  id: 'ini',
  name: 'INI',
  mode: SyntaxMode.ini,
  extensions: ['ini', 'cfg', 'conf', 'editorconfig', 'gitconfig', 'env'],
  fileNames: ['.editorconfig', '.gitconfig', '.env', '.npmrc', '.gitmodules'],
  lineComments: [';', '#'],
);

const properties = LanguageSpec(
  id: 'properties',
  name: 'Properties',
  mode: SyntaxMode.ini,
  extensions: ['properties'],
  fileNames: ['gradle.properties', 'local.properties'],
  lineComments: ['#', '!'],
);

const gitignore = LanguageSpec(
  id: 'ignore',
  name: 'Ignore File',
  mode: SyntaxMode.ini,
  fileNames: ['.gitignore', '.dockerignore', '.npmignore', '.prettierignore', '.eslintignore'],
  lineComments: ['#'],
);

/// 全部内置语言。顺序只影响 `#!` 识别时的先后。
/// 常用语言开箱即用;Scala、Lua、PowerShell、Protobuf、GraphQL 等改由插件提供着色规则(见 builtin_catalog.dart)。
const List<LanguageSpec> builtinLanguages = [
  java, kotlin, groovy, dart, rust, go, c, cpp, csharp, swift, javascript, typescript, python, ruby, php,
  shell, sql, css, dockerfile, makefile, xml, html, jsonLang, yaml, markdown,
  toml, ini, properties, gitignore,
];

/// 应用里共用的一份注册表。
final LanguageRegistry languages = LanguageRegistry(builtinLanguages);
