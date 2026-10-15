; 放在 tree-sitter-python 自带规则前面(先匹配的生效)。

((call
  function: (identifier) @function.builtin)
 (#match?
   @function.builtin
   "^(abs|all|any|ascii|bin|bool|breakpoint|bytearray|bytes|callable|chr|classmethod|compile|complex|delattr|dict|dir|divmod|enumerate|eval|exec|filter|float|format|frozenset|getattr|globals|hasattr|hash|help|hex|id|input|int|isinstance|issubclass|iter|len|list|locals|map|max|memoryview|min|next|object|oct|open|ord|pow|print|property|range|repr|reversed|round|set|setattr|slice|sorted|staticmethod|str|sum|super|tuple|type|vars|zip|__import__)$"))

; 全大写是常量(自带规则先把大写开头的都当成类)
((identifier) @constant
 (#match? @constant "^_*[A-Z][A-Z\\d_]+$"))

((identifier) @variable.builtin
 (#any-of? @variable.builtin "self" "cls"))
