# Rust 负责的核心任务

Flutter(Dart)管界面和交互;**计算量大、数据量大、或要和操作系统打交道的活交给 Rust**,
编成 `libcodelite.dylib`,经 C 调用约定(FFI)在同一个进程里调用(见 `crates/code-lite-ffi`、
`apps/code_lite_ui/lib/core/ffi/codelite_bindings.dart`)。

**新增 Rust 负责的事项都记在这里**,并随实现更新状态。选型依据(实测数字)见文末。

状态:✅ 完成 · 🚧 进行中 · ⏳ 待做 · 🔍 待评估

| # | 事项 | 状态 | 说明 | 提交 |
|---|---|---|---|---|
| 0 | 交互终端:PTY + vt100 解析 | ✅ | 每个项目一个 Rust 上下文;后台线程读 shell 输出喂给 vt100,屏幕在 Rust 里;回滚 5000 行;选区复制按页取历史 | 早期 |
| 1 | 终端画面只传变化的行(二进制) | ✅ | `codelite_pty_frame`:Rust 记着上一帧每行的指纹,只发变了的行,二进制(格式见 `encode_frame`),Dart `pty_frame.dart` 直接解码。编译日志刷屏时每帧 2.3 ms → 0.7 ms、占界面线程 5% → 1.7%(release 库实测,每帧平均只带 1 行)。旧库没有这个函数时自动退回 JSON 快照;选区复制翻页仍用 JSON 快照 | `3d40e46` |
| 2 | 全局搜索 / 替换 | ✅ | `codelite_search`(`code_lite_fs::project_search`):整文件一次匹配先挑出可能命中的文件,按路径排序分批并行(`rayon`),够数就停;Dart 在后台 isolate 里调(`rust_search.dart`),不卡界面。结果与 Dart 版逐条一致(列号是 UTF-16、按 `\r\n` / `\r` 分行、整词用 ASCII `\b`)。bcpoker_admin 实测 260 ms → 80 ms(约 3 倍)。Rust 不支持的正则(环视、反向引用)和没有 Rust 库时回到 Dart 那份。文件清单还没常驻,留给 #3 | `5de5df9` |
| 3 | 项目文件索引 + 按文件名快速打开(Go to File) | ✅ | `code_lite_fs::file_index`:每个项目一份文件清单常驻 Rust 上下文(只存相对路径字符串),第一次用时后台线程建,每次打开 Go to File 后台重扫;打字时 `nucleo-matcher` 模糊匹配(rayon 分块并行),无 `/` 只匹配文件名、有 `/` 匹配路径,同分路径短的在前,返回匹配字符的 UTF-16 下标供高亮。查询很快,界面线程直接调:4 千个文件 < 0.3 ms(含 `/` 的路径匹配约 3 ms),1.8 万个文件 < 1.4 ms;建清单 120~540 ms 在后台。界面 `goto_file_dialog.dart`,快捷键 ⇧⌘O(可配)。全局搜索仍自己遍历目录:它和文件清单的范围不同(搜索跳过所有点目录),遍历只占 80 ms 里的几 ms,不值得耦合 | `d963e3c` |
| 4 | 文件监视 | ✅ | `code_lite_fs::watcher`(`notify`,macOS 上 FSEvents),每个项目一个,随上下文释放。`target/`、`node_modules/`、`.git` 等目录和编辑器 / 保存用的临时文件在 Rust 里就丢掉;其余按路径攒着,界面每 300 ms 取一批(`codelite_watch_poll`),取时看磁盘分出改了 / 新建 / 删掉,并**就地更新 Go to File 的文件清单**(不重扫)。界面:改了的已打开文件和磁盘对一下,有新建 / 删除时文件树自动刷新(以前不会)。模拟一次编译(target/ 写 5000 个文件 + 改 10 个源文件):交给 Dart 的事件 10024 个 → 10 个。一次变太多(切大分支)时报 overflow,整体重来。Rust 不可用时退回 Dart 的监视 | `38faff9` |
| 5 | 差异对比(Commit / Merge / PR) | ✅ | `codelite_line_diff`(`code_lite_fs::line_diff`,`imara-diff` 的 histogram 算法 + 行级后处理):两边各拼成一段 `\n` 连起来的 UTF-8 加行数传过去,回来是各段改动的行号区间;Dart 的 `lineHunks` / `sideBySideDiff` 由它排出左右对齐的行(Commit、PR 的并排差异和三方合并共用),行的配对规则不变。原来 Dart 的 Myers 回溯时每步复制整个状态数组,改动一多就爆:2 万行改 2000 处 1 s / 2.4 GB、2 万行整体改写 24 s / 3.3 GB、5 万行整体改写 > 60 s,还都在界面线程上;现在这些都是 3~8 ms、多占几 MB(release 库实测),所以仍同步调用。没有 Rust 库时用 Dart 那份(`dartLineHunks`),测试里两份对照校验 | `258a969` |
| 6 | 语法解析(tree-sitter) | ⏸ 评估完,等决定 | **能编译**:25 种语言的语法包都在 crates.io,和 `tree-sitter` 0.25 的 ABI 兼容(要先联网下载进缓存,之后可离线)。**包会变大**:全装动态库 3.3 MB → 33 MB(Swift / C# 各约 5.5 MB,C++ / Kotlin / TypeScript 各约 3.5 MB,Java / JS / Python 各约 0.6 MB)。**高亮不会更快**,现在 Dart 的逐行分词已经更快:7 千行的 Java / Dart 文件全量 5 ms vs tree-sitter 25~31 ms,敲一个字 0.02 ms vs 0.5~4 ms,画一屏两边都约 0.13 ms;而且每次按键都要把改动同步给 Rust。**收益只在准确度和新功能**:按语法树区分方法调用 / 类型 / 字段 / 参数、代码折叠、没有语言服务器时更准的结构视图(现在退回正则大纲)。见下方「tree-sitter 评估」 | |

## tree-sitter 评估(2026-10-15)

测试文件:Metrics.java(7683 行 / 261 KB)、Flutter 的 editable_text.dart(6963 行 / 270 KB)。tree-sitter 用 release 构建,Dart 用 `flutter test`(JIT,AOT 只会更快)。

| | 全量 | 中间敲一个字 | 画可见 60 行 |
|---|---|---|---|
| Dart 逐行分词(现在) | 4.3~5 ms | 0.02 ms(只重算 1 行) | 0.14~0.25 ms |
| tree-sitter 解析 + 高亮查询 | 25~31 ms 解析 + 7~11 ms 编译查询 | 0.6~4 ms 增量重解析 | 0.13 ms |

结论:tree-sitter 换来的是「懂语法」而不是速度,值不值得取决于要不要折叠、更细的着色和不靠语言服务器的结构视图;要做的话只装常用语言能把体积压在 +5~8 MB。

## 不交给 Rust 的(及原因)

- **编辑器文本**:每次按键、每次刷新都要跨 FFI,只有几百 MB 的超大文件才划算。
- **Git 操作**:调用的 `git` 命令本身是 C 写的,已经很快;分支状态检查已经是直接读文件。
- **语言服务器通信**:问题在 JSON 解析放在界面线程,放到 Dart 后台 isolate 即可。
- **内存 / CPU 统计**:已经直接调系统接口(`proc_pid_rusage`)。
- **文件树扫描、Maven 解析、快捷键、内置 Web 服务器**:工作量太小(文件树实测 Dart 5 ms / Rust 3 ms)。

## 测性能的注意事项

- **测 Rust 一定要用 release 库**。`flutter test` 默认先找 `target/debug/libcodelite.dylib`,未优化的 Rust 慢 10~20 倍:
  终端那项最初测出「每帧 8.4 ms、占 16%」就是 debug 库的数字,release 库实际是 2.3 ms / 5%。
  测之前 `cargo build --release -p code-lite-ffi`,并临时把 debug 库挪开。

## 约定

- 导出函数用 `#[no_mangle] extern "C"`,每个都带项目上下文指针 `ctx`(每个项目一个,关项目时整体释放)。
- **谁分配谁释放**:Rust 返回的字符串 / 字节缓冲必须调 Rust 的释放函数(`codelite_string_free`、`codelite_bytes_free`)。
- 数据量大的(终端画面、搜索结果)用二进制或只传变化的部分,不整块转 JSON;耗时的(搜索)在 Rust 自己的线程里做,不同步卡界面线程。
- 依赖只能用本机离线缓存里有的 crate(`cargo --offline`)。

## 选型依据(2026-10-14 实测,bcpoker_admin:3966 个文件 / 27 MB)

| | 全局搜索 | 文件树扫描 | 峰值内存 |
|---|---|---|---|
| Dart(AOT,后台 isolate) | 240 ms | 5 ms | 在 App 自己的 VM 里 |
| Rust(同样算法) | 122 ms | 3 ms | 8 MB |
| C(系统 grep,单线程) | 290 ms | — | 1.8 MB |
| Rust(ripgrep 的做法:并行 + SIMD) | ~70 ms | — | — |

结论:同样算法 Rust 约快 2 倍,C 并不更快;决定速度的是算法(并行、SIMD、少做无用功)。
App 的内存大头不在我们的代码:Flutter 绘制约 300 MB、每个 Java 项目的 jdtls 约 576 MB,我们自己的数据约 23 MB。
