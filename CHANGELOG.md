# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/). Versioning
starts at 0.1.0, not 1.0.0: per the Rivet family policy a product stays in
the 0.x epoch until it has earned a 1.0, so the first public release is 0.1.0.

## [0.1.0] - 2026-10-14

### Changed

- Rewrote the engine from Go to Racket (same repository format, same
  behavior): Apple-grade native hosts are the Rivet line's whole point, and
  a Go engine would have forced a second stack and a never-tested Go↔Swift
  bridge. The Go implementation survives in git history as a format
  reference.

### Added

- Native macOS shell (SwiftUI over the embedded engine): account sidebar
  with real sizes, snapshot timeline, snapshot/restore actions with a
  destructive-action confirmation that explains the pre-restore safety
  snapshot, and an auto-snapshot interval picker (off / 15m / 1h / 6h / 1d).
- Keepsake Hub: a self-hosted HTTP facade over the repository directory
  (same format as local volumes) — blob upload/download, manifest writes,
  per-device snapshot listings, bearer-token auth, path-traversal rejection,
  a server-rendered auto-refreshing web timeline (browser auth via
  `?token=`), and a Dockerfile. Routing is a pure function under test.
- Hub license gate (MT Photos-style honesty scheme): 30-day trial from the
  repository's creation stamp, Ed25519-signed KS1 activation tokens verified
  fully offline. An expired hub refuses new writes (402) but serves reads
  and restores forever — agents fail over to directory writes, so no data
  is ever held hostage.
- Repository hygiene tools: `hub/gc.rkt` sweeps unreferenced blobs past a
  grace window (protecting in-flight uploads); `hub/verify.rkt` audits
  every manifest and referenced blob (parse + hash), reporting corruption
  by name. Both pure-directory tools, unit tested.
- Agent speaks HTTP: `--repo http://host:port` turns any command into a hub
  client (blobs and manifests push, restores pull) while `--repo <dir>`
  keeps writing local/SMB volumes — same format either way. Hub unreachable
  fails fast at startup with a hint, never mid-snapshot.
- Restore flow: restore by snapshot index (`restore-snapshot`), two-phase
  materialization (pre-flight blob verification before the target is
  touched, written-size checks after), path-safety rejection, best-effort
  mode/mtime restore, and a CLI that always takes an automatic pre-restore
  safety snapshot first. macOS TCC denials surface as an actionable Full
  Disk Access hint instead of a bare "Operation not permitted".
- Agent CLI (`racket app/cli.rkt`): `discover`, `snapshot`, `status` —
  locates WeChat account directories on macOS / Windows / Linux, chunks
  files content-addressed (whole-file for media, page-aligned for SQLite
  databases), uploads only missing blobs, and writes JSON snapshot
  manifests.
- Keepsake repository format v1: content-addressed blob store, per-device
  manifest namespaces, atomic writes, no locking required — specified in
  `docs/repo-format.md`.
- Cross-platform CI (ubuntu / macOS / Windows) and bilingual README.
