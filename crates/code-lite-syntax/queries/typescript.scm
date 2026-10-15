; 接在 TypeScript 自带规则和 JavaScript 规则后面(后匹配的生效):
; TypeScript 把大写开头的标识符都当成类型,全大写的还是常量。
((identifier) @constant
 (#match? @constant "^_*[A-Z][A-Z\\d_]+$"))
