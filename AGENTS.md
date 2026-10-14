<claude-mem-context>
# Memory Context

# [code-lite-x] recent context, 9/8/2026 5:09pm GMT+8

No previous sessions found.
</claude-mem-context>

# CodeLiteX (Code Editor + Git Management IDE)

CodeLiteX 是一款高性能的原生跨平台代码编辑器，内置 Git 管理，并提供全局搜索与交互终端；LSP 与文件大纲（outline）在 Flutter 侧实现（`apps/code_lite_ui/lib/core/lsp/`）。
工作空间根目录 `/Users/dev/rust/code-lite-x/` 下包含 Rust Core 原生能力层与 Flutter 桌面端交互层：

| 模块 / 目录 | 角色 | 技术栈 | 交付产物 | 架构定位 |
| :--- | :--- | :--- | :--- | :--- |
| `crates/` | Rust Core 核心引擎 | Rust 2021 (portable-pty, vt100) | `libcodelite.dylib`, `code-lite-app` | PTY 终端(正逐模块迁到 Dart:Git、文件树、全局搜索、LSP、编辑器内核已迁完;无本地数据库) |
| `apps/code_lite_ui/` | 桌面端图形界面 | Flutter 3.47+ (Dart 3.13) + FFI;macOS 12+ | macOS / Linux / Windows 桌面 GUI | IntelliJ Darcula 风格编辑器、Git 操作台、全局搜索模态框、交互终端 |
| `scripts/` | 构建与原生打包 | Bash + cargo + flutter CLI + install_name_tool | `CodeLiteX.app` / `dist/release/macos/` | 自动化独立发布构建、动态库嵌入与 rpath/代码签名修复 |

> [!NOTE]
> - **Rust 负责哪些事**:见 `docs/rust-core.md`(清单 + 状态)。新增交给 Rust 的事项要先记进去,实现后更新状态。
> - **严格的 FFI 隔离**：Flutter UI 与 Rust Core 之间**仅通过 C-ABI FFI 动态链接库通信**。UI 层严禁直接引入 Rust 原生源码，统一通过 `ApiClient` → `CodeLiteBindings` 访问底层能力。

---

## 核心开发与工作准则

1. **代码搜索与架构梳理规范**：优先使用 **CodeGraph MCP 工具** 与 **Ripgrep (grep_search)**，避免漫无目的的盲目扫描与读文件循环。
   - `codegraph_explore` / `codegraph_search`：快速获取符号逐字源码与架构上下文（调用时附带 `projectPath: "/Users/dev/rust/code-lite-x"`）；
   - `codegraph_callers` / `codegraph_callees`：追踪上下游调用链路；
   - `codegraph_impact`：精准评估修改符号时的影响面（Blast Radius）；
   - 检索接口 URL、文本配置、i18n、样式或未建立索引的脚本统一使用 **Grep**。
2. **Rust 版本**：仓库根的 `rust-toolchain.toml` 固定编译器版本（当前 1.99.0），升级时改那里，再跑一遍下面的离线测试和打包。
3. **Rust Cargo 离线构建与测试铁律**：
   - 依赖已在本地 Cargo vendor / cache 完备锁定，所有 cargo 命令**必须显式增加 `--offline` 标志**并指定 PATH：
     ```bash
     export PATH="$HOME/.cargo/bin:$PATH" && cargo <cmd> --offline
     ```
   - 严禁擅自引入未经本地离线验证的重型外部 crate，保证工作区在断网环境下 100% 可编译、可运行、可测试。
4. **UI 视觉与防御性布局规范**：
   - 遵循 IntelliJ IDEA Darcula 工业级暗色主题规范（`IntelliJTheme`）；
   - 在任何嵌套 `Row` 或面板标题区域，文本标签**必须使用 `Expanded`/`Flexible` 包裹并设置 `overflow: TextOverflow.ellipsis`**，避免因屏幕缩放或视口收窄触发 RenderFlex 溢出；
   - 图标按钮优先使用轻量 `InkWell` 或 ShrinkWrap 约束，严禁出现默认 48px 强制触控区域挤占紧凑桌面布局。
5. **配置与敏感信息红线**：
   严禁将以下信息提交至 Git：
   - 第三方服务 API Key / Token
   - 私钥、证书与生产环境凭证
   - 旧版本遗留的本地数据库 `.codelite/*.db*` 及构建产物 `target/`, `dist/`

---

## 已确认的产品决策（改界面 / 交互前先看）

