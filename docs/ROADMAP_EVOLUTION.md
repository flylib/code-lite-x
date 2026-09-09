# CodeLiteX 工业级演进路线图 (Evolution Roadmap v4.2)

> **版本**：v4.2（架构决策收敛版）
> **修订日期**：2026-09-09
> **定位**：从「原生 AI 编程编辑器原型」演进至「工业级高可用、多语言、开放生态的下一代 AI-Native IDE」
> **已完成基线**：Phase 0 ~ Phase 5

> ### 核心命题
> **CodeLiteX 的核心竞争力不是 LLM，而是 Agent Runtime + Tool Runtime + CodeGraph + Memory + Workspace State。模型只是 Provider。**
> 本版路线图据此组织：先补齐这五项底座与其间的抽象边界，再进入功能实施。

> ### 版本演进说明
> - **v4.0**：功能清单式规划。阶段排序的产品判断正确，但基线描述与代码实际状态存在偏差。
> - **v4.1**：对全部基线陈述逐条核对代码后修订，新增两个被遗漏的阻塞性前置阶段。
> - **v4.2**（本版）：收敛四项架构决策（D1'/D2/D3/D4），补齐 **Agent Runtime** 与 **检索/上下文层** 两处架构缺口，
>   并**取消历史编号负担，全面改用整数编号**。

---

## 0. 编号映射表（v4.0 / v4.1 → v4.2）

历史编号在 v4.1 中因阶段插入与换序出现 `7 → 9 → 8` 的乱序。v4.2 起 0~5 已完成、6 以后全用整数续排，不再使用小数编号。

| v4.2 | 主题 | v4.1 | v4.0 |
| :-- | :--- | :-- | :-- |
| **Phase 6** | 安全底座与工程前置（含 Core API 契约 + codegen） | Phase 5.5 | — |
| **Phase 7** | Editable Editor Kernel（可编辑编辑器内核） | Phase 6.0 | [已完成 ✅ 2026-09-09] |
| **Phase 8** | IDE Core（LSP Supervisor / Ghost Text / Tabs·Split·Gutter） | Phase 6 | [已完成 ✅ 2026-09-10] |
| **Phase 9** | Agent Runtime + Multi-file + Git Worktree | Phase 7 | [已完成 ✅ 2026-09-10] |
| **Phase 10** | 检索/上下文层（项目指令 → Memory → Skill → MCP） | — | — |
| **Phase 11** | Cross-platform Release（全平台发布与增量更新） | Phase 9 | Phase 9 |
| **Phase 12** | WASM Plugin Ecosystem（插件生态） | Phase 8 | Phase 8 |

> 引用旧编号的外部文档（含 `.gemini` brain 目录下的副本）请按本表换算。

---

## 1. 架构决策（已收敛，作为后续实施的前提）

| 编号 | 决策项 | 结论 | 影响范围 |
| :-- | :--- | :--- | :--- |
| **D1'** | UI ↔ Core 传输层 | **TOML IDL 契约 + JSON-RPC 2.0 线格式 + xtask codegen**；FFI 为唯一激活 Adapter，HTTP / Remote 留槽不实现 | Phase 6、8、11 |
| **D2** | 并发模型 | **沿用 `std::thread` + `parking_lot`，不引入 tokio** | Phase 8 |
| **D3** | macOS 更新策略 | **整包替换 + `.app` 级差分（Sparkle 模式）**；组件级差分仅用于 Windows / Linux | Phase 11 |
| **D4** | Skill 的架构层次 | **Prompt-first, Capability-second 两层架构**（详见下方） | Phase 10、12 |

### D1' 详解：传输层抽象为 Core API + Adapter

原 v4.1 将此题设为「FFI vs HTTP 二选一」，属于问题设定错误 —— CodeLiteX 的目标形态已不止本机桌面编辑器，未来需覆盖远程 Agent / 容器 Agent / SSH Workspace / Remote Development。把选择锁死在具体传输上会限制演进。正确的问法是 **UI ↔ Core Transport 该如何抽象**。

```
单一 Core API 契约 (core_api.toml)          ← 单一真源
        │  xtask codegen
        ├──► Rust  dispatch table + 请求/响应结构体
        └──► Dart  client + 类型化 model
                │
                ├── Local FFI Adapter        ← 当前唯一激活
                ├── Local IPC/HTTP Adapter   ← 留槽不实现
                └── Remote Adapter           ← 留槽不实现
```

**支撑依据**：`code-lite-ffi` 的 50 个 `#[no_mangle]` 导出**全部以 `*const c_char` 收发 JSON**，
即 FFI 侧本来就是消息传递语义，与 HTTP 侧完全同构 —— 两者之间不存在阻抗差，Adapter 抽象几乎零成本。

**两条硬约束**：
1. **契约是单一真源，两侧代码生成。** 无 codegen 的 Adapter 抽象 = 同样的维护账 + 更多间接层 —— 今天的真实成本正是 `codelite_bindings.dart`(746 行) 与 `api_client.dart`(517 行) 两份手写镜像各自漂移。
2. **现阶段只激活一个 Adapter。** 定义边界 ≠ 实现三份；无远程用户即不写 Remote Adapter。

**已排除方案**：

| 方案 | 排除理由 |
| :--- | :--- |
| flutter_rust_bridge | 它本身即 FFI 绑定生成器 —— 与传输无关性目标直接冲突；它不是契约层，而是其中一个 Adapter |
| gRPC / tonic | tonic 强制引入 tokio，与 D2 冲突 |
| OpenAPI | 仅能描述 HTTP，无法描述 FFI Adapter |
| 纯 protobuf（不含 gRPC） | 技术可行，但需替换现有 JSON 约定，迁移成本高而收益仅为 payload 体积 —— 当前瓶颈不在此 |

### D4 详解：Skill 的两层架构（Prompt-first, Capability-second）

```
Skill  = Instructions + Workflow + Tool Bindings   (prompt 层，声明式，无需编译)
Plugin = Runtime Capability                        (WASM 沙箱，可执行)

判别式:   该能力是否需要向 ToolRuntime 注册新 Tool ?
              否 → Skill          是 → Plugin

硬约束:   Skill 只能绑定「已安装且已授权」的 Tool。
          Binding 是引用,不是打包 —— Skill 不得携带、也不得触发安装任何 Plugin。

选择机制: 与 Memory 检索共用同一检索层(description 匹配,交由模型判断)
```

