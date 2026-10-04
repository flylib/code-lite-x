<claude-mem-context>
# Memory Context

# [code-lite-x] recent context, 9/8/2026 5:09pm GMT+8

No previous sessions found.
</claude-mem-context>

# CodeLiteX (Code Editor + Git Management IDE)

CodeLiteX 是一款高性能的原生跨平台代码编辑器，内置 Git 管理，并提供全局搜索、交互终端与自动更新能力；LSP 与文件大纲（outline）在 Flutter 侧实现（`apps/code_lite_ui/lib/core/lsp/`）。
工作空间根目录 `/Users/dev/rust/code-lite-x/` 下包含 Rust Core 原生能力层与 Flutter 桌面端交互层：

| 模块 / 目录 | 角色 | 技术栈 | 交付产物 | 架构定位 |
| :--- | :--- | :--- | :--- | :--- |
| `crates/` | Rust Core 核心引擎 | Rust 2021 (Ropey, Parking Lot, portable-pty) | `libcodelite.dylib` (7.0M), `code-lite-app` (2.9M) | 视口虚拟化、PTY 终端、自动更新(正逐模块迁到 Dart:Git、文件树、全局搜索、LSP 已迁完;无本地数据库) |
| `apps/code_lite_ui/` | 桌面端图形界面 | Flutter 3.35+ (Dart 3.9) + FFI | macOS / Linux / Windows 桌面 GUI | IntelliJ Darcula 风格编辑器、Git 操作台、全局搜索模态框、交互终端 |
| `scripts/` | 构建与原生打包 | Bash + cargo + flutter CLI + install_name_tool | `CodeLiteX.app` / `dist/release/macos/` | 自动化独立发布构建、动态库嵌入与 rpath/代码签名修复 |

> [!NOTE]
> - **严格的 FFI 隔离**：Flutter UI 与 Rust Core 之间**仅通过 C-ABI FFI 动态链接库通信**。UI 层严禁直接引入 Rust 原生源码，统一通过 `ApiClient` → `CodeLiteBindings` 访问底层能力。

---

## 核心开发与工作准则

1. **代码搜索与架构梳理规范**：优先使用 **CodeGraph MCP 工具** 与 **Ripgrep (grep_search)**，避免漫无目的的盲目扫描与读文件循环。
   - `codegraph_explore` / `codegraph_search`：快速获取符号逐字源码与架构上下文（调用时附带 `projectPath: "/Users/dev/rust/code-lite-x"`）；
   - `codegraph_callers` / `codegraph_callees`：追踪上下游调用链路；
   - `codegraph_impact`：精准评估修改符号时的影响面（Blast Radius）；
   - 检索接口 URL、文本配置、i18n、样式或未建立索引的脚本统一使用 **Grep**。
2. **Rust Cargo 离线构建与测试铁律**：
   - 依赖已在本地 Cargo vendor / cache 完备锁定，所有 cargo 命令**必须显式增加 `--offline` 标志**并指定 PATH：
     ```bash
     export PATH="$HOME/.cargo/bin:$PATH" && cargo <cmd> --offline
     ```
   - 严禁擅自引入未经本地离线验证的重型外部 crate，保证工作区在断网环境下 100% 可编译、可运行、可测试。
3. **UI 视觉与防御性布局规范**：
   - 遵循 IntelliJ IDEA Darcula 工业级暗色主题规范（`IntelliJTheme`）；
   - 在任何嵌套 `Row` 或面板标题区域，文本标签**必须使用 `Expanded`/`Flexible` 包裹并设置 `overflow: TextOverflow.ellipsis`**，避免因屏幕缩放或视口收窄触发 RenderFlex 溢出；
   - 图标按钮优先使用轻量 `InkWell` 或 ShrinkWrap 约束，严禁出现默认 48px 强制触控区域挤占紧凑桌面布局。
4. **配置与敏感信息红线**：
   严禁将以下信息提交至 Git：
   - 第三方服务 API Key / Token
   - 私钥、证书与生产环境凭证
   - 旧版本遗留的本地数据库 `.codelite/*.db*` 及构建产物 `target/`, `dist/`

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
cargo test --offline -p code-lite-core       # 视口虚拟化 Tokenizer、Buffer、Cursor
cargo test --offline -p code-lite-fs         # 自动更新(tree/search 仅剩守护进程在用,App 已改用 Dart 实现)
cargo test --offline -p code-lite-rpc        # 共享 JSON-RPC 2.0 协议、Framing、Correlation
cargo test --offline -p code-lite-terminal   # PTY 交互终端会话
cargo test --offline -p code-lite-ffi        # C-ABI 导出、JSON-RPC 路由与集成测试

# 运行 IDL 契约代码生成器
cargo run -p xtask --offline -- codegen

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
* `lib/core/lsp/`：Dart 实现的 LSP 客户端与文件大纲（outline）；Rust 侧不再有 LSP / 代码图谱；
* `lib/core/client/`：高层业务客户端（`api_client.dart`），封装异步 Future/Stream，并在 FFI 动态库未加载时无缝回退至离线 Mock 逻辑；
* `lib/core/theme/`：全局主题与样式（`intellij_theme.dart`），锁定 JetBrains Darcula 经典配比；
* `lib/features/editor/`：代码编辑器区域，集成百万行视口虚拟化语法 Token 渲染与多光标编辑；
* `lib/features/tree/`：左侧工作区文件树（`project_explorer.dart`）；
* `lib/features/bottom_tools/`：底部工具箱（`bottom_tools_widget.dart`），整合真实 Git 分支控制台与交互终端；
* `lib/features/search/`：全局搜索模态框（`global_search_modal.dart`，支持 `Cmd+Shift+F` 快速唤起）。

### 状态流转与交互规范
1. **统一门面**：界面所有数据请求统一经由 `ApiClient` 发起，严禁在 Widget 内直接执行 raw `DynamicLibrary` 指针操作；
2. **防溢出与自适应**：在多列布局（如 Git 控制面板）中，固定侧边栏宽度并对中央可伸缩区域采用 `Expanded`，标题与路径行始终配置 `overflow: TextOverflow.ellipsis`。

---

## Rust Core 后端架构规范 (`crates/`)

### Crates 职责划分

```
crates/
 ├── code-lite-core      # 编辑器基础数据结构：Piece Table / Buffer、Cursor、视口行 Tokenizer
 ├── code-lite-rpc       # 共享 JSON-RPC 2.0 传输层：协议模型、Framing 与 Request 关联
 ├── code-lite-fs        # 自动更新;工作区扫描/搜索仅供守护进程使用,随守护进程一起退役
 ├── code-lite-terminal  # PTY 交互终端会话管理
 ├── code-lite-ffi       # C-ABI 动态链接导出层、JSON-RPC 派发表与 handlers 业务处理器
 ├── xtask               # IDL 契约驱动的代码生成器 (core_api.toml -> Rust dispatch & Dart client)
 └── code-lite-app       # 原生轻量化独立后台守护进程 (Daemon)
```

### 关键架构机制
1. **视口虚拟化高亮 Token 流 (`code-lite-core::syntax`)**：
   无需全文件语法解析，根据当前展示行号区间 `[start_line, end_line]`，流式生成词法分类 Token（Keyword, Type, Function, String, Comment 等），保证百万行代码 120 FPS 渲染。
2. **内存管理规范 (`code-lite-ffi`)**：
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
