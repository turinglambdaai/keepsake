#lang racket/base

;; Shared constants of the keepsake repository format (docs/repo-format.md).
;; The format is the core asset: change the doc first, then this module,
;; then the code that follows it.

(provide format-version
         marker-name
         blob-dir
         manifest-suffix)

;; On-disk repository layout version.
(define format-version 1)

;; File that marks a directory as a keepsake repository.
(define marker-name "repo.json")

;; Blob store fanout root (under the repo root).
(define blob-dir "blobs/sha256")

;; Snapshot manifest filename suffix.
(define manifest-suffix ".manifest.json")
