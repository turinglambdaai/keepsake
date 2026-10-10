# Keepsake

桌面微信数据的时光机。Keepsake 像 macOS 给磁盘拍快照那样给你的微信账号目录拍快照——去重、多版本、可恢复，**全程不读取、不解密、不触碰聊天内容**。

[![CI](https://github.com/turinglambdaai/keepsake/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/keepsake/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) ![Racket](https://img.shields.io/badge/Racket-9.3-9D00FF?logo=racket&logoColor=white)

[English](README.md) · **中文**

## 为什么

微信不在服务器上保存聊天记录：一条消息只存在于收到它的设备上。这让本地的 `xwechat_files` 目录成为几年对话的**唯一**副本——而微信没有给你任何管理它的工具。一次磁盘损坏、一次失败的升级、一次手滑的清理，历史就没了。

Keepsake 接过这份责任，只守一条诚实的规矩：**只处理文件，不处理内容。** 查看和恢复都走微信本体；Keepsake 保证任意时间点的副本永远拿得到。

## 工作方式

- **发现**——定位微信账号目录（macOS、Windows、Linux），报告每个账号有什么、有多大。
- **快照**——遍历账号目录，把文件切成内容寻址的块（媒体整文件一块，SQLite 数据库按自身页大小切块，让相邻快照共享所有未变化的页），只上传仓库里缺的块，并写一份 JSON manifest。可选的定时间隔让应用开着时就自动持续快照。
- **恢复**——把任意快照物化回原位；永远先给当前数据拍一份「恢复前保险快照」，再动手。

仓库是一个平铺、自描述的目录树——没有数据库、没有私有打包格式。确切格式见 [`docs/repo-format.md`](docs/repo-format.md)；就算本项目明天消失，你用 `jq` 和 `cp` 也能把任何快照拼回来。

## 设计原则

1. **零解密。** 不提取密钥、不解密数据库、不注入进程——这条线永远不会碰。这正是 Keepsake 可以放心开发、分发、依赖的原因。
2. **可逃生的格式。** 项目没了，仓库还在。
3. **Hub 永远不是单点。** Agent 可以把同样的仓库直接写到本地卷或 SMB 挂载；自托管 hub 只增加调度、GC、校验和多设备网页视图。
4. **恢复永不破坏。** 每次恢复都以当前数据的自动保险快照开场。
5. **桌面端就是全部世界。** iOS/iPadOS/Android 把微信数据锁在沙盒里，够不着；手机历史通过微信自带的「迁移到电脑」进入桌面端后，再被快照覆盖。

## 自托管 Hub

把 agent 指向一个 hub，多台机器备份进同一仓库，在浏览器里查看所有时间线：

```bash
docker build -t keepsake-hub hub/
docker run -d -p 8080:8080 -v /mnt/user/keepsake:/data \
  -e KEEPSAKE_HUB_TOKEN=choose-a-secret keepsake-hub

racket app/cli.rkt snapshot --repo http://nas:8080     # 走 HTTP 推送
```

Hub 在同一仓库格式之上增加远程访问、网页时间线、license 门槛、GC 与校验——格式本身不依赖它的存活。

Hub 自首次启动起有 30 天免费试用。试用期结束后它**永远**继续提供读取和恢复服务、**绝不拿你的数据做人质**——只有向 hub 的新写入需要激活，而 agent 随时可以降级为直接写挂载卷上的仓库。激活是完全离线的签名 token（`POST /api/license`）。

## 状态与路线图

当前可用：发现、自动去重快照、定时快照、带保险快照的恢复、hub（REST API、网页时间线、GC、校验、license 门槛）以及 macOS SwiftUI 壳。1.0 之前格式可能微调。

- [x] M0——发现、切块、内容寻址仓库、manifest、恢复、定时快照
- [x] M1 核心——hub REST API、多设备网页时间线、GC、校验、license 门槛、agent HTTP 推送
- [ ] M1——hub 打磨：签发工具、网页 UI 细化
- [ ] M2——Windows/Linux 原生宿主、hub 正式发布（签名镜像）

## 从源码构建

```bash
raco pkg install --auto --no-docs crypto   # 唯一依赖
raco test tests/                           # 必须全绿

racket app/cli.rkt discover                    # 找到微信账号
racket app/cli.rkt snapshot --repo ~/backup    # 第一次快照
racket app/cli.rkt snapshot --repo ~/backup    # 再来一次：近乎零上传
racket app/cli.rkt status --repo ~/backup      # 备份了什么、何时、在哪
racket app/cli.rkt restore --repo ~/backup --list                  # 挑一个时间点
racket app/cli.rkt restore --repo ~/backup --account wxid_x \
      --index 1 --to /path/to/account                              # 回到那一刻
```

恢复永远以当前目录的自动保险快照开场——回退不可能让你丢数据。

Keepsake 遵循 [Rivet](https://github.com/turinglambdaai/rivet) 架构：Racket 引擎驱动第一方原生宿主。CLI 是今天的 agent 形态，macOS 原生壳开发中；自托管 hub 容器见 [`hub/Dockerfile`](hub/Dockerfile)。

macOS 提示：读取微信容器目录需要给终端（或打包后的应用）授权一次**完全磁盘访问权限**。

## 许可证

[MIT](LICENSE)
