# Keepsake

桌面微信数据的时光机。Keepsake 像 macOS 给磁盘拍快照那样给你的微信账号目录拍快照——去重、多版本、可恢复，**全程不读取、不解密、不触碰聊天内容**。

[![CI](https://github.com/turinglambdaai/keepsake/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/keepsake/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) ![Go](https://img.shields.io/badge/Go-1.23%2B-00ADD8?logo=go&logoColor=white)

[English](README.md) · **中文** · 🌐 [keepsake.jrtx.site](https://keepsake.jrtx.site)

## 为什么

微信不在服务器上保存聊天记录：一条消息只存在于收到它的设备上。这让本地的 `xwechat_files` 目录成为几年对话的**唯一**副本——而微信没有给你任何管理它的工具。一次磁盘损坏、一次失败的升级、一次手滑的清理，历史就没了。

Keepsake 接过这份责任，只守一条诚实的规矩：**只处理文件，不处理内容。** 查看和恢复都走微信本体；Keepsake 保证任意时间点的副本永远拿得到。

## 工作方式

- **发现**——定位微信账号目录（macOS、Windows、Linux），报告每个账号有什么、有多大。
- **快照**——遍历账号目录，把文件切成内容寻址的块（媒体文件整文件一块，SQLite 数据库按自身页大小切块，让相邻快照共享所有未变化的页），只上传仓库里缺的块，并写一份 JSON manifest。
- **恢复**（开发中）——把任意快照物化回原位；永远先给当前数据拍一份「恢复前保险快照」，再动手。

仓库是一个平铺、自描述的目录树——没有数据库、没有私有打包格式。确切格式见 [`docs/repo-format.md`](docs/repo-format.md)；就算本项目明天消失，你用 `jq` 和 `cp` 也能把任何快照拼回来。

## 设计原则

1. **零解密。** 不提取密钥、不解密数据库、不注入进程——这条线永远不会碰。这正是 Keepsake 可以放心开发、分发、依赖的原因。
2. **可逃生的格式。** 项目没了，仓库还在。
3. **Hub 永远不是单点。** Agent 可以把同样的仓库布局直接写到本地卷或 SMB 挂载；自托管 hub（Docker，规划中）只增加调度、GC、校验和多设备 UI。
4. **恢复永不破坏。** 每次恢复都以当前数据的保险快照开场。
5. **桌面端就是全部世界。** iOS/iPadOS/Android 把微信数据锁在沙盒里，够不着；手机历史通过微信自带的「聊天记录迁移」进入桌面端后，再被快照覆盖。

## 状态与路线图

早期开发中。Agent CLI 已端到端可用（发现、快照、去重）；1.0 之前格式可能微调。

- [x] M0 核心——发现、切块、内容寻址仓库、manifest
- [ ] M0 ——恢复流、定时快照
- [ ] M1 ——自托管 hub（Docker）：REST API、多设备时间线、Web UI
- [ ] M2 ——Windows/Linux agent 加固、hub 发布

## 从源码构建

```bash
go build ./...          # 或: go install github.com/turinglambdaai/keepsake/cmd/agent@latest
go test ./...           # 必须全绿

go run ./cmd/agent discover                     # 找到微信账号
go run ./cmd/agent snapshot --repo ~/backup     # 第一次快照
go run ./cmd/agent snapshot --repo ~/backup     # 再来一次：近乎零上传
go run ./cmd/agent status --repo ~/backup       # 备份了什么、何时、在哪
```

macOS 提示：读取微信容器目录需要给终端（或打包后的应用）授权一次**完全磁盘访问权限**。

## 许可证

[MIT](LICENSE)
