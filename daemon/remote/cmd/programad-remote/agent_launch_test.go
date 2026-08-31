package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOmoEnsurePluginInvalidJSONErrorDoesNotExposeUserPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	userDir := filepath.Join(home, ".config", "opencode")
	if err := os.MkdirAll(userDir, 0755); err != nil {
		t.Fatalf("failed to create user config dir: %v", err)
	}
	userJSONPath := filepath.Join(userDir, "opencode.json")
	if err := os.WriteFile(userJSONPath, []byte("{"), 0644); err != nil {
		t.Fatalf("failed to write invalid config: %v", err)
	}

	err := omoEnsurePlugin(os.Getenv("PATH"))
	if err == nil {
		t.Fatal("omoEnsurePlugin returned nil for invalid opencode.json")
	}

	msg := err.Error()
	if strings.Contains(msg, home) || strings.Contains(msg, userJSONPath) {
		t.Fatalf("error %q exposes user config path %q", msg, userJSONPath)
	}
	if !strings.Contains(msg, "invalid opencode.json") {
		t.Fatalf("error = %q, want generic invalid opencode.json message", msg)
	}
}

func TestEnsureClaudeNodeOptionsRestoreModuleUsesPrivateUserStorage(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	path, err := ensureClaudeNodeOptionsRestoreModule()
	if err != nil {
		t.Fatalf("ensureClaudeNodeOptionsRestoreModule: %v", err)
	}
	want := filepath.Join(home, ".programa", "runtime", "claude-node-options", "restore-node-options.cjs")
	if path != want {
		t.Fatalf("restore module path = %q, want %q", path, want)
	}
	for _, directory := range []string{
		filepath.Join(home, ".programa"),
		filepath.Join(home, ".programa", "runtime"),
		filepath.Dir(want),
	} {
		info, statErr := os.Lstat(directory)
		if statErr != nil {
			t.Fatalf("lstat %q: %v", directory, statErr)
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0700 {
			t.Fatalf("directory %q has unsafe mode %v", directory, info.Mode())
		}
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("lstat restore module: %v", err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0600 {
		t.Fatalf("restore module has unsafe mode %v", info.Mode())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read restore module: %v", err)
	}
	if string(data) != claudeNodeOptionsRestoreModuleScript {
		t.Fatal("restore module content changed")
	}
}

func TestEnsureClaudeNodeOptionsRestoreModuleRejectsSymlinkedProgramaDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	foreign := t.TempDir()
	if err := os.Symlink(foreign, filepath.Join(home, ".programa")); err != nil {
		t.Fatalf("create malicious symlink: %v", err)
	}

	if _, err := ensureClaudeNodeOptionsRestoreModule(); err == nil {
		t.Fatal("expected symlinked .programa directory to be rejected")
	}
	if _, err := os.Stat(filepath.Join(foreign, "runtime", "claude-node-options", "restore-node-options.cjs")); !os.IsNotExist(err) {
		t.Fatalf("restore module followed symlink into foreign directory: %v", err)
	}
}