**为何需要那条硬约束**：若安装一个 Skill 可顺带拉入 WASM 能力，则 Skill 本身变成授权面
（装一个 `docker.skill` 等于授予容器操作权限），构成供应链风险。
明确 Binding 为「引用已授权能力」后，Phase 6-A 加固后的 ToolRuntime 仍是唯一授权权威，Skill 仅在已授权能力上做编排。

**因此 Skill 不单列 Phase**：其格式三级演进（`SKILL.md` → `+Tool Bindings` → `+WASM 引用`）
不需要三个路线阶段，而是**一个阶段（Phase 10）+ 一条绑定规则**，第三级随 Phase 12 提供新 Tool 自然解锁。
理由见 Phase 10 —— Skill 选择与 Memory 检索是同一套机器。

---

## 2. 基线核对表（代码实测 vs 历史文档描述）

> 全部结论标注 `文件:行号`，可直接复核。核对基准：`main` 分支，2026-09-09。

### 2.1 高估项（已实现，勿重复建设）

| # | 历史描述 | 代码实际 | 依据 |
| :-- | :--- | :--- | :--- |
| 1 | 「打通真实外部 LSP 进程」= 全新工作 | **已完成约 70%**：子进程 stdio、`Content-Length` framing、后台 reader 线程、`initialize`/`initialized` 握手、FFI 出口齐备 | `code-lite-lsp/src/client.rs:58`<br>`code-lite-lsp/src/transport.rs`<br>`code-lite-ffi/src/lib.rs:919` |
| 2 | Agent「缺少状态机」 | **已有 7 态机**：`Pending / AwaitingApproval / Approved / Running / Success / Failed / RolledBack` | `code-lite-agent/src/planner.rs:7` |
| 3 | Agent「缺少 Verification」 | **已实现**：`apply_patch` → `did_change` → 过滤 Error 级诊断 | `code-lite-agent/src/executor.rs:160-175` |
| 4 | Agent「缺少 Recovery」 | **已实现**：自愈重试配额 → 耗尽后 `rollback_to_step(base_op_id - 1)` 原子回滚 | `code-lite-agent/src/executor.rs:181-215` |
| 5 | Agent「缺少 Context Engine」 | **已实现**：CodeGraph 拓扑 + LSP 诊断 → prompt 组装 | `code-lite-agent/src/context_builder.rs` |
| 6 | 「模型只是 Provider」需重构 | **架构上已成立**：`LlmProvider` 为单方法 trait，已有 `BuiltinRuleProvider` + `OpenAiCompatibleProvider`。Qwen / DeepSeek / Ollama 今日即可用（OpenAI 兼容），Claude / Gemini 各为一个 trait 实现 | `code-lite-agent/src/llm.rs:118` |
| 7 | 多 buffer 需新建 | **已就绪**：`editors: Mutex<HashMap<String, Editor>>`；Rust 侧 `buffer.rs`(267) / `cursor.rs`(374) / `history.rs`(187) 完备 | `code-lite-ffi/src/lib.rs:41` |

### 2.2 低估项与缺失项（真实工作量所在）

| # | 历史描述 | 代码实际 | 依据 |
| :-- | :--- | :--- | :--- |
| 8 | Ghost Text / 分屏 = 在现有编辑器上「增强」 | **编辑器当前只读**：`StatelessWidget` + `lines.map(RichText)`，无 `TextField`/`EditableText`、无光标、无选区、无 per-pane 滚动控制器 | `editor_view_widget.dart:6` |
| 9 | 行内幽灵补全已有雏形 | **硬编码字符串占位**，非功能实现 | `editor_view_widget.dart:366`、`:381` |
| 10 | Tab Strip 已具备 | **标签列表写死在源码**；`onCodeChanged` 已声明并透传，但**全项目无任何调用点触发** | `app.dart:30`、`:227` |
| 11 | Planner 已具备 | **不是 planner，是关键词规则引擎**：`prompt_lower.contains("delete")` → 吐出写死的三步模板 | `code-lite-agent/src/planner.rs:127` |
| 12 | 已实现「自愈闭环」 | **诊断不回流模型**：验证失败仅 `_attempt` 计数 +1 并**重跑同一 step**（`step.args` 未变），N 次后回滚。实为「原样重试 N 次后放弃」 | `code-lite-agent/src/executor.rs:181-215` |
| 13 | Context Engine 完整 | **无检索阶段**：`build_prompt_context(focus_file, focus_symbol)` 要求调用方已知何为相关 | `code-lite-agent/src/context_builder.rs:96` |
| 14 | — | **项目指令文件无人读取**：仓库有 `GEMINI.md`(154 行，完整架构说明) 与 `AGENTS.md`(6 行)，但 `crates/` 与 `apps/code_lite_ui/lib/` 中 grep `AGENTS.md\|GEMINI.md\|CLAUDE.md` **零命中** | — |
| 15 | Memory | **不存在** | — |

### 2.3 缺陷项（阻塞性，须前置修复）

| # | 项 | 问题 | 依据 |
| :-- | :--- | :--- | :--- |
| 16 | Tool Runtime 沙箱 | **未封闭**：路径无包含性校验 + `Low`/`Medium` 全自动放行 → 任意路径读 / 任意路径写均无需批准（详见 Phase 6-A） | `tool_runtime.rs:49`、`:92`、`:132`、`:198`<br>`permission.rs:122` |
| 17 | LLM 通道 | **shell out 到 `curl` 子进程**；API key 与完整 prompt body 均落在 argv 上 → `ps` 可读 + 撞 `ARG_MAX` | `llm.rs:265`、`:275`、`:278` |
| 18 | 传输层 | **两套并存**：UI 实际走 HTTP(`127.0.0.1:4096`)，FFI 的 50 个导出 + 746 行 Dart binding 处于旁路 | `app.dart:3`<br>`api_client.dart:11` |
| 19 | LSP 握手 | **server capabilities 被丢弃**：`let _ = client.send_request("initialize", ...)` | `client.rs:137` |
| 20 | LSP 同步 | **`did_change` 全量发送文档文本**，与 Ghost Text 的 300ms 防抖叠加将造成大文件反复全量重发 | `client.rs:315` |
| 21 | 测试基线 | 50 个 `#[test]` **全为 crate 内 inline 单测**；无 `crates/*/tests/` 目录，无一条跨传输边界的测试 | — |
| 22 | Dart 并发 | Dart FFI binding 中**无任何 `Isolate`**，全部同步调用运行在主 isolate | `codelite_bindings.dart` |
| 23 | 更新机制 | 「差分只更新 `.dylib`」会**破坏已签名 bundle 的 code signature**，导致 notarization 失效 | 见 D3 |

