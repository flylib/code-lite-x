; 接在 JavaScript 自带规则后面(后匹配的生效):和 Dart 的逐行分词一样,这几个全局对象算内置。
((identifier) @function.builtin
 (#any-of? @function.builtin "console" "require" "window" "document" "process"))