开发中拿不准、经用户确认过的做法。总原则：**交互和布局一律参考 IntelliJ IDEA（新 UI）**；和这里冲突时以这里为准；有新的确认就追加一条，别让同一个问题再问一遍。

**编辑器**
- 未被引用的变量 / 字段 / 导入：只把文字变灰。不加黄色下划线，悬停也不弹提示。
- 找不到定义的引用（未解析的变量 / 方法）：文字标红，不用红色波浪下划线。警告仍是波浪线。
- 编辑区最右边的错误条要窄：8px（原 12px 被嫌宽）。点错误条上的标记跳到那个问题（光标到出错的行和列并滚到可见），悬停显示手形光标和错误信息；点空白处滚到文件对应位置；重叠时错误优先于警告（同 IntelliJ）。
- 文件在别处被改了（别的编辑器、格式化工具、脚本、git）：已打开的标签自动跟上。没保存修改的直接换成磁盘内容（可 ⌘Z 撤回）；有没保存修改的不覆盖任何一边，编辑区上方出提示条让用户选「载入磁盘版本 / 保留我的修改」，选之前不自动保存。靠项目目录的文件监视 + 切回窗口 / 切换项目时再对一遍 + 每次保存前先看一眼磁盘（`EditorSessionManager.syncWithDisk`）。
- 每个项目都恢复上次的状态：打开的标签、光标、滚动位置。从文件树打开的标签存的是绝对路径，也要恢复。
- Markdown 有 Editor / Editor+Preview / Preview 三种模式。能接开源库就接开源库（现用 `flutter_markdown_plus` + `markdown`）；两栏同步滚动不能卡。
- HTML 文件：编辑器右上角列出本机装了的浏览器，点哪个就用哪个打开。打开方式同 IntelliJ：经内置服务器按 `http://localhost:63342/<项目名>/<相对路径>` 打开，不用 file://。**每个项目一个服务器**，第一次用时启动，项目关闭时随之关闭（`ProjectContext.browserUrlFor`、`core/platform/web_server_native.dart`）；63342 被占了（别的项目或 IntelliJ）就往后找空端口；只听本机、只认 Host 为 localhost 的请求。

**整体外观（分支 `feat/islands-ui`）**
- 完整复刻 IntelliJ 新 UI 的「Islands Dark」：标题栏、活动条、状态栏和岛之间的缝是窗口底色 `#24282C`；编辑区、侧边工具窗、底部工具窗是一块块 8px 圆角的岛 `#181A1C`，岛之间留 5px 缝（缝就是拖动调整大小的地方）。颜色是从用户给的 IntelliJ 截图逐像素取的，见 `IntelliJTheme` / `IntelliJMetrics`、`core/theme/island.dart`。
- 标题栏：左边红绿灯、项目、分支，左侧带项目颜色的光晕；右边 Current File ▾、运行、调试、⋮，再隔开是搜索和设置。没有搜索框、没有文件路径、没有撤销 / 重做按钮（⌘Z 照常）。
- 编辑器标签是圆角块，选中的是蓝灰底 `#25334E`，没有下划线；× 只在选中或悬停时出现。活动条选中的按钮是实心灰色圆角块。代码区默认配色 Islands Dark（Markdown 标题是粉色 `#C77DBB`）。

**工具窗与布局**
- 工具窗标题栏只放 ⋮（移动到 / 隐藏）和 —；不要单独的「拆分」按钮。
- 侧边工具窗可以放在左侧或右侧，每侧分上 / 下两块。
- 右侧栏始终显示，顶上是通知，下面是停靠在右侧的工具窗按钮；展开时面板在编辑区和右侧栏之间。
- 右侧面板和编辑区之间的分隔线要细，参考左侧，不要夹一条宽带。
- 构建工具窗参考 IntelliJ 的 Maven 窗口：模块树 → Lifecycle / Plugins / Dependencies → 任务，双击运行。新的构建工具通过插件清单（`buildTools`）扩展。
- 插件市场暂时不做。

**文件树**
- 快速搜索（IntelliJ 的 speed search）：**只在文件树有焦点时生效**（点一下文件树）。直接打字在已展开的节点里找，选中跳到第一个匹配（从当前选中往下找，到底回到顶上），匹配字符高亮，顶上浮一个搜索框（没匹配时红字）；↑↓ 在匹配间跳，回车打开文件 / 展开目录，Backspace 删字，Esc 或失去焦点退出。匹配不分大小写，先找连续出现，否则分段匹配、每段从词首开始（`admser` → admin-service，`stmgc` → SeaTunnelMigrationGroupController）。不搜时 ↑↓ 移动选中，→ 展开 / ← 收起或回到上一级，回车打开。

