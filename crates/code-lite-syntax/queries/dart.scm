; 接在 tree-sitter-dart 自带规则后面(后匹配的生效)。

; 字符串插值 ${...} 里面不是字符串
(template_substitution) @embedded
(template_substitution
  "$" @punctuation.special
  "{" @punctuation.special
  "}" @punctuation.special)

(void_type) @keyword