---

## 3. 目标态架构

> ⚠️ 下图为**演进目标态**，非当前实际调用链。当前实际形态见 §4。

```
                                    CodeLiteX
                                        │
                        ┌───────────────┴───────────────┐
                        │                               │
                 Flutter Desktop                    Rust Core
                        │                               │
            ┌───────────┴────────────┐      ┌───────────┴────────────┐
            │   Editor Kernel        │      │     Agent Runtime      │
            │  (Phase 7)             │      │     (Phase 9)          │
            │                        │      │                        │
            │  Cursor / Selection    │      │  Planner (模型驱动)     │
            │  IME / Viewport        │      │  Context Engine        │
            │  Tabs / Split / Dirty  │      │  Observation → Re-plan │
            │  Ghost Text (Phase 8)  │      │  Verification          │
            │  Git Gutter (Phase 8)  │      │  Recovery              │
            └───────────┬────────────┘      │  State Machine         │
                        │                   │  Permission            │
                        │                   └───────────┬────────────┘
        ┌───────────────┴───────────────┐               │
        │   Core API 契约 (D1')          │               ▼
        │   TOML IDL + JSON-RPC 2.0     │   ┌────────────────────────────┐
        │   ├── Local FFI Adapter ✓     │   │  Tool Runtime              │
        │   ├── IPC/HTTP Adapter  ○     │   │  (唯一受控安全网关)         │
        │   └── Remote Adapter    ○     │   │  三级权限 + 路径包含性校验   │
        └───────────────────────────────┘   └─────────────┬──────────────┘
                                                          │
                    ┌─────────────────┬───────────────────┼──────────────────┐
                    │                 │                   │                  │
                   LSP            CodeGraph              Git            MCP / WASM
              (Phase 8)                                                 (10 / 12)
                    │                 │                   │
            rust-analyzer          Symbol             Worktree
            gopls / clangd         Reference          Diff
            vtsls / dart           Call Graph         Merge
                    │                 │                   │
                    └─────────────────┼───────────────────┘
                                      ▼
                    ┌──────────────────────────────────────┐
                    │   检索 / 上下文层  (Phase 10)          │
                    │                                      │
                    │   项目指令文件  →  Memory Engine       │
                    │                 →  Skill Selection   │
                    │        统一 description 相关性匹配     │
                    └──────────────────┬───────────────────┘
                                       ▼
                    ┌──────────────────────────────────────┐
                    │   存储基座  .codelite/project.db      │
                    │   SQLite WAL  (+ 可选 Vector Index)   │
                    │   graph / event / op / session /      │
                    │   diagnostic / approval  stores       │
                    └──────────────────┬───────────────────┘
                                       ▼
                                 Model Providers
                        ┌─────────┬─────────┬─────────┬─────────┐
                      Claude    Gemini     Qwen    DeepSeek   Ollama
                        (LlmProvider trait — 单方法,已就绪)
```

---

## 4. 当前实际形态（2026-09-09）

```
        Flutter UI (app.dart)
              │
              │  import 'core/client/api_client.dart'        ← 实际在用
              ▼
        HTTP  http://127.0.0.1:4096  (package:http)
              │                       api_client.dart:11
              ▼
        code-lite-app::server
              │
              ▼
        Rust Core
              │
              ├── Agent: Planner(关键词规则) → Executor → Verify → 原样重试 → Rollback
              │                                              └── 无 Observation 回流
              ├── ToolRuntime: 无路径包含性校验,Low/Medium 自动放行
              ├── LLM: spawn curl 子进程,key 在 argv
              └── 检索层: 不存在(GEMINI.md 154 行无人读取)

        ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
        codelite_bindings.dart (746 行)  ──╳──  未接入 app.dart
        code-lite-ffi (2076 行 / 50 个导出,全为 c_char JSON)
        ┈┈┈┈┈ 并行第二套传输,当前旁路(技术债,Phase 6-C 处理)┈┈┈┈┈
```

---

## 5. 阶段规划概览

| 阶段 | 主题 | 解决的核心痛点 | 关键交付 | 阻塞关系 |
| :--- | :--- | :--- | :--- | :--- |
| **6** | 安全底座与工程前置 | 安全网关未封闭；LLM 通道撑不住高频；双传输并存；无集成测试兜底 | 路径包含性校验<br>进程内 HTTP 客户端<br>Core API 契约 + codegen<br>`crates/*/tests/` | 阻塞 7 / 8 / 9 / 12 |
| **7** | Editable Editor Kernel | 编辑器只读，Ghost Text / 分屏 / Gutter Revert 全部缺前置原语 | 光标 / 选区 / IME / Viewport<br>Rust `Editor` 双向绑定<br>耗时调用移出主 isolate | 阻塞 8 |
| **8** | IDE Core | 无真实语言服务托管；无行内补全；无工业级多文件工作区 | `lsp::supervisor`<br>`agent::fim`<br>Tabs / Split / Git Gutter | — |
| **9** | Agent Runtime + 多文件 + Worktree | Plan 非模型生成；观测不回流；跨文件改动无协调；实验污染工作区 | 模型驱动 Planner<br>Observation → Re-plan<br>`fs::worktree` | 依赖 6-D |
| **10** | 检索 / 上下文层 | Agent 无长期记忆；项目知识无载体；上下文靠调用方硬传 | 项目指令文件读取<br>Memory Engine<br>Skill + MCP | 依赖 9 |
| **11** | Cross-platform Release | 仅 macOS 打包，无 Linux / Windows 生产包与热升级 | 三平台打包矩阵<br>Auto-Updater（分平台策略） | — |
| **12** | WASM Plugin Ecosystem | 外部能力无法动态扩展 | `code-lite-plugin` (Wasmtime)<br>Plugin SDK | **硬依赖 6-A** |