**Go to File**
- ⇧⌘O（其它平台 Ctrl+Shift+N，可在 Keymap 里改）弹出 IntelliJ 式的按文件名查找：文件清单常驻 Rust，打字实时模糊匹配；没有 `/` 只匹配文件名，有 `/` 匹配路径；`Foo.java:120:5` 打开后跳到那一行那一列；没输入时列出打开着的标签；↑↓ 选，回车打开，Esc 关。不收 `.git`、`node_modules`、`target`、`build`、`.dart_tool`、`.gradle`、`.idea`、`out` 下的文件（`.github` 这类点目录照收，同 IntelliJ）。

**项目**
- 一个进程同时打开多个项目，都留在内存里，切换只是换显示哪一个。「Opening Projects」列表里点 × 才真正关闭，关闭时有未保存的修改要问。
- 标题栏的项目下拉：直接打字就开始搜索、过滤项目（IntelliJ 的做法）。

**Git**
- merge / rebase 有冲突时，标题栏出现两个按钮：一个弹出冲突文件列表，一个 × 中止这次合并。
- 解决冲突用三栏 Merge 窗口（标题叫「Merge」，不叫「Open File」），中间的结果栏可以直接编辑。

**快捷键**
- 快捷键可配置，默认键位同 IntelliJ（macOS「Mac OS X 10.5+」；其它平台「Default」），存储格式和 action id 也用 IntelliJ 的（`meta 1`、`ActivateProjectToolWindow`），所以能直接「从 IntelliJ 导入」：读最新 `IntelliJIdea*` 配置目录的 `options/mac/keymap.xml`（当前配置名）+ `keymaps/*.xml`（用户改的）+ 安装包 `lib/app.jar` 里的自带配置，沿 parent 链解析；macOS 键位继承 `$default` 时 Ctrl 换成 ⌘（IntelliJ 自己也这么换）。设置 ▸ Keymap 可加（按下组合键录入，冲突的从原操作移走）、删、恢复默认。设置文件只存改过的（`keymap.overrides`）。
- 第一批是打开 / 收起工具窗：⌘1 项目、⌘0 Commit、⌘7 结构、⌘9 Git、⌥F12 终端、⇧⌘F12 隐藏 / 恢复所有工具窗；PR、Opening Projects、Maven 默认无快捷键。再按一次同一个键收起（同 IntelliJ）。活动条按钮的提示跟着显示当前快捷键（`core/keymap/`、`features/settings/keymap_page.dart`）。

**窗口**
- macOS 左上角是真的关闭 / 最小化 / 缩放按钮（系统红绿灯），不要弹窗。

**待确认（先按猜测做了，用户还没明确表态）**
- 底部工具窗现在横跨左右两条活动条之间的整个宽度，左侧的项目面板也因此停在终端上方，不再是从上到底的整列（照 IntelliJ 截图做的）。用户如果想要左侧整列，就做成选项。
- 构建工具窗（Maven）的默认位置：最初用户选的是「左侧竖条」，后来参考 IntelliJ 截图改成了默认在右侧。已经存过布局的用户按存的来。

---

## 常用命令速查

### 全栈一键命令（根目录 `/Users/dev/rust/code-lite-x/`）
```bash
# 1. 执行 Rust 全工作区离线单元测试与集成测试 (必须 0 failed)
export PATH="$HOME/.cargo/bin:$PATH" && cargo test --offline --workspace

# 2. 编译 Rust Core C-ABI 动态链接库 (Debug 用于开发与 FFI 联调)
export PATH="$HOME/.cargo/bin:$PATH" && cargo build --offline -p code-lite-ffi

# 3. 运行 Flutter 客户端全套自动化测试 (必须 0 failed)
cd apps/code_lite_ui && /Users/dev/development/flutter/bin/flutter test

# 4. 一键打包 macOS 原生独立分发产物 (自动构建 Release 动态库与 Daemon 并收集至 dist/)
bash scripts/build_macos_release.sh
```

### Rust Core 独立子模块调试（`crates/`）
```bash
# 针对特定 crate 运行测试
cargo test --offline -p code-lite-core       # 仅守护进程使用的文本缓冲(App 编辑器已是纯 Dart)
cargo test --offline -p code-lite-fs         # 工作区扫描/搜索(仅守护进程使用,App 已改用 Dart 实现)
cargo test --offline -p code-lite-terminal   # PTY 交互终端会话
cargo test --offline -p code-lite-ffi        # C-ABI 导出(终端)

# 编译独立后台守护进程
cargo build --release --offline -p code-lite-app
```

