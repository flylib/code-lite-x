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
- 阶段 3（工作区与编辑器功能）待开始。

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