---

## 6. 详细阶段设计

### 🔸 Phase 6: 安全底座与工程前置

> **阻塞 Phase 7 / 8 / 9 / 12。本阶段全部为既有代码的加固与归一，不新增用户可见功能。**

#### 6-A. Tool Runtime 沙箱封闭化 —— **Phase 12 的开工前提**

**三条独立缺陷，叠加后等价于「无沙箱」：**

1. **路径可逃逸**：全部工具统一使用 `self.workspace_root.join(relative_path)`
   （`tool_runtime.rs:49` `read_file` / `:92` `apply_patch` / `:198` `delete_file`），**未做 `canonicalize` 与包含性校验**。
   Rust 的 `Path::join` 遇绝对路径时会丢弃 base，故 `read_file("/Users/<user>/.ssh/id_ed25519")` 与 `../` 形式均可逃逸出工作区。
2. **写操作免批准**：`permission.rs:122` 为 `RiskLevel::Low | RiskLevel::Medium => Ok(Granted)`。
   `read_file` 评级 Low、`apply_patch` 评级 Medium，**两者全自动放行**；仅 `delete_file` 与未知工具为 Critical。
   合并第 1 条即：**任意路径读 + 任意路径写，均无需用户批准**。
3. **命令无白名单**：`execute(cmd, args)`（`tool_runtime.rs:132`）仅以 `current_dir` 约束，而 cwd 无法约束绝对路径与任意可执行文件。

**交付要求：**
- 统一路径守卫：所有工具入口先 `canonicalize`（含父目录解析），再断言 `starts_with(workspace_root)`；拒绝绝对路径与符号链接穿越。
- 权限分级修正：`apply_patch` / `delete_file` / `execute` 一律上调至需显式批准；`Medium` 不再自动放行。
- `execute` 引入命令白名单（构建 / 测试 / VCS 类）+ 参数校验。
- 补写针对性逃逸测试：绝对路径、`../` 穿越、symlink、白名单绕过。

> **与 Phase 12 的关系**：wasmtime 仅保证插件不直接触碰宿主文件系统，但插件要产生价值就必须调用 Host API，
> 而 Host API 背后正是 Tool Runtime。**Phase 12 的安全上限 ≡ Tool Runtime 的安全上限。**
> 本项完成前 Phase 12 不具备开工条件。同时本项也是 D4 硬约束（Skill 只能引用已授权 Tool）的执行者。

#### 6-B. LLM 通道替换 —— **Phase 8 Ghost Text 的开工前提**

**现状问题**（`llm.rs:265-278`）：每次请求 `spawn` 一个 `curl` 子进程，且
- `cmd.arg("-H").arg(format!("Authorization: Bearer {}", key))`（`:275`）→ **API key 位于 argv，本机任意进程可通过 `ps` 读取**；
- `cmd.arg("-d").arg(&body_str)`（`:278`）→ 完整 prompt body 亦位于 argv，将撞上 `ARG_MAX`（macOS 约 256 KB）。

**交付要求：**
- 改为进程内 HTTP 客户端：按 D2（同步模型）选 `ureq`。
- key 走 header、body 走 socket，**不得出现在任何进程参数中**。
- 保留 `BuiltinRuleProvider` 兜底路径与 `ThinkingStreamParser`（现有 SSE / `<think>` 解析可直接复用）。
- **扩展 `LlmProvider` trait 增加结构化输出 / tool-call 路径** —— 当前只有 `stream_chat`（`llm.rs:118`），
  而 Phase 9 的模型驱动 Planner 必须能获得 schema 约束的结构化 Plan。此项是 Phase 9 的前置。

> **必要性**：Phase 8 的 FIM 是**高频**请求（每次键入停顿触发）。per-request fork 进程的开销与上述缺陷叠加，将使「毫秒级手感」目标失效。

#### 6-C. Core API 契约与传输层归一（D1' 落地）

**契约格式：TOML IDL（`core_api.toml`）**

选独立 IDL 而非 Rust proc-macro，因为漂移有更简单的解法：
**生成的 Rust dispatch table 按名字引用 handler 函数 —— IDL 声明了但未实现即编译失败**，
故 IDL 无法静默漂移，且无需承担 proc-macro 的调试与编译期代价。

选 TOML 而非 YAML / JSON：TOML 可写注释；`toml` crate 极稳定且仅 build 期使用；`serde_yaml` 维护状态不佳。

```toml
[api]
version = 1                       # 契约版本,Adapter 握手时校验

[[method]]
name    = "file.open"
kind    = "call"                  # 请求/响应
handler = "handlers::file::open"  # dispatch 按名字引用 → 缺实现即编译错
params  = { path = "string" }
returns = "FileContent"

[[method]]
name    = "lsp.completion"
kind    = "call"
handler = "handlers::lsp::completion"
params  = { uri = "string", line = "u32", character = "u32" }
returns = "CompletionItem[]"

[[method]]
name    = "agent.send_prompt"
kind    = "stream"                # 服务端 → 客户端推送流
handler = "handlers::agent::send_prompt"
params  = { session_id = "string", prompt = "string" }
emits   = "StreamEvent"

[[type]]
name   = "StreamEvent"
fields = { session_id = "string", event_type = "string", text = "string", plan_json = "string?" }
```

**线格式：JSON-RPC 2.0 —— 复用自有实现，零新依赖**

`code-lite-lsp` 已有完整的 JSON-RPC 2.0 实现并正在驱动 rust-analyzer：
`transport.rs` 的 `Content-Length` framing、`client.rs` 的 request-id 关联 + `pending_requests` + `Condvar` 等待模型。
且它天生 transport-agnostic（LSP 本身即跑在 stdio / pipe / socket / websocket 上），notification 语义原生支持流。
落地动作：将 framing 与 correlation 从 `code-lite-lsp` 抽出为共享 crate。

