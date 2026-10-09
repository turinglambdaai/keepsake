# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/); versioning
starts at 1.0.0 for the first release.

## [Unreleased]

### Added

- Agent CLI with `discover`, `snapshot`, `status` commands: locates WeChat
  account directories on macOS / Windows / Linux, chunks files
  content-addressed (whole-file for media, page-aligned for SQLite
  databases), uploads only missing blobs, and writes JSON snapshot manifests.
- Keepsake repository format v1: content-addressed blob store, per-device
  manifest namespaces, atomic writes, no locking required — specified in
  `docs/repo-format.md`.
- Cross-platform CI (ubuntu / macOS / Windows) and bilingual README.
