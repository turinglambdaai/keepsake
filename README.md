# Keepsake

A time machine for your desktop WeChat data. Keepsake snapshots your WeChat
account directory the way macOS snapshots your disk — deduplicated, versioned,
restorable — **without ever reading, decrypting, or touching the contents**.

[![CI](https://github.com/turinglambdaai/keepsake/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/keepsake/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) ![Racket](https://img.shields.io/badge/Racket-9.3-9D00FF?logo=racket&logoColor=white)

**English** · [中文](README.zh-CN.md)

## Why

WeChat keeps no server-side archive of your chats: a message exists only on
the devices that received it. That makes your local `xwechat_files` directory
the *only* copy of years of conversations — and WeChat gives you no tool to
manage it. One wiped disk, one bad update, one misclicked cleanup and the
history is gone.

Keepsake takes over that responsibility with one honest rule: **it handles
files, never content.** View and restore through WeChat itself; Keepsake
makes sure a copy from any point in time is always within reach.

## How it works

- **Discover** — locates WeChat account directories (macOS, Windows, Linux),
  reports what each account holds and how big it is.
- **Snapshot** — walks the account directory, splits files into
  content-addressed chunks (whole-file for media, page-aligned for SQLite
  databases so unchanged pages dedupe across snapshots), uploads only what
  the repository is missing, and writes a JSON manifest. An optional
  interval keeps snapshotting automatically while the app is open.
- **Restore** — materializes any snapshot back into place, always after
  taking a safety snapshot of the current data first.

The repository is a plain, self-describing directory tree — no database, no
proprietary packing. See [`docs/repo-format.md`](docs/repo-format.md) for the
exact format; you can reassemble every snapshot with `jq` and `cp`.

## Design principles

1. **Zero decryption.** No key extraction, no database decryption, no process
   injection — the line this project will never cross. It is what makes
   Keepsake safe to build, distribute, and depend on.
2. **Escapable format.** If Keepsake vanished, your repository survives.
3. **The hub is never a single point of failure.** Agents can write the same
   repository layout straight to a local volume or SMB mount; a self-hosted
   hub only adds scheduling, GC, verification, and a multi-device web view.
4. **Restore never destroys.** Every restore begins with a safety snapshot of
   the current data.
5. **Desktops are the whole world.** iOS/iPadOS/Android sandbox WeChat data
   beyond reach; phone history joins the backup through WeChat's own
   *migrate chat history* flow into a desktop client, and gets snapshotted
   from there.

## Self-hosted hub

Point agents at a hub to back up multiple machines into one repository and
watch every timeline from a browser:

```bash
docker build -t keepsake-hub hub/
docker run -d -p 8080:8080 -v /mnt/user/keepsake:/data \
  -e KEEPSAKE_HUB_TOKEN=choose-a-secret keepsake-hub

racket app/cli.rkt snapshot --repo http://nas:8080     # push over HTTP
```

The hub adds remote reach, a web timeline, license gating, GC and
verification on top of the same repository format — nothing in the format
depends on it staying up.

The hub is unlicensed for a 30-day trial from first start. After that it
keeps serving reads and restores forever and **never holds your data
hostage** — only new writes to the hub are gated, and agents can always
fail over to writing the repository directly on a mounted volume. Activation
is a fully-offline signed token (`POST /api/license`).

## Status & roadmap

Working today: discovery, snapshots with automatic dedupe, scheduled
snapshots, restore with safety snapshots, the hub (REST API, web timeline,
GC, verification, license gate), and the macOS SwiftUI shell. Expect
format-adjacent changes until 1.0.

- [x] M0 — discovery, chunking, content-addressed repository, manifests,
      restore, scheduled snapshots
- [x] M1 core — hub REST API, multi-device web timeline, GC, verification,
      license gate, agent HTTP push
- [ ] M1 — hub polish: activation tooling for vendors, web UI refinements
- [ ] M2 — Windows/Linux native hosts, hub release with signed images

## Build from source

```bash
raco pkg install --auto --no-docs crypto   # one dependency
raco test tests/                           # everything must stay green

racket app/cli.rkt discover                    # find WeChat accounts
racket app/cli.rkt snapshot --repo ~/backup    # first snapshot
racket app/cli.rkt snapshot --repo ~/backup    # again: near-zero upload
racket app/cli.rkt status --repo ~/backup      # what is backed up, when, where
racket app/cli.rkt restore --repo ~/backup --list                  # pick a point in time
racket app/cli.rkt restore --repo ~/backup --account wxid_x \
      --index 1 --to /path/to/account                              # back to that moment
```

Restores always begin with an automatic safety snapshot of the current
directory, so going back can never cost you data.

Keepsake follows the [Rivet](https://github.com/turinglambdaai/rivet)
architecture: a Racket engine behind first-party native hosts. The CLI is
today's agent form, with a native macOS shell in progress; a self-hosted hub
container ships from [`hub/Dockerfile`](hub/Dockerfile).

macOS note: reading WeChat's container directory requires granting the
terminal (or the packaged app) **Full Disk Access** once.

## License

[MIT](LICENSE)
