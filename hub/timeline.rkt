#lang racket/base

;; Server-rendered timeline page for the hub: devices, snapshot histories,
;; and repository size. Plain HTML, zero client JS, auto-refresh. The token
;; travels as ?token= on the URL for browser access.

(require json
         racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         "../app/format.rkt")

(provide timeline-html)

(define (human n)
  (cond
    [(< n 1024) (format "~a B" n)]
    [(< n (expt 1024 2)) (~a (~r (/ n 1024.0) #:precision '(= 1)) " KB")]
    [(< n (expt 1024 3)) (~a (~r (/ n (expt 1024 2)) #:precision '(= 1)) " MB")]
    [(< n (expt 1024 4)) (~a (~r (/ n (expt 1024 3)) #:precision '(= 1)) " GB")]
    [else (~a (~r (/ n (expt 1024 4)) #:precision '(= 1)) " TB")]))

;; UTC ISO -> "yyyy-MM-dd HH:mm"
(define (pretty-time iso)
  (define m (regexp-match #px"^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2})" iso))
  (if m (string-join (cdr m) "-") iso))

(struct device-timeline (id snapshots total-bytes) #:transparent)

(define (load-timelines root)
  (define dev-dir (build-path root "devices"))
  (for/list ([d (in-list (if (directory-exists? dev-dir)
                             (sort (directory-list dev-dir)
                                   string<?
                                   #:key path->string)
                             (list)))]
             #:do [(define dev-path (build-path dev-dir d))]
             #:when (directory-exists? dev-path))
    (define snaps-dir (build-path dev-path "snapshots"))
    (define raw
      (if (directory-exists? snaps-dir)
          (sort (directory-list snaps-dir) string<? #:key path->string)
          (list)))
    (define valid
      (for/list ([f (in-list raw)]
                 #:when (string-suffix? (path->string f) manifest-suffix))
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (with-input-from-file (build-path snaps-dir f) read-json))))
    (define good (filter values valid))
    (device-timeline
     (path->string d)
     good
     (for/sum ([m (in-list good)])
       (for/sum ([f (in-list (hash-ref m 'files (list)))])
         (hash-ref f 'size 0))))))

(define (repo-blob-stats root)
  (define blobs (build-path root "blobs" "sha256"))
  (if (directory-exists? blobs)
      (for/fold ([count 0] [bytes 0])
                ([shard (in-list (directory-list blobs))]
                 #:when (directory-exists? (build-path blobs shard))
                 [f (in-list (directory-list (build-path blobs shard)))])
        (define p (build-path blobs shard f))
        (values (add1 count) (+ bytes (file-size p))))
      (values 0 0)))

(define (esc s)
  (string-replace
   (string-replace
    (string-replace (string-replace s "&" "&amp;") "<" "&lt;")
    ">" "&gt;")
   "\"" "&quot;"))

(define (snapshot-row m)
  (apply string-append
         (list
          "<tr><td>" (esc (pretty-time (hash-ref m 'created_at ""))) "</td>"
          "<td>" (esc (hash-ref m 'account "")) "</td>"
          "<td>" (number->string (length (hash-ref m 'files (list)))) "</td>"
          "<td>" (human (for/sum ([f (in-list (hash-ref m 'files (list)))])
                          (hash-ref f 'size 0)))
          "</td></tr>")))

(define (device-section t)
  (define snaps (device-timeline-snapshots t))
  (apply string-append
         (list
          "<section class=\"device\"><h2>" (esc (device-timeline-id t)) "</h2>"
          "<p class=\"meta\">" (number->string (length snaps))
          " snapshots - " (human (device-timeline-total-bytes t)) "</p>"
          "<table><tr><th>time</th><th>account</th><th>files</th><th>size</th></tr>"
          (string-join (map snapshot-row (reverse snaps)) "")
          "</table></section>")))

(define (timeline-html root token)
  (define timelines (load-timelines root))
  (define-values (blob-count blob-bytes) (repo-blob-stats root))
  (define device-sections
    (if (null? timelines)
        "<p class=\"empty\">No devices have pushed snapshots yet.</p>"
        (string-join (map device-section timelines) "\n")))
  (apply string-append
         (list
          "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">"
          "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
          "<meta http-equiv=\"refresh\" content=\"60\">"
          "<title>Keepsake Hub</title><style>"
          "body{font:15px/1.6 ui-sans-serif,-apple-system,'PingFang SC','Segoe UI',sans-serif;"
          "background:#faf7f2;color:#1f1d1a;max-width:900px;margin:0 auto;padding:24px}"
          "h1{font-size:26px;margin:0 0 4px}h2{font-size:18px;margin:24px 0 10px}"
          ".meta{color:#6b6660;font-size:13px;margin:0 0 12px}"
          ".stats{color:#6b6660;font-size:13px;margin:0 0 20px}"
          "table{width:100%;border-collapse:collapse;font-size:14px}"
          "th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #e8e2d9}"
          "th{color:#6b6660;font-weight:600}"
          ".empty{color:#6b6660}"
          ".footer{margin-top:36px;color:#6b6660;font-size:12px;"
          "border-top:1px solid #e8e2d9;padding-top:12px}"
          "@media (prefers-color-scheme: dark){"
          "body{background:#1f1d1a;color:#f0ede8}"
          ".meta,.stats,.empty,.footer{color:#a8a29a}"
          "th,td{border-bottom-color:#3a3835}}"
          "</style></head><body>"
          "<h1>Keepsake Hub</h1>"
          "<p class=\"stats\">repository " (human blob-bytes)
          " - " (number->string blob-count)
          " blobs - refreshes every 60s</p>"
          device-sections
          "<p class=\"footer\">Keepsake Hub - read-only timeline - blobs and"
          " manifests are available through the API after token auth.</p>"
          "</body></html>")))
