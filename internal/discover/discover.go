// Package discover locates local WeChat data directories across platforms.
//
// Only the desktop clients matter here: the mobile clients (iOS/iPadOS/
// Android) keep their data sandboxed by the platform security model and are
// deliberately out of scope — phone history reaches the desktop through
// WeChat's own "migrate chat history" feature.
package discover

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
)

// Account is one WeChat account directory found under a data root.
type Account struct {
	ID   string `json:"id"`   // directory name, e.g. wxid_xxxx
	Path string `json:"path"` // absolute path to the account directory
}

// ErrNotFound reports that no known WeChat data root exists on this machine.
var ErrNotFound = errors.New("keepsake: no WeChat data directory found on this machine")

// DefaultRoot returns the platform's WeChat data root, checking the known
// candidates in order. It returns an error wrapping ErrNotFound when none
// of them exists.
func DefaultRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	var candidates []string
	switch runtime.GOOS {
	case "darwin":
		candidates = []string{
			filepath.Join(home, "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"),
		}
	case "windows":
		candidates = []string{
			// WeChat 4.x
			filepath.Join(home, "Documents", "xwechat_files"),
			// WeChat 3.x legacy layout
			filepath.Join(home, "Documents", "WeChat Files"),
		}
	case "linux":
		candidates = []string{
			filepath.Join(home, ".xwechat"),
		}
	default:
		return "", ErrNotFound
	}

	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && info.IsDir() {
			return c, nil
		}
	}
	return "", ErrNotFound
}

// FindAccounts lists the WeChat account directories under the platform's
// default root. An account directory is one that contains a db_storage
// subdirectory (the WeChat 4.x message store); other directories are ignored
// so cache/tmp clutter never shows up as an account.
func FindAccounts() ([]Account, error) {
	root, err := DefaultRoot()
	if err != nil {
		return nil, err
	}
	return FindAccountsIn(root)
}

// FindAccountsIn lists account directories under an explicit root. Used by
// tests and by users whose data lives on a non-default path.
func FindAccountsIn(root string) ([]Account, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	var accounts []Account
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		// WeChat 4.x account dirs contain db_storage; the 3.x legacy layout
		// used msg_<n>.db files directly under the account dir.
		accPath := filepath.Join(root, e.Name())
		_, dbStorageErr := os.Stat(filepath.Join(accPath, "db_storage"))
		if dbStorageErr == nil {
			accounts = append(accounts, Account{ID: e.Name(), Path: accPath})
			continue
		}
	}
	return accounts, nil
}
