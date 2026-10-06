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
- 计划文档已建立；阶段 0 正在进行。
- 已观察到当前 Rust 版本为 1.95.0，满足 Lapce `v0.4.6` 声明的 MSRV。
- Lapce `v0.4.6` 已通过 SSH 浅克隆到临时目录 `/tmp/codelitex-lapce-v046-ssh`，上游提交为 `b012cef466741528f338879fa708355217fc40bd`；源码未并入产品工作区。
- Lapce `Cargo.lock` 的 13 个 Git 源已按锁定 revision 获取到临时目录 `/tmp/codelitex-lapce-deps`，并逐一核对提交号。
- Lapce 锁定了 723 个 registry 包版本。补充本机 registry 缓存时，下载的 crate 均来自 crates.io 官方端点，并逐个按 `Cargo.lock` 中的 SHA-256 校验。
- 在临时克隆中将 24 个 Git 包临时改为指向这些精确提交的本地路径后，使用 Rust 1.95.0 执行 `cargo build --offline` 成功（Lapce `dev` profile）。该临时验证修改没有进入 `rust` 分支。
- 原始 Lapce 清单直接执行 `cargo build --offline --locked` 仍会因 Cargo 原生 Git checkout 缓存中缺少 `winit`（`dpi` patch）而失败；因此阶段 0 的源码编译已验证，但可复现的 Cargo Git 源缓存/集成方案仍待确定，尚未进入阶段 1。
- 临时构建目录只用于验证；接入时需使用稳定、可复现的本地依赖路径，并保留各上游许可证和版权声明。
