# Security Policy

## Scope

Keepsake handles **file-level copies only**. It does not decrypt, extract
keys from, or attach to the WeChat process; the repository contains only
opaque file chunks and JSON manifests.

## Reporting a vulnerability

Open a private security advisory via
[GitHub Security Advisories](https://github.com/turinglambdaai/keepsake/security/advisories/new).

Targets of highest interest:

- Repository integrity (a crafted manifest or blob escaping the repository
  root — path traversal in `devices/<id>/` or blob paths)
- Restore correctness (a snapshot overwriting data outside the account
  directory)
- Anything that would cause Keepsake to read or expose message *content*
  (out of scope by design — if you found a way, that is a serious bug)

## Non-goals

Features that require decryption or process instrumentation are refused by
design; please do not report their absence as vulnerabilities.