**`kind = "stream"` 的语义边界**：契约只声明「这是流」，**投递方式交由各 Adapter 自行决定**。

| Adapter | stream 投递方式 |
| :--- | :--- |
| FFI（现阶段） | 保留现有 drain-poll（`stream_events` + `poll_stream_events`） |
| FFI（后续可选升级） | Dart `NativePort` / `Dart_PostCObject` 真推送 |
| HTTP | SSE |
| Remote | WebSocket |

生成的 Dart client 对上层**统一暴露 `Stream<StreamEvent>`**，UI 不感知底层是轮询还是推送 ——
故 Phase 8 完成后把 FFI 从 poll 换成 NativePort **无需改动任何 UI 代码**。这是该抽象的主要收益点。

**codegen：xtask 模式，不用 build.rs**

不使用 `build.rs`（每次编译都跑生成器会拖慢构建，且生成物不入 git 不利 review）。

```bash
cargo run -p xtask -- codegen
```

生成物提交进仓库：`crates/code-lite-ffi/src/generated/dispatch.rs`、`apps/code_lite_ui/lib/core/api/generated/`。
CI 增加一步「跑生成器 + `git diff --exit-code`」，改 IDL 未重新生成即失败。

**规模与收益**

| 项 | 量 |
| :-- | :-- |
| IDL（50 方法 + 类型） | ~400 行 TOML |
| 生成器 | ~300–500 行 Rust |
| 替换掉的手写代码 | `codelite_bindings.dart` 746 行 + `api_client.dart` 517 行 + 部分 FFI boilerplate |

净减少代码量，且**漂移从「靠人盯」变为「编译期报错」**。

**迁移路径：不要一次转 50 个**

```
第 1 步  抽共享 jsonrpc crate(从 code-lite-lsp 提 framing + correlation)
第 2 步  IDL 只写 Phase 7/8 真正需要的 8 个方法:
         file.open / file.edit / undo / redo /
         lsp.completion / lsp.diagnostics / agent.send_prompt / git.status
第 3 步  生成物与现有手写两套并存,新 UI 代码只走生成的 client
第 4 步  Phase 7/8 完成、契约形状被真实需求验证后,再批量迁余下 42 个
第 5 步  删除 api_client.dart 与 code-lite-app::server(FFI 为唯一激活 Adapter)
```

> **第 2 步刻意只做 8 个**：契约设计的最大风险是在无真实调用方时把形状定错。
> 让 Editor Kernel（高频）与 Ghost Text（流式）这两个最挑剔的消费者先把契约压出形状，再批量迁移。

#### 6-D. 集成测试骨架

现状：50 个 `#[test]` 全为 crate 内 inline 单测，**无 `crates/*/tests/` 目录，无跨传输边界测试**。
Phase 9 的多文件拓扑规划与 worktree 合并属典型「单测测不出」场景，须先立骨架：
- `crates/*/tests/` 集成测试目录；
- 一条贯穿传输层的端到端用例（打开工作区 → 编辑 → 诊断 → Agent 计划 → 批准 → 回滚）。

---

### 🔸 Phase 7: Editable Editor Kernel [已完成 ✅ 2026-09-09]

> **阻塞 Phase 8 的 Ghost Text 与 Tabs / Split / Gutter。**

**现状问题**：`editor_view_widget.dart:6` 为 `StatelessWidget`，正文由 `lines.map(_buildCodeLine)` 渲染为一组 `RichText`。
不存在 `TextField` / `EditableText`、光标、选区、per-pane `ScrollController`；
`_buildAiGhostText()`（`:366`）返回硬编码字符串（`:381`）；
`_openTabs` 写死于 `app.dart:30`；`onCodeChanged` 虽已透传但**无任何触发点**（`app.dart:227` 仅赋值）。

即：Ghost Text 的「`Tab` 采纳并移动光标」「`Cmd+Right` 逐词采纳」、分屏的「两栏独立 Viewport 与 Cursor」、
Gutter 的「点击展开 Diff 浮层并 Revert 单行」，**全部建立在一个尚不存在的文本输入原语之上**。

**利好条件**：Rust 侧底座已完备 —— `buffer.rs`(267) / `cursor.rs`(374) / `history.rs`(187)，
且 `editors: Mutex<HashMap<String, Editor>>`（`code-lite-ffi/src/lib.rs:41`）已是多 buffer 结构。**缺口纯粹在 Flutter 侧。**

**交付要求：**
- 文本输入原语：真实光标、选区、键盘输入、**IME 组合输入**、per-pane `ScrollController`。
- 与 Rust `Editor` 的双向绑定：编辑事件下推、`buffer` 状态上取；Dirty 状态由 Rust 侧 `history` 派生。
- 每标签独立的 buffer / cursor / viewport 状态（对接已有 `editors` HashMap）。
- **耗时调用移出主 isolate**：当前 Dart FFI binding 中无任何 `Isolate`，全部同步调用在主 isolate。
  `rust-analyzer` 冷启动索引期请求可达数秒，FIM 还需走网络 —— 必须迁至 helper isolate。

> **工作量提示**：本阶段 + Phase 8 的 Ghost Text / Tabs 合计规模约为 v4.0 原估值的两倍以上，请勿混排。

---

### 🔹 Phase 8: IDE Core（LSP Supervisor / Ghost Text / 多标签分屏）

#### 8.1 LSP Supervisor [已完成 ✅ 2026-09-09]

**已具备，勿重复实现**：`spawn_process`（`client.rs:58`）的子进程 stdio、`initialize`/`initialized` 握手、
后台 reader 线程、`pending_requests` + `Condvar` 同步等待；`transport.rs` 的双向 framing（含 3 个测试）；
FFI 出口 `codelite_lsp_init_server`（`code-lite-ffi/src/lib.rs:919`，已支持外部二进制与 `VirtualLspServer` 回退）。

