# AGENTS.md

指引给 AI agent（及开发者）：如何理解、构建、改动 Keepsake。

## 这是什么

Keepsake 是桌面微信数据的备份工具——「微信数据目录的 Time Machine」：发现本机微信账号目录，定期拍内容寻址的增量快照到本地卷 / SMB 挂载 / 自托管 hub，任何快照可一键恢复回原位。核心情绪价值：**几年聊天记录的唯一副本，从此有一份任意时点可回得去的保险。**

技术形态遵循 [Rivet](https://github.com/turinglambdaai/rivet) 线：**Racket 引擎 + 各平台第一方原生 UI**。当前是 CLI（`app/cli.rkt`）；M0 里程碑加原生壳（macOS SwiftUI / Windows WinUI 3 / Linux GTK4），M1 加自托管 hub（Docker）。产品灵魂是**苹果级 UI 品质**——壳的每一像素都要按这个标准做。

| 层 | 技术 | 目录 | 状态 |
|---|---|---|---|
| 引擎（发现/切块/仓库/快照） | Racket 9.3 | `app/` | ✅ 19 测试全绿 |
| CLI | Racket | `app/cli.rkt` | ✅ discover/snapshot/status |
| 原生壳 | SwiftUI / WinUI 3 / GTK4 | `macos-host/` 等（待建） | M0 后续 |
| Hub | Docker 容器（Racket 服务 + Web UI） | （待建） | M1 |

## 硬边界（本仓库存在的合法性根基，任何改动不得越过）

1. **零解密**：不提取密钥、不解密 SQLCipher 数据库、不 hook/注入微信进程。只做文件级操作。2026-01 腾讯对解密类工具的批量 DMCA 执法是本产品的立项前提——这条线是产品定义，不是合规顾虑。
2. **不做内容功能**：不渲染聊天、不解析消息、不出「按联系人备份」这类需要读库的功能。查看与恢复走微信本体。
3. **手机端不做 agent**：iOS/iPadOS/Android 沙盒物理不可达，文档只能说「用微信自带迁移功能进桌面端」。
4. 任何 PR/改动触碰以上三条，无论实现多优雅，直接拒绝。

## 架构速览

| 模块 | 文件 | 说明 |
|---|---|---|
| 格式常量 | `app/format.rkt` | 仓库布局版本，与 docs/repo-format.md 同步 |
| manifest | `app/manifest.rkt` | 快照清单的 jsexpr 契约与原子写 |
| 切块 | `app/chunk.rkt` | 媒体整文件 + SQLite 按自身页大小页级切（页大小从 db 头读） |
| 发现 | `app/discover.rkt` | macOS / Windows（4.x+3.x 布局）/ Linux 路径 |
| 仓库 | `app/repo.rkt` | sha256 blob 池 + per-device manifest，原子写，无锁并发 |
| 快照 | `app/snapshot.rkt` | walk（跳 symlink）→ chunk → 补缺失 blob → 写 manifest |
| CLI | `app/cli.rkt` | discover / snapshot / status |

**`docs/repo-format.md` 是核心资产与契约**：改仓库布局 / manifest schema 之前，先改这份文档并 bump `format-version`，代码跟着文档走，不允许文档落后于实现。

## 快速命令

```bash
raco pkg install --auto --no-docs crypto   # 唯一依赖（首次）
raco test tests/                            # 必须全绿
racket app/cli.rkt discover                 # 冒烟：找账号（没装微信输出提示，属正常）
```

坑（已踩过）：`crypto-factories` 必须在模块顶层激活 libcrypto 工厂；9.3 的 `directory-list` 无 `#:link-mode?`；`hash-update` 的 updater 是一元的。

## 约定

- README.md（英）与 README.zh-CN.md（中）同步改；网址只出现在语言行 🌐。
- CHANGELOG.md 保持 Keep-a-Changelog 风格；新栈产品首发 1.0.0。
- 平台路径相关改动必须带平台矩阵测试（CI 覆盖 ubuntu/macos/windows）。
- 引擎不依赖 rivet；M0 壳开工后遵循 Rivet 工作约定（开发前 pull 本地 rivet、清 `compiled/` 再 `raco setup`）。
- blob 内容寻址逻辑（`app/chunk.rkt`、`app/repo.rkt`）是数据兼容性的根：改动前先读 repo-format.md 的 Compatibility rules 一节。
- **UI 是产品之魂**：壳相关改动必须达到 Apple 级设计标准（参照 fulcrum 的 Raycast 对标线），不达标的 UI 等于没做。
