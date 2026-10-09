// Command agent is the keepsake desktop agent: it discovers WeChat account
// directories, snapshots them into a keepsake repository, and restores from
// that repository — file-level only, never touching WeChat's encryption.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"text/tabwriter"
	"time"

	"github.com/turinglambdaai/keepsake/internal/discover"
	"github.com/turinglambdaai/keepsake/internal/repo"
	"github.com/turinglambdaai/keepsake/internal/snapshot"
)

const version = "0.0.1"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "discover":
		err = cmdDiscover()
	case "snapshot":
		err = cmdSnapshot(os.Args[2:])
	case "status":
		err = cmdStatus(os.Args[2:])
	case "restore":
		fmt.Println("restore is not implemented yet (M0 milestone); see docs/repo-format.md")
	case "version":
		fmt.Println("keepsake agent", version)
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "keepsake:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `keepsake agent — local file-level backup for desktop WeChat data

Usage:
  keepsake discover                 list WeChat accounts found on this machine
  keepsake snapshot --repo DIR [--account ID] [--device NAME]
  keepsake status   --repo DIR [--device NAME]
  keepsake restore                  (not implemented yet)
  keepsake version
`)
}

func cmdDiscover() error {
	accounts, err := discover.FindAccounts()
	if err != nil {
		return err
	}
	if len(accounts) == 0 {
		fmt.Println("no WeChat account directories found")
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ACCOUNT\tSIZE\tPATH")
	for _, a := range accounts {
		size, err := dirSize(a.Path)
		if err != nil {
			return err
		}
		fmt.Fprintf(w, "%s\t%s\t%s\n", a.ID, human(size), a.Path)
	}
	return w.Flush()
}

func cmdSnapshot(args []string) error {
	fs := flag.NewFlagSet("snapshot", flag.ExitOnError)
	repoDir := fs.String("repo", "", "repository directory (required)")
	accountID := fs.String("account", "", "account directory name (default: all accounts)")
	device := fs.String("device", defaultDeviceName(), "device id stored in the repository")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *repoDir == "" {
		return fmt.Errorf("--repo is required")
	}

	accounts, err := discover.FindAccounts()
	if err != nil {
		return err
	}
	if *accountID != "" {
		var keep []discover.Account
		for _, a := range accounts {
			if a.ID == *accountID {
				keep = append(keep, a)
			}
		}
		if len(keep) == 0 {
			return fmt.Errorf("account %q not found; run `keepsake discover`", *accountID)
		}
		accounts = keep
	}

	r, err := repo.Init(*repoDir)
	if err != nil {
		return err
	}
	for _, a := range accounts {
		m, res, err := snapshot.Run(r, a, *device)
		if err != nil {
			return err
		}
		b, _ := json.MarshalIndent(res, "", "  ")
		fmt.Printf("snapshot %s @ %s\n%s\n", a.ID, m.CreatedAt.Format(time.RFC3339), b)
	}
	return nil
}

func cmdStatus(args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	repoDir := fs.String("repo", "", "repository directory (required)")
	device := fs.String("device", "", "device id (default: all devices)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *repoDir == "" {
		return fmt.Errorf("--repo is required")
	}
	r, err := repo.Open(*repoDir)
	if err != nil {
		return err
	}

	var devices []string
	if *device != "" {
		devices = []string{*device}
	} else {
		entries, err := os.ReadDir(filepath.Join(r.Root(), "devices"))
		if err != nil {
			return err
		}
		for _, e := range entries {
			devices = append(devices, e.Name())
		}
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "DEVICE\tSNAPSHOT\tACCOUNT\tFILES\tSIZE")
	for _, d := range devices {
		snaps, err := r.Snapshots(d)
		if err != nil {
			return err
		}
		for _, m := range snaps {
			fmt.Fprintf(w, "%s\t%s\t%s\t%d\t%s\n", d,
				m.CreatedAt.Local().Format("2006-01-02 15:04:05"),
				m.Account, len(m.Files), human(m.TotalSize()))
		}
	}
	return w.Flush()
}

func defaultDeviceName() string {
	host, err := os.Hostname()
	if err == nil && host != "" {
		return host
	}
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return "unknown"
}

func dirSize(root string) (int64, error) {
	var total int64
	err := filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		total += info.Size()
		return nil
	})
	return total, err
}

func human(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for ; n >= unit && exp < 4; exp++ {
		n /= unit
		div /= unit
	}
	return fmt.Sprintf("%.1f %cB", float64(n)*float64(div), "KMGTPE"[exp-1])
}