**本阶段实际待建**：
- **`ProcessSupervisor`**：语言服务器二进制探测、按语言路由（`rust-analyzer` / `gopls` / `clangd` / `vtsls` / `dart_analysis_server`）、多实例生命周期托管；
- **自愈机制**：子进程 panic / OOM 后指数退避重启，并**重放当前已打开文档的 `textDocument/didOpen`**；
- **修复两处既有缺陷**：
  - `client.rs:137` `let _ = client.send_request("initialize", ...)` —— **server capabilities 被丢弃**。
    Supervisor 需据此判断增量 / 全量同步与 rename 支持，必须保留该响应；
  - `did_change`（`client.rs:315`）**全量发送文档文本** —— 与 8.2 的防抖叠加会造成大文件反复全量重发，须改为 incremental sync。
- **并发模型**：沿用 `std::thread` + `parking_lot`（D2），不引入 tokio。

#### 8.2 行内幽灵代码补全与 FIM（`code-lite-agent::fim`）[已完成 ✅ 2026-09-09]

**前置**：Phase 6-B（LLM 通道）、Phase 7（编辑器内核）。

- **Fill-in-the-Middle 模板**：提取光标前 1000 字符（Prefix）与光标后 500 字符（Suffix），注入大模型 FIM 协议；
- **防抖调度**：键入停顿后 300ms 静默异步触发（`_scheduleFimQuery`）；
- **灰色幽灵文字渲染**：光标右侧以 `#6E7681` 虚影展示候选片段（替换 `_buildAiGhostText` 的硬编码占位，并在存在建议时提供 `_buildAiGhostHint` 状态栏交互提示）；
- **键盘交互**：`Tab` 完全采纳并移动光标至末尾；`Cmd+Right` / `Ctrl+Right` 逐词采纳；`Esc` 或不匹配输入立即丢弃。

#### 8.3 多标签页与分屏工作区 [已完成 ✅ 2026-09-10]

**前置**：Phase 7。

- **Tab Strip**：文件类型图标、关闭按钮、拖拽排序、`Cmd+W` 关闭当前标签（替换 `app.dart:30` 硬编码列表）；
- **Dirty Dot**：由 Rust 侧 `history` 状态派生，退出时弹窗确认；
- **水平 / 垂直分屏**：左右或上下两栏，各自独立 Viewport 滚动与 Cursor；
- **Git Gutter**：绿（新增）/ 蓝（修改）/ 红倒三角（删除）指示条；点击就地展开微型 Diff 浮层，支持单行 Revert。

---

### 🔹 Phase 9: Agent Runtime + 多文件协同 + Git Worktree [已完成 ✅ 2026-09-10]

> **前置**：Phase 6-B（结构化输出）、Phase 6-D（集成测试骨架）。
> **本阶段的定义方式**：由**两条缺失的边**界定，而非枚举子系统清单 ——
> 在一个阶段内立起 9 个子系统正是 v4.0 的 Phase 6 变得无法估算的原因。

#### 9.1 Agent Runtime：补两条边，其余六项重构归位

**已存在，本阶段只做重构归位、不重写：**

| 组件 | 现状 | 依据 |
| :--- | :--- | :--- |
| State Machine | 7 态机完备 | `planner.rs:7` |
| Tool Executor | `PlanExecutor` + `ToolRuntime` | `executor.rs:36` |
| Permission | 已有（Phase 6-A 加固） | `permission.rs` |
| Verification | `apply_patch` → `did_change` → 过滤 Error | `executor.rs:160-175` |
| Recovery | 重试配额耗尽 → 原子回滚 | `executor.rs:181-215` |
| Context Engine | CodeGraph + LSP → prompt | `context_builder.rs` |

**缺口一：Plan 不是模型生成的。**
`TaskPlanner::plan_task` 是关键词规则引擎 —— `prompt_lower.contains("delete")` → 吐出写死的三步模板（`planner.rs:127`）。
现在的 Planner 实为 if-else 派发器。
- **交付**：Planner 改为模型驱动（依赖 6-B 的结构化输出路径），**保留规则引擎作离线兜底**，与 `BuiltinRuleProvider` 同一模式。

**缺口二：Observation 不回流到模型。**
当前「自愈」为：验证失败 → `_attempt` +1 → **重跑同一 step**（`step.args` 未变）→ N 次后回滚。
诊断信息从未喂回 LLM 以生成不同的 patch，故实为「原样重试 N 次后放弃」。

```
现状:  Plan(规则) → Tool → Verify → ✗ → 原样重试 → ✗✗✗ → Rollback
                                     └────────┘  自己转圈,不经过模型

目标:  Plan(模型) → Tool → Verify → Observation → Re-plan(模型) → Tool → ...
                                          └──────────────┘  本阶段新增的回流边
```

- **交付**：通用 Observation 记录（不止 LSP 诊断特例）+ Re-plan 回流边；重试时携带上一轮观测结果。

#### 9.2 拓扑依赖感知多文件规划（`code-lite-agent::multi_file`）
- **拓扑排序修改计划**：基于 `code-lite-graph` 的 Call Graph 与 References，按被依赖者优先排序
  （先改 `models.rs` → 再改 `service.rs` → 最后改 `handler.rs`）；
- **多文件统一审查视窗**：集中列出全部涉改文件，支持逐文件折叠或一键全部批准。

#### 9.3 Git Worktree 独立实验沙箱（`code-lite-fs::worktree`）

> `code-lite-fs/src/git.rs` 已是 shell out 到 `git` 的实现，新增 worktree 近乎零架构成本。
> 且它能**兜住 Phase 6-A 的部分残余风险**（Agent 在独立目录内施为，失败直接删除），既是体验升级也是安全垫。

- `git worktree add .codelite/worktree/<task_id> -b agent/<task_id>`；
- 沙箱内自治构建与测试：独立目录内应用补丁、运行 `cargo test` / `flutter test`；
- **原子 Fast-forward 合并**：全部验证通过且用户批准后 `merge` 回主工作区并清理 worktree；失败则直接删除 worktree，用户工作区不受影响。

```
Agent 修改 → 独立 Worktree → Build / Test → Review → Merge
                    └── 失败则整目录删除,主工作区零影响
```

#### 9.4 细粒度步骤回滚
支持对 Plan 中单步局部撤销，不影响后续已验证的无害改动（可复用 `op_store::rollback_to_op` / `restore_session_start`）。

---

### 🔹 Phase 10: 检索 / 上下文层（本版唯一全新架构）

