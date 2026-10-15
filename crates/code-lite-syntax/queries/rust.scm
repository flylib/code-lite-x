; 接在 tree-sitter-rust 自带规则后面(后匹配的生效)。

; 自带的全大写常量规则正则写错了(多了个 ')
((identifier) @constant
 (#match? @constant "^_*[A-Z][A-Z\\d_]+$"))

[(integer_literal) (float_literal)] @number

; 和 Dart 的逐行分词一样,这几个算常量
((identifier) @constant.builtin
 (#any-of? @constant.builtin "Some" "None" "Ok" "Err"))