### Flutter 桌面客户端（`apps/code_lite_ui/`）
```bash
# 本地热重载运行桌面版 (需宿主完整安装 Xcode / Desktop 支持)
/Users/dev/development/flutter/bin/flutter run -d macos

# 静态代码分析与机械性修复
/Users/dev/development/flutter/bin/flutter analyze
```

---

## 前端架构规范 (`apps/code_lite_ui/`)

### 目录分层结构
* `lib/core/ffi/`：底层动态链接库封装（`codelite_bindings.dart`），负责指针内存安全编解码（`_toCString` / `_fromCString`）；
* `lib/core/fs/`：纯 Dart 工作区文件树扫描与全局搜索/替换（`workspace_fs.dart`），在后台 Isolate 中执行；
* `lib/core/git/`：纯 Dart Git 引擎（`git_service.dart`），通过 `Process.run` 调用系统 `git` 命令行；Git 不再经过 Rust FFI；
* `lib/core/github/`：GitHub Pull Request 服务（`github_service.dart`），经本机 `gh` 命令行（`gh pr` / `gh api`）读写 PR、评审与评论，应用不保存 token；
* `lib/core/plugins/`：插件框架（声明式 `plugin.json` + 独立进程）。`plugin_manifest.dart` 定义清单格式（语言、着色规则、语言服务器、构建工具 `buildTools`、安装步骤；`bundled: true` 为随 IDE 自带、默认启用、只能停用不能卸载），`builtin_catalog.dart` 是随 IDE 打包的插件目录（以后由插件市场提供同格式索引），`plugin_host_io.dart` 负责下载解压 / 运行安装命令 / 展开变量（装到 `~/.codelitex/plugins/<id>`，走系统代理），`plugin_manager.dart` 管理安装状态、新语言提示，并把语言服务器启动方式交给 LSP；
* `lib/core/state/`：应用状态。**一个进程可同时打开多个项目**：`project_manager.dart`（`ProjectManager`）管打开列表 / 当前项目 / 关闭，列表存 `~/.codelitex/open_projects.json`，启动只加载当前项目，其余首次切到时才加载；`project_context.dart`（`ProjectContext`）是**每个项目一份**的状态包（自己的 `ApiClient`——含独立的 Rust 终端上下文、语言服务器、Git——以及编辑会话、工作区、终端、Git 日志、分支、PR、构建工具窗）。切换项目只是换显示哪一份，其它项目留在内存里照常运行，关闭才释放。窗口布局、设置、插件、编辑器外观是全局共享的。新写的异步 store 要混入 `DisposeSafeNotifier`（`dispose_safe.dart`），因为项目随时可能被关闭；
* `lib/core/lsp/`：Dart 实现的 LSP 客户端与文件大纲（outline）；Rust 侧不再有 LSP / 代码图谱；
* `lib/core/build_tools/`：构建工具的模块树与命令拼装（`build_model.dart`）。插件清单的 `buildTools.model` 按名字选 IDE 内置读取器（目前 `maven`：`maven_reader.dart` 读 pom.xml 的 `<modules>`，`xml_lite.dart` 是不依赖外部包的极简 XML 解析）；
* `lib/core/client/`：高层业务客户端（`api_client.dart`），封装异步 Future/Stream，并在 FFI 动态库未加载时无缝回退至离线 Mock 逻辑；
* `lib/core/theme/`：全局主题与样式（`intellij_theme.dart`），锁定 JetBrains Darcula 经典配比；
* `lib/features/editor/`：代码编辑器区域（纯 Dart：文本、撤销/重做历史、语法高亮、文件读写）；
* `lib/features/editor/syntax/`：语法引擎。`languages.dart` 是各语言的声明式定义（关键字、注释、字符串、注解……），`LanguageRegistry` 按扩展名 / 文件名 / `#!` 识别语言；`tokenizer.dart` 逐行分词并携带跨行状态；`DocumentHighlighter` 只重算改动行。新增语言＝加一份 `LanguageSpec`；
* `lib/features/tree/`：左侧工作区文件树（`project_explorer.dart`）；
* `lib/features/bottom_tools/`：底部工具箱（`bottom_tools_widget.dart`），整合真实 Git 分支控制台与交互终端；
* `lib/features/pull_requests/`：左侧 Pull Requests 工具窗（列表/筛选/详情）、PR 并排差异标签（行内评审评论、右键菜单）与 Timeline 标签；
* `lib/features/build_tools/`：左侧构建工具窗（Maven 等）。项目根有插件声明的标记文件（pom.xml）时活动条才出现按钮；模块树 → Lifecycle → 任务，双击在新终端标签里运行（有 mvnw 用 `./mvnw`，子模块带 `-f`）；
* `lib/features/tool_window/`：侧边工具窗的位置与标题栏。`LayoutStore` 里每个 `SideTool`（项目 / Commit / PR / 结构 / Opening Projects / 构建）可以放在左侧或右侧（`ToolSide`），每侧再分上 / 下两块（`ToolSlot`），上下都开着时拆分显示（`side_split_view.dart`）；标题栏 ⋮ ▸ 移动到 ▸ 四个位置。右活动条（`RightStripeWidget`）始终显示，顶上是通知，下面是停靠在右侧的工具窗；构建工具窗（Maven）默认在右侧（同 IntelliJ）。底部工具窗横跨两条活动条之间的整个宽度，左右工具窗停在它上面。位置存在设置文件的 `layout` 里；
* `lib/features/projects/`：左侧「Opening Projects」工具窗（打开的项目列表，点击切换，× 真正关闭）；
* `lib/features/search/`：全局搜索模态框（`global_search_modal.dart`，支持 `Cmd+Shift+F` 快速唤起）。