> **本阶段的核心洞察**：**Memory 检索与 Skill 选择是同一个操作 —— 按相关性注入上下文。**
> 分开建设等于把检索层写两遍。故 Memory、Skill、MCP、项目指令文件同属本阶段，共用一套选择机器。

**插入缝已经存在**：`AgentContextBuilder::build_prompt_context(focus_file, focus_symbol)`（`context_builder.rs:96`）
要求调用方**已经知道什么是相关的** —— 整条链路里没有检索这一步。

```
Task
  ↓
┌────────────── 检索层 (本阶段新建) ───────────────┐
│  统一 description 相关性匹配,交由模型判断         │
│                                                │
│  ├── 项目指令文件   (10.1)                      │
│  ├── Memory Retrieval (10.2)                   │
│  ├── Skill Selection  (10.3)                   │
│  └── MCP Tool 发现    (10.4)                    │
└────────────────────┬───────────────────────────┘
                     ↓
        build_prompt_context()   ← 已存在
                     ↓
                    LLM
```

> **选择机制不要自己写关键词规则** —— `planner.rs:127` 已演示过关键词规则会长成什么样。统一用 description 匹配交由模型判断。

#### 10.1 项目级指令文件读取 —— **投入产出比最高，优先做**

仓库已有 `GEMINI.md`（154 行，完整的模块职责与架构说明）与 `AGENTS.md`（6 行），
但 `crates/` 与 `apps/code_lite_ui/lib/` 中 grep `AGENTS.md|GEMINI.md|CLAUDE.md` **零命中 —— 无人读取**。

- **约 50 行代码，今天就有内容可读。** 接进 `AgentContextBuilder` 后，Agent 立刻知道 `crates/` 与 `apps/` 的职责分工。
- 这是整个 Skill 体系的**最小可用形态**，且不依赖任何 Skill 格式决策 —— 应作为本阶段第一步。

#### 10.2 Memory Engine —— **v1 只做两类，不做七类**

大量原料已在 SQLite 中，v1 是**在已有 store 上加检索层 + 写入触发器**，而非新建七个存储：

| 记忆类型 | 现状 | v1 是否纳入 |
| :--- | :--- | :--- |
| **Code Memory** | **已有** —— `graph_store.rs`(638 行) 符号 / 引用 / 调用图 | ✅ 直接检索 |
| **Error Memory** | **原料已有** —— `event_store` 审计日志 + `op_store` apply/rollback 快照 | ✅ **有自动写入触发点** |
| **Decision Memory** | **原料已有** —— 同上；rollback 事件天然是「此路不通」的记录 | ✅ **有自动写入触发点** |
| Session Memory | **原料已有** —— `session_store` | ✅ 直接检索 |
| Project / Architecture Memory | 需新建 | ⏸ 由 10.1 的指令文件先行承载 |
| User Preference | 需新建 | ⏸ 后置 |

**两条范围约束：**
1. **Vector Index 不是 day-one。** 代码检索上 CodeGraph 结构化查询 + 已有 `search.rs`(313 行) 通常胜过 embedding。
   向量的价值集中在 Decision / Error 这类自然语言记录上 —— 属本阶段后半段的可选项，不是基座。
2. **只做有自动写入触发点的记忆类型。** Error / Decision 有强制写入路径（rollback 事件、commit）；
   Project / Architecture / UserPreference 靠人工维护，无强制写入路径的记忆库会腐坏成噪声。
   而用户想要的「这个 bug 上次怎么解决的」「这个模块不能动」恰好落在有触发点的那两类上，砍到两类不影响效果。

#### 10.3 Skill（D4 落地：Prompt-first）

```
Skill = Instructions + Workflow + Tool Bindings     (声明式,无需编译)
```

**格式演进（同一阶段内递进，不占用额外 Phase）：**

```
级别 1   SKILL.md                        ← frontmatter 承载 name / description / tool-bindings
级别 2   SKILL.md + bundled 资产          ← 仅在真正需要脚本 / 参考文档时才出现第二个文件
级别 3   SKILL.md + WASM Tool 引用        ← 随 Phase 12 提供新 Tool 自然解锁
```

> **元数据放 frontmatter，不单独开 `manifest.yaml`。** name / description / tool-bindings 全部写在 `SKILL.md` 的 frontmatter 里，
> 只有真正存在 bundled 资产时才出现第二个文件 —— 一个 Skill 两个文件是可以避免的格式 churn。

**硬约束（安全边界，必须在此阶段确立）：**

> **Skill 只能绑定「已安装且已授权」的 Tool。Binding 是引用，不是打包 —— Skill 不得携带、也不得触发安装任何 Plugin。**

若安装 Skill 可顺带拉入 WASM 能力，Skill 即成为授权面（装一个 `docker.skill` 等于授予容器操作权限），构成供应链风险。
确立此约束后，Phase 6-A 加固后的 ToolRuntime 仍是唯一授权权威。

**预期形态举例：**

| 无需系统能力 → 纯 Skill，直接加载不编译 | 需真实系统能力 → Skill 绑定 Tool / MCP / WASM |
| :--- | :--- |
| `flutter-ui.skill`<br>`code-review.skill`<br>`springboot.skill`<br>`mysql-optimization.skill` | `docker.skill`<br>`kubernetes.skill`<br>`database.skill`<br>`android.skill`<br>`browser.skill` |

#### 10.4 MCP 接入
MCP 本质是「又一个 Tool Provider」，故不单列阶段，随本阶段的检索层一并接入 ToolRuntime：
发现的 MCP Tool 与 Core Tool 走同一套权限评级与审批路径（Phase 6-A 的加固对其同等生效）。

---

### 🔹 Phase 11: Cross-platform Release

#### 11.1 跨平台打包矩阵（`scripts/`）
- **Linux (`build_linux_release.sh`)**：编译 `libcodelite.so` 与 `code-lite-app` → Flutter Linux Desktop Release → 产出 `.AppImage` 与 Debian `.deb`；
- **Windows (`build_windows_release.bat`)**：编译 `codelite.dll` 与 `code-lite-app.exe` → Flutter Windows Desktop Release → 产出便携 ZIP 与 `.msi` / InnoSetup 安装引导。

#### 11.2 自动增量更新（D3 落地：分平台差异化）

