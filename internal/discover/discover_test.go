package discover

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestFindAccountsInDetectsDBStorageLayout(t *testing.T) {
	root := t.TempDir()

	// A real 4.x account dir.
	acc := filepath.Join(root, "wxid_abc123")
	if err := os.MkdirAll(filepath.Join(acc, "db_storage", "message"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Noise that must be ignored: a cache dir, a loose file, and an account
	// dir without db_storage.
	if err := os.MkdirAll(filepath.Join(root, "cache"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "stray.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "all-users"), 0o755); err != nil {
		t.Fatal(err)
	}

	accounts, err := FindAccountsIn(root)
	if err != nil {
		t.Fatalf("FindAccountsIn: %v", err)
	}
	if len(accounts) != 1 {
		t.Fatalf("got %d accounts, want 1: %+v", len(accounts), accounts)
	}
	if accounts[0].ID != "wxid_abc123" {
		t.Fatalf("account ID = %q, want wxid_abc123", accounts[0].ID)
	}
	if accounts[0].Path != acc {
		t.Fatalf("account path = %q, want %q", accounts[0].Path, acc)
	}
}

func TestFindAccountsInEmptyRoot(t *testing.T) {
	accounts, err := FindAccountsIn(t.TempDir())
	if err != nil {
		t.Fatalf("FindAccountsIn: %v", err)
	}
	if len(accounts) != 0 {
		t.Fatalf("got %d accounts, want 0", len(accounts))
	}
}

func TestFindAccountsInMissingRoot(t *testing.T) {
	_, err := FindAccountsIn(filepath.Join(t.TempDir(), "nope"))
	if err == nil {
		t.Fatal("expected error for missing root")
	}
}

func TestDefaultRootExistsSomewhereOnThisMachine(t *testing.T) {
	// On a dev machine without WeChat installed the default root legitimately
	// does not exist; the contract is that a missing root surfaces as
	// ErrNotFound, never a bare stat error.
	_, err := DefaultRoot()
	if err != nil && !errors.Is(err, ErrNotFound) {
		t.Fatalf("DefaultRoot error = %v, want ErrNotFound or nil", err)
	}
}
