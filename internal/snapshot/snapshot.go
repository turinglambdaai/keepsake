// Package snapshot turns a WeChat account directory into a repository
// snapshot: walk, chunk, upload missing blobs, write the manifest.
package snapshot

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/turinglambdaai/keepsake/internal/chunk"
	"github.com/turinglambdaai/keepsake/internal/discover"
	"github.com/turinglambdaai/keepsake/internal/manifest"
	"github.com/turinglambdaai/keepsake/internal/repo"
)

// Result reports what one snapshot run actually did — the numbers that make
// incremental behavior visible to the user.
type Result struct {
	Files         int   `json:"files"`
	TotalBytes    int64 `json:"total_bytes"`
	UploadedBlobs int   `json:"uploaded_blobs"`
	UploadedBytes int64 `json:"uploaded_bytes"` // new bytes that hit the repository
	DedupedBlobs  int   `json:"deduped_blobs"`
	DedupedBytes  int64 `json:"deduped_bytes"` // bytes already present, not re-uploaded
}

// Run snapshots the account directory into repo and returns the written
// manifest plus statistics.
func Run(r *repo.Repo, account discover.Account, deviceID string) (*manifest.Manifest, *Result, error) {
	res := &Result{}
	m := manifest.Manifest{
		FormatVersion: manifest.FormatVersion,
		DeviceID:      deviceID,
		Account:       account.ID,
		HostPlatform:  runtime.GOOS,
		CreatedAt:     time.Now().UTC(),
	}

	err := filepath.WalkDir(account.Path, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		// Never follow symlinks: WeChat data has none in practice, and
		// following them risks loops and escaping the account directory.
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}

		info, err := d.Info()
		if err != nil {
			return err
		}
		refs, err := chunk.PlanFile(path)
		if err != nil {
			return fmt.Errorf("chunk %s: %w", path, err)
		}

		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()

		for _, ref := range refs {
			exists, err := r.HasBlob(ref.Hash)
			if err != nil {
				return err
			}
			if exists {
				res.DedupedBlobs++
				res.DedupedBytes += ref.Size
				continue
			}
			buf := make([]byte, ref.Size)
			if _, err := f.ReadAt(buf, ref.Offset); err != nil {
				return fmt.Errorf("read %s @%d: %w", path, ref.Offset, err)
			}
			got, err := r.PutBlob(bytes.NewReader(buf))
			if err != nil {
				return err
			}
			if got != ref.Hash {
				return fmt.Errorf("chunk hash mismatch for %s: planned %s, stored %s", path, ref.Hash, got)
			}
			res.UploadedBlobs++
			res.UploadedBytes += ref.Size
		}

		res.Files++
		res.TotalBytes += info.Size()
		m.Files = append(m.Files, manifest.FileEntry{
			Path:    toSlashRel(account.Path, path),
			Size:    info.Size(),
			Mode:    uint32(info.Mode().Perm()),
			ModTime: info.ModTime(),
			Chunks:  refs,
		})
		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	if err := r.WriteManifest(m); err != nil {
		return nil, nil, err
	}
	return &m, res, nil
}

func toSlashRel(base, path string) string {
	rel, err := filepath.Rel(base, path)
	if err != nil {
		// WalkDir only yields paths under base, so this cannot happen.
		rel = path
	}
	return filepath.ToSlash(rel)
}
