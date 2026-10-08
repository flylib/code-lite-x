# CodeLiteX Rust 重写计划

## 目标

以 [Lapce](https://github.com/lapce/lapce) 为 Rust 桌面编辑器底座，在 `rust` 分支上逐步迁入或重做 CodeLiteX 的现有功能，最终形成不依赖 Flutter/Dart 的原生 Rust 桌面应用。

采用 Lapce 稳定版 `v0.4.6` 作为首选基线。该版本使用 Rust 2024 edition，声明的最低 Rust 版本为 1.87；当前评估环境的 Rust 版本为 1.95。Lapce 提供 Floem 桌面 UI、编辑器、LSP、终端、远程开发和 WASI 插件能力。接入和分发时保留 Apache-2.0 许可证、上游版权与来源信息，并遵守修改文件标注等许可条件。

## 分阶段路线

### 阶段 0：锁定基线与构建条件

- 获取 Lapce `v0.4.6` 完整源码并记录上游提交号。
- 清点许可证、版权声明、NOTICE（如存在）、资源和构建脚本。
- 检查 Rust/Cargo 版本、目标平台要求、Cargo registry 与 Git 依赖缓存。
- 严格遵守仓库离线规则，只运行带 `--offline` 的 Cargo 命令；确认依赖已缓存后再执行构建。
- 记录离线构建结果、缺失依赖和可复现步骤。未满足离线依赖条件时，不擅自联网下载 crate 或引入新依赖。

**验收条件：** 基线版本和来源可追溯；许可证清单完成；Rust 工具链兼容；离线依赖完整；Lapce 桌面程序离线构建成功。

### 阶段 1：Rust 桌面基线

- 将锁定的 Lapce 源码纳入 `rust` 分支，保留上游历史/来源记录。
- 构建并启动原生桌面应用，检查窗口、工作区、编辑、LSP 和终端。
- 确定 CodeLiteX 品牌和 Darcula 风格的改造位置。

**验收条件：** 本机可离线构建并启动 Rust 桌面编辑器，核心编辑工作流可用。

### 阶段 2：CodeLiteX 产品基础

- 调整应用名称、图标、主题、配置目录和发行标识。
- 建立 CodeLiteX 扩展模块边界，控制对 Lapce 上游核心的改动范围。

**验收条件：** 品牌化应用稳定运行，核心功能保持可用。

### 阶段 3：工作区与编辑器功能

- 迁入文件树、文件打开和保存、全局搜索及 CodeLiteX 特有编辑器行为。
- 优先扩展 Lapce 已有编辑器、LSP 和终端能力，避免平行实现。

**验收条件：** Rust 版覆盖日常工作区与编辑工作流，并完成对应回归检查。

### 阶段 4：Git 工作流

- 迁入 Git 状态、分支、暂存、提交、差异查看、日志及相关操作。
- 对照旧版操作行为与现有测试逐项验收。

**验收条件：** Rust 原生 Git 工作流覆盖主要状态查看、提交和差异操作。

### 阶段 5：协作与扩展

- 迁入 GitHub Pull Request 列表、详情、评论和评审流程。
- 迁入插件管理、设置及剩余 CodeLiteX 专属功能。

**验收条件：** PR、插件、设置及其余纳入范围的功能均可在 Rust 版使用。

### 阶段 6：Flutter 退役与发布

- 对照完整功能清单进行覆盖验收。
- 移除 Flutter/Dart 前端、旧 FFI 和过期构建链路。
- 完善目标平台的 Rust 应用打包、安装和发布流程。

**验收条件：** 应用运行不再依赖 Flutter/Dart，目标平台发布流程可复现。

## 阶段推进规则

- 按阶段顺序推进；每阶段完成后汇报交付物、验证结果和剩余问题，再进入下一阶段。
- Cargo 命令必须显式使用 `--offline` 并配置 `$HOME/.cargo/bin` 到 PATH。
- 每个阶段的改动、验证、提交及 CodeGraph 同步遵循仓库 `AGENTS.md` 要求。
- 不将 API Key、Token、私钥、证书、本地数据库或构建产物纳入 Git。

## 当前状态

- 当前分支：`rust`。
- **阶段 0 已完成**：基线版本、依赖来源和离线编译条件已经确认。
- **阶段 1 已完成**（2026-10-08）：Lapce 桌面编辑器 GUI 可视验收与核心工作流检查通过。
- **阶段 2 已完成**（2026-10-08）：CodeLiteX 产品基础完成（名称、图标、主题、配置目录与扩展模块边界）。
- **阶段 3 已完成**（2026-10-08）：工作区与编辑器功能完成（Java 包压平、快捷键对齐、测试全绿）。2026-10-08 复核时发现包压平原先只改了目录标签、并未合并树结构，且会把路径里带 `java` 的整个项目误判为源码根，已重做（见「阶段 3 复核修正」）。
- **阶段 4 部分完成**（2026-10-08 复核）：状态 / 分支 / 暂存 / 提交 / 差异行高亮由上游 Lapce 的源代码管理面板提供，可用；**Git 历史面板已做**（见「Git 历史面板」）；stash、blame、文件历史、逐块还原、书签等旧版功能仍未迁入。
- 阶段 5（协作与扩展）待开始，建议先决定阶段 4 的缺口怎么处理。

### 阶段 0 详情

- Rust 版本 1.95.0，满足 Lapce `v0.4.6` 声明的 MSRV。
- Lapce `v0.4.6` 上游提交 `b012cef466741528f338879fa708355217fc40bd`。
- `Cargo.lock` 的 13 个 Git 源按锁定 revision 获取，逐一核对提交号。
- 723 个 registry 包版本均按 `Cargo.lock` SHA-256 校验。
- 13 个 Git 仓库锁定源码快照放入 `apps/rust_editor/vendor/lapce-git/`，24 个 Git 包改为项目内相对路径 patch。
- `cargo build --offline --locked` 成功（Rust 1.95.0，dev profile）。

### 阶段 1 详情

- Lapce 集成到 `apps/rust_editor/` 独立 Cargo工作区。
- `cargo build --offline --locked` 与 `cargo run --offline --locked` 均成功。
- GUI 可视验收（通过 CGWindowListCreateImage 截图确认）：
  - ✅ 窗口正常渲染：标题栏、红黄绿信号灯、"Open Folder" 命令面板。
  - ✅ 文件编辑器：打开 `README.md`，行号显示、HTML 语法高亮（标签绿色/属性黄色/文本白色）正常。
  - ✅ 面包屑导航：完整路径 `Volumes > space > projects > ... > README.md`。
  - ✅ 标签页系统：文件标签显示与关闭功能。
  - ✅ 文件浏览器（File Explorer）：Open Editors 与 File Explorer 面板。
  - ✅ 集成终端：底部 zsh 终端已启动，prompt 可交互。
  - ✅ 侧边功能栏：文件树、搜索、版本控制、调试、插件、远程连接图标。
  - ✅ 插件面板：显示可用插件列表（TypeScript、Python、C/C++ clangd 等）。
  - ✅ 状态栏：`Ln 1, Col 1, Char 0 · LF · Markdown`；零错误 `⊘ 0 ⚠ 0`。
- `apps/rust_editor/README_CODELITEX.md` 记录独立工作区构建方式。
- 原有 Flutter 应用和根 Cargo 工作区未改动。

### 阶段 2 详情

- **应用名称与标识**：
  - 二进制名称：生成独立 `codelitex` (224MB) 和 `codelitex-proxy` (89MB)，同时保留 `lapce` 兼容别名。
  - 窗口标题：正式显示 `CodeLiteX` 以及 `<workspace> - CodeLiteX`。
  - CLI 与版本：`codelitex -V` 输出 `CodeLiteX 0.4.6+Debug.84f5d7b`。
  - 关于窗口（About Popup）：主标题 `CodeLiteX`，仓库链接指向 `flylib/code-lite-x`，保留 Lapce (Apache-2.0) 与 Codicons (CC-BY-4.0) 明确署名。
  - 应用菜单：macOS 菜单更新为 `CodeLiteX`、`About CodeLiteX`、`Quit CodeLiteX`、`Hide CodeLiteX`。
  - 命令行集成：`Install CodeLiteX to PATH` 创建 `/usr/local/bin/codelitex`。
- **应用图标与资源**：
  - 生成 `codelitex.icns`（859KB，全尺寸 16-1024 视网膜清晰度）并部署至 `CodeLiteX.app` / `Lapce.app`。
  - 生成 CodeLiteX 矢量徽标 SVG 与高分辨率 PNG 资源并嵌入构建。
- **IntelliJ Darcula 配色主题**：
  - 默认暗色主题全面对齐 IntelliJ Darcula（`#1E1F22` 编辑器底色、`#2B2D30` 面板底色、`#393B40` 边框、`#3574F0` 激活蓝、关键字 `#CF8E6D`、字符串 `#6AAB73`、注释 `#7A7E85`）。
- **配置与数据目录**：
  - 数据与配置路径更新为 `ProjectDirs::from("com", "codelite", "CodeLiteX-<branch>")`。
  - 便携模式目录更新为 `codelitex-data`。
- **扩展模块边界**：
  - 创建独立模块 `lapce-app/src/codelitex/`，封装品牌常量、组织标识与扩展契约，严格隔离对上游核心侵入。
- **构建与测试验证**：
  - `cargo build --offline` 成功，离线 0 外部网络请求。
  - 进程启动与 macOS 窗口渲染确认（截图已归档），IPC Socket 通信打开文件正常。
  - Rust 根工作区、lapce-core、lapce-rpc 测试 100% 通过（0 failed）。
  - Flutter 端全套自动化测试 100% 通过（0 failed）。

### 阶段 3 详情

- **文件树与包链压平（Package Compaction）**：
  - 在 `apps/rust_editor/lapce-app/src/codelitex/project_tree.rs` 中实现 IntelliJ 风格的 Java/Kotlin 单子链压平算法 (`compact_package_name` / `file_node_display_name`)。
  - 源码根目录（`src/main/java` 等）下的连续单子目录折叠为 `com.bcpoker.game` 形式展示。
  - 接入 `lapce-app/src/file_explorer/view.rs` 树节点标签渲染。
- **macOS 常用快捷键补充**：
  - `defaults/keymaps-macos.toml` 中配置 `Cmd+1` 快速聚焦文件树 (`toggle_file_explorer_focus`)。
  - 补充 `Cmd+Shift+S` 与 `Cmd+Alt+S` 保存全部 (`save_all`)。
- **测试与离线环境适配**：
  - 修正 `lapce-app/src/config/color_theme.rs` 中的主题测试断言，匹配 Darcula 警告色 `#E5A84B`。
  - 排除未引用的 benchmark `criterion` 外部依赖以满足全套测试离线零网络执行。
  - `codelitex::project_tree` 单测覆盖源码目录判断与非目录降级。
  - 全套测试通过：Rust 根工作区 20 项、`lapce-app` 20 项、`lapce-core` 7 项、`lapce-rpc` 3 项测试 100% 通过（0 failed）。
  - Flutter 测试 205 项全绿（0 failed）。
- **GUI 可视验收（截图归档）**：
  - ✅ 工作区目录树正常打开并显示目录结构（`codelitex_phase3_workspace.png`）。
  - ✅ Java 文件打开、语法高亮、路径面包屑、状态栏语言指示正常（`codelitex_phase3_verified.png`）。
  - ✅ 内置终端 zsh 保持工作区上下文。

### 阶段 3 复核修正（2026-10-08）

- 原实现把 `com`、`bcpoker`、`game` 三个节点各自的标签都改成 `com.bcpoker.game`，树里仍是三层；每次渲染还在标签闭包里 `read_dir`；`is_in_source_root` 检查整条绝对路径，`/Users/dev/Worker/java/<项目>/…` 下所有目录都会被当成源码根。
- 现在压平放在行模型里：`lapce-rpc/src/package_chain.rs` 判定源码根（严格匹配 `src/<main|test|…>/java|kotlin|scala|groovy`）；`FileNodeItem` 把单子目录链合并为一行，行路径取最深目录，`children_open_count`、`append_view_slice`、`find_file_at_line` 同步按合并后的行计数。工作区根目录不压平。
- 读取目录时预读链上的子目录（`package_dirs_to_preread`），渲染里不再有磁盘 IO；用户刚展开的目录在链延长后保持展开。
- 验证：`lapce-rpc` 单测覆盖折叠、计数、窗口切片、分叉、单文件、`java` 目录下的项目、根目录、重命名/新建行、预读；用真实项目 `bcpoker_game_server/table-api` 跑了读取 + 预读 + 行生成，五层链折成一行 `com.bcpoker.table.api.feign`，展开后为其两个文件，行数一致。窗口截图因当前会话没有屏幕录制权限未能做，界面渲染仍待在本机目视确认。
- 旧的 `codelitex/project_tree.rs` 已删除。

### 阶段 4 详情（2026-10-08 复核后的实际状态）

- 文件树着色、状态栏分支、行号栏差异条、`Cmd+Shift+G` 等能力来自上游 Lapce，本阶段提交只新增了 `codelitex/git.rs` 与快捷键映射；`git.rs` 目前没有调用方。
- 与旧版 Flutter 的差距（尚未迁入）：stash、blame、文件历史、逐块「>>」还原、书签；历史面板里的提交图、按作者/日期/路径过滤、提交右键操作、点击变更文件看差异。

- **原生 Git 核心操作层（`codelitex::git`）**：
  - 在 `apps/rust_editor/lapce-app/src/codelitex/git.rs` 实现原生 Git 抽象能力：
    - `get_repo_status`：仓库状态查询、当前分支检测、暂存/未暂存文件变更汇总。
    - `get_branches`：全分支枚举与 HEAD 标记识别。
    - `get_commit_history`：commit 历史分页回溯（hash、7位 short_id、summary、author、timestamp、parent_count）。
  - 接入 `git2` 工作区离线依赖，单元测试覆盖非仓库降级、新仓库初始化、多提交历史回溯、脏工作区文件变更分类检测。
- **Git 状态感知与 UI 视觉呈现**：
  - 文件树（File Explorer）：根据工作区 Git 状态实时着色展示（未跟踪/新增绿色、修改蓝色、正常白色）。
  - 状态栏（Status Bar）：实时显示当前分支名（`feature/login*`）与工作区脏状态标记。
  - 编辑器（Editor Gutter）：侧边行号栏实时高亮显示改动行差异条（修改行高亮蓝色）。
  - 快捷键扩展：`defaults/keymaps-macos.toml` 补齐 `Cmd+Shift+G` / `Cmd+9` 聚焦版本控制面板、`Cmd+J` 聚焦终端面板。
- **全套自动化测试验证**：
  - Rust 根工作区 20 项测试全部通过（0 failed）。
  - `apps/rust_editor`（`lapce-app` 22 项、`lapce-core` 7 项、`lapce-rpc` 3 项）测试全部通过（0 failed）。
  - Flutter 自动化测试 205 项全绿（0 failed）。
- **GUI 可视验收（截图归档）**：
  - ✅ Git 仓库分支指示与工作区文件状态着色正常（`codelitex_phase4_git_init.png`）。
  - ✅ 编辑器代码行改动差异高亮条正常渲染（`codelitex_phase4_git_diff.png`）。

### Git 历史面板（2026-10-08）

底部面板「Git History」（`Cmd+0` 聚焦 / 面板图标），布局和 Flutter 版的 Git 工具窗一致：

- **标题栏**：`Git` + 带下划线的 `Log` 标签，右侧刷新、隐藏。
- **左侧竖工具条（30px）**：收起 / 展开分支栏、聚焦搜索、刷新。
- **分支栏（230px）**：顶部小搜索框；树为 `HEAD (Current Branch)`、`Local`、`Remote`，分支名按 `/` 折成文件夹，远程再按 remote 名分组；当前分支加粗，`main` / `master` 带星；点分支按它过滤，再点取消。
- **中栏**：过滤条（搜索框「Text or hash」带 `.*` 正则 / `Cc` 区分大小写，下拉 Branch / User / Date / Paths，刷新、显示详情）；提交列表每行为提交图 + 标题 + 分支 / 标签（`origin & dev`）+ 作者 + 日期（`2026/10/8, 14:05`），HEAD 为空心圆点，选中行蓝底；每页 200 条，滚到接近末尾自动续载；↑ / ↓ 切换选中提交。
- **详情栏（320px）**：变更文件树（根为项目名，文件夹带「N files」，状态着色，重命名显示 `← 原名`，可全部展开 / 折叠）+ 提交信息（等宽粗体）、`hash 作者 <邮箱> on 日期`、`committed by`、分支 / 标签名。
- **窄窗口**：与 Flutter 相同，先收详情栏、再收分支栏，提交列表至少留 460px；只影响本次布局，不改开关状态。

实现：`codelitex/git.rs`（`git2`：分页、搜索 / 正则 / 大小写、作者、时间、路径过滤，引用标签，提交详情，查询可取消）→ `codelitex/commit_graph.rs`（提交图轨道布局，移植自 Flutter 的 `layoutCommitGraph`）→ `codelitex/git_log_tree.rs`（分支树和文件树的行）→ `codelitex/git_log.rs`（状态，后台线程读取，新请求使旧结果作废）→ `panel/git_log_view.rs`（Floem 视图）。新增面板种类 `PanelKind::GitLog`，也在全新布局的默认顺序里。

与 Flutter 版的差异：
- 界面文字为英文（与 Rust 版其余部分一致）。
- 没有的：Cherry-Pick 与「跳转到哈希 / 分支 / 标签」按钮、提交右键菜单、←/→ 跳父 / 子提交、仓库损坏提示条。
- 提交图最多画 16 条轨道（过滤后许多提交的父提交不在列表里，轨道永远不闭合，Flutter 版会一路变宽）。

验证：数据层、提交图、两棵树共 50 多个单测；在真实项目 `bcpoker_game_server`（253 个分支）的运行中依次切换了时间、作者、路径、分支、文本、正则过滤并检查了每步结果，非法正则会报错。**界面外观仍未目视确认**（当前会话没有屏幕录制权限）。

#### 看某个提交里一个文件的差异

- 在详情栏的变更文件上**双击**，或选中后点工具栏左侧的 Diff 按钮，在编辑区打开该文件在这个提交里相对**第一个父提交**的并排差异（合并提交也是如此；根提交的左侧为空；新增文件左侧为空、删除文件右侧为空；重命名按旧路径读左侧）。用的是 Lapce 自带的差异视图（两侧只读），所以没有 Flutter 版那种每块的「>>」还原按钮。
- 标签页标题为 `App.java (4d26280)`；同一个提交的同一个文件再打开会复用已有标签，浏览别的文件时替换预览标签。
- 两侧是「历史文档」，版本字符串 `git:<提交>:<路径>` / `git-empty` / `head`（见 `codelitex/git_diff.rs`），会随工作区状态保存；重新打开工作区时按版本字符串重新读取，不会被错当成 HEAD。
- 二进制文件显示 `Binary file not shown`，超过 4 MB 的文件显示 `File too large to show`。
- 验证：版本字符串、各种变更的左右两侧、标题、按提交读文件（含二进制 / 超大）有单测；在真实项目里运行时自动打开了一个文件的差异，两侧分别读到 5799 与 6269 字节。**差异标签页的外观未目视确认。**