> ⚠️ **原「差分只更新 `libcodelite.dylib` / `.so` / `.dll`」方案在 macOS 上不可行**：
> 替换已签名 bundle 内的动态库会**破坏 code signature**，导致 notarization 失效、Gatekeeper 拒绝启动。

| 平台 | 策略 |
| :--- | :--- |
| **macOS** | 整包替换 + `.app` 级二进制差分（Sparkle 模式），保持签名完整 |
| **Windows / Linux** | 组件级差分（`.dll` / `.so` / 前端资源） |
| 共通 | 启动时检查发布渠道 `version.json`；后台就绪后提示「一键重启以应用更新」 |

> **更新单元取决于 D1'**：FFI 为唯一激活 Adapter，故更新对象是 `.app` 内嵌的动态库与前端资源，不含独立 sidecar 进程。

---

### 🔹 Phase 12: WASM Plugin Ecosystem

> **硬依赖 Phase 6-A。** 理由：**Phase 12 的安全上限 ≡ Tool Runtime 的安全上限**。
> 在网关封闭化之前开放第三方插件，等于把逃逸能力直接授予外部代码。

```
Plugin = Runtime Capability     (可执行,需沙箱,信任模型 = 第三方不可信代码)
```

#### 12.1 WASM 插件沙箱运行时（`crates/code-lite-plugin`）
- 基于 `wasmtime` 构建宿主调用规范；插件可由 Rust / Zig / C / AssemblyScript 编译为 `.wasm`；
- 导出标准 Host API：`codelite_api_read_buffer`、`codelite_api_get_diagnostics`、`codelite_api_register_tool`；
- **全部 Host API 必须经由加固后的 Tool Runtime，不得旁路。**

#### 12.2 Tool Runtime 开放与插件市场
- 插件可向 `ToolRuntime` 注入受控新能力：SQL 连接器（`mysql_query` / `postgres_explain`）、Docker / Kubernetes 编排、自定义 Linter 规则包；
- 注入的 Tool 自动纳入权限评级与审批路径；
- 完成后，Phase 10 的 Skill 即可通过 Tool Binding **引用**（而非携带）这些能力，达成 D4 的级别 3。

---

## 7. 依赖关系与推进顺序

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Phase 6  安全底座与工程前置                                    [阻塞性]        │
│   A. ToolRuntime 路径包含性 + 权限分级        ──► 阻塞 Phase 12               │
│   B. LLM 换 ureq (key 移出 argv) + 结构化输出 ──► 阻塞 Phase 8.2 / 9.1        │
│   C. Core API 契约 + codegen (TOML/JSON-RPC)  ──► 阻塞 Phase 7 / 8 / 11       │
│   D. crates/*/tests/ 集成测试骨架             ──► 阻塞 Phase 9                │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Phase 7  Editable Editor Kernel [已完成 ✅ 2026-09-09]                         │
│   光标 / 选区 / IME / per-pane 滚动;  耗时调用移出主 isolate                    │
│                                               ──► 阻塞 Phase 8.2 / 8.3       │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Phase 8  IDE Core                                             [P0]           │
│   8.1 LSP Supervisor (范围缩减 · 补 capabilities + 增量同步) [已完成 ✅ 2026-09-09] │
│   8.2 Ghost Text / FIM  [已完成 ✅ 2026-09-09]                               │
│   8.3 Tabs / Split / Git Gutter                                              │
│   理由: 直接决定开发者日常敲代码的第一感官与沉浸感。                             │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Phase 9  Agent Runtime + Multi-file + Worktree                [P1]           │
│   9.1 两条边: 模型驱动 Planner / Observation 回流  (其余 6 项重构归位)          │
│   9.2 拓扑排序多文件规划    9.3 Worktree 沙箱    9.4 细粒度回滚                 │
│   注: 9.3 可与 8.3 并行 —— git.rs 已 shell out 到 git,近乎零架构成本           │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Phase 10  检索 / 上下文层                                      [P1]           │
│   10.1 项目指令文件(约 50 行,优先) → 10.2 Memory(仅 Error/Decision)           │
│   → 10.3 Skill(Prompt-first)      → 10.4 MCP                                 │
│   核心: Memory 检索与 Skill 选择共用同一套 description 匹配机器                 │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Phase 11  Cross-platform Release                              [P2]           │
│   理由: 打通 Windows / Linux 分发通道,建立用户体量。                            │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Phase 12  WASM Plugin Ecosystem                    [P3 · 硬依赖 6-A]         │
│   理由: 生态护城河需建立在已有用户体量 + 已封闭安全网关之上。                     │
└──────────────────────────────────────────────────────────────────────────────┘
```

**为何 11 先于 12**：没有 Windows / Linux 就没有用户体量，而没有用户体量的插件市场是空的。先打开分发通道。

---

## 8. 尚未排期项（有意保留为 open question）

| 项 | 未排期原因 |
| :-- | :--- |
| Plugin Marketplace | 需先有 Phase 11 的用户体量与 Phase 12 的插件运行时；分发与审核策略未定 |
| Remote Development / 容器 Agent | D1' 已为其留出 Remote Adapter 槽位，但无真实需求前不实现 |
| Vector Index | 见 10.2 —— 仅在 Decision / Error 记忆的自然语言检索被证明不足时引入 |
| Project / Architecture / UserPreference Memory | 见 10.2 —— 缺少自动写入触发点，需先找到触发路径 |
| FFI NativePort 推送 | Phase 6-C 的 Adapter 抽象已使其成为纯内部优化，可在任意时点替换，不改 UI 代码 |

---

## 附录：核对方法

本文档全部基线结论于 2026-09-09 对仓库 `main` 分支实际代码逐条核对，覆盖：
`Cargo.toml` workspace 依赖、`crates/` 全部 8 个 crate 的源码与测试（50 个 `#[test]`）、
`apps/code_lite_ui/lib/` 全部 Dart 源码（含 FFI binding 与 HTTP client 两条传输路径）、
根目录指令文件（`AGENTS.md` / `GEMINI.md`）、`scripts/` 与 `dist/` 产物布局。
表中结论均标注 `文件:行号`，可直接复核。

**本文档为规划修订，未修改任何代码。**
