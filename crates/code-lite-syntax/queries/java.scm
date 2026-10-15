; 放在 tree-sitter-java 自带规则前面(先匹配的生效):按 IntelliJ 的着色补上语法树才分得清的几类。

((block_comment) @comment.documentation
 (#match? @comment.documentation "^/\\*\\*"))

; 字段:声明处、obj.field / this.field、枚举常量 —— IntelliJ 里的紫色
(field_declaration
  declarator: (variable_declarator name: (identifier) @property))
(field_access
  field: (identifier) @property)
(enum_constant
  name: (identifier) @property)

; 构造方法名和普通方法一样(自带规则当成类型)
(constructor_declaration
  name: (identifier) @function.method)

(super) @keyword