### 状态流转与交互规范
1. **统一门面**：界面所有数据请求统一经由 `ApiClient` 发起，严禁在 Widget 内直接执行 raw `DynamicLibrary` 指针操作；
2. **防溢出与自适应**：在多列布局（如 Git 控制面板）中，固定侧边栏宽度并对中央可伸缩区域采用 `Expanded`，标题与路径行始终配置 `overflow: TextOverflow.ellipsis`。

---

## Rust Core 后端架构规范 (`crates/`)

### Crates 职责划分

```
crates/
 ├── code-lite-core      # 文本缓冲(仅守护进程使用;App 的编辑器内核已迁到 Dart)
 ├── code-lite-fs        # 工作区扫描/搜索,仅供守护进程使用,随守护进程一起退役
 ├── code-lite-terminal  # PTY 交互终端会话管理
 ├── code-lite-ffi       # C-ABI 动态链接导出层(终端)
 └── code-lite-app       # 原生轻量化独立后台守护进程 (Daemon)
```

### 关键架构机制
1. **内存管理规范 (`code-lite-ffi`)**：
   - 跨语言字符串严格遵循「Rust 分配、Rust 释放」原则；
   - 导出 `codelite_string_alloc` 与 `codelite_buffer_free`，禁止跨 FFI 边界由 Dart 侧释放 Rust 裸指针。

---

## 验证与发布规范

1. **提交前自动化验证**：
   - Rust 校验：运行 `cargo test --offline --workspace`，必须 **0 failed**；
   - Flutter 校验：运行 `flutter test`，必须 **0 failed**；
   - **不要在本文档写死测试数量。** 数量随功能增长而变,写死必然过期(曾写 66/19,实际已到 99/35),一律以本次运行的实际结果为准。
2. **发布打包验收**：
   - 运行 `bash scripts/build_macos_release.sh`；
   - 检查 `dist/release/macos/` 下包含优化后的 `libcodelite.dylib` 与 `code-lite-app`，并在具备完整 Xcode 环境的主机上验证独立应用 `CodeLiteX.app` 的正常拉起。
3. **功能点自动 Git 提交准则**：
   - 每一个功能点 / 演进子阶段（例如 Phase 8.1, Phase 8.2 等）改完并通过全部测试（Rust + Flutter 全绿）后，必须**自动执行 Git 提交**；
   - 提交信息遵循 Conventional Commits 规范（如 `feat(phase-8.1): lsp process supervisor & incremental did_change`），清晰记录里程碑。
4. **CodeGraph 知识图谱自动同步准则**：
   - 每次代码改动与验证完成后，必须立即同步 CodeGraph 代码索引：
     ```bash
     /Users/dev/.nvm/versions/node/v24.15.0/bin/codegraph sync /Users/dev/rust/code-lite-x
     ```
   - 并在 MCP 中确认图谱状态（`codegraph_status`），确保后续代码理解、符号跳转与调用链始终处于最新、最准确的 AST 状态。
