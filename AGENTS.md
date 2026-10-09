# AGENTS.md

指引给 AI agent（及开发者）：如何理解、构建、改动 Keepsake。

## 这是什么

Keepsake 是桌面微信数据的备份工具——「微信数据目录的 Time Machine」：发现本机微信账号目录，定期拍内容寻址的增量快照到本地卷 / SMB 挂载 / 自托管 hub，任何快照可一键恢复回原位。核心情绪价值：**几年聊天记录的唯一副本，从此有一份任意时点可回得去的保险。**

技术形态：**Go 单二进制**（agent CLI 起步，后续加托盘壳）+ 自托管 hub（Docker，M1）。不依赖微信、不注入进程、不读消息内容——见下方硬边界。

## 硬边界（本仓库存在的合法性根基，任何改动不得越过）

1. **零解密**：不提取密钥、不解密 SQLCipher 数据库、不 hook/注入微信进程。只做文件级操作。2026-01 腾讯对解密类工具的批量 DMCA 执法是本产品的立项前提——这条线是产品定义，不是合规顾虑。
2. **不做内容功能**：不渲染聊天、不解析消息、不出「按联系人备份」这类需要读库的功能。查看与恢复走微信本体。
3. **手机端不做 agent**：iOS/iPadOS/Android 沙盒物理不可达，文档只能说「用微信自带迁移功能进桌面端」。
4. 任何 PR/改动触碰以上三条，无论实现多优雅，直接拒绝。

## 架构速览

| 组件 | 位置 | 状态 |
|---|---|---|
| agent CLI | `cmd/agent/` | discover / snapshot / status 可用；restore 待做 |
| 发现 | `internal/discover/` | macOS / Windows（4.x + 3.x 布局）/ Linux |
| 切块 | `internal/chunk/` | 媒体整文件 + SQLite 按自身页大小页级切 |
| 仓库 | `internal/repo/` | 内容寻址 blob + manifest，原子写，无锁并发 |
| 快照 | `internal/snapshot/` | walk → chunk → 补缺失 blob → 写 manifest |
| hub | （M1，未开工） | Docker：REST + Web UI + 调度/GC/校验 |

**`docs/repo-format.md` 是核心资产与契约**：改仓库布局 / manifest schema 之前，先改这份文档并 bump 对应 `FormatVersion`，代码跟着文档走，不允许文档落后于实现。

## 快速命令

```bash
go test ./...      # 全部必须绿
go vet ./...       # 提交前必过
gofmt -l .         # 必须无输出
go run ./cmd/agent discover    # 冒烟：找账号（本机没装微信会报 ErrNotFound，属正常）
```

## 约定

- README.md（英）与 README.zh-CN.md（中）同步改；头部不放仓库外的杂项链接，网址只出现在语言行 🌐。
- CHANGELOG.md 保持 Keep-a-Changelog 风格；新栈产品首发 1.0.0。
- 平台路径相关改动必须带平台矩阵测试（CI 覆盖 ubuntu/macos/windows）。
- blob 内容寻址逻辑（`internal/chunk`、`internal/repo`）是数据兼容性的根：改动前先读 repo-format.md 的 Compatibility rules 一节。
