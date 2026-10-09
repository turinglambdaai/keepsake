# Contributing

## Ground rule

Keepsake is **file-level only**: no key extraction, no database decryption,
no process injection, no message-content features. PRs crossing this line are
closed on sight regardless of quality. See [AGENTS.md](AGENTS.md) for the
full boundary.

## Development

```bash
go test ./...     # must be green
go vet ./...      # must pass
gofmt -l .        # must print nothing
```

- Changes to the repository layout or manifest schema go to
  [`docs/repo-format.md`](docs/repo-format.md) **first**, with the
  corresponding `FormatVersion` bump, then the code.
- Platform-specific paths need the platform matrix to stay green in CI
  (ubuntu / macOS / Windows).
- `README.md` and `README.zh-CN.md` are updated together.
