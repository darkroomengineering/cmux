package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// --- Wait-for (filesystem-based signaling) ---

func tmuxWaitForSignalPath(name, socketIdentity string) (string, error) {
	runtimeDir, err := tmuxWaitForRuntimeDirectory()
	if err != nil {
		return "", err
	}
	var sanitized strings.Builder
	for _, c := range name {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '_' || c == '-' {
			sanitized.WriteRune(c)
		} else {
			sanitized.WriteByte('_')
		}
	}
	nameHash := sha256.Sum256([]byte(name))
	sessionHash := sha256.Sum256([]byte(socketIdentity))
	return filepath.Join(
		runtimeDir,
		fmt.Sprintf("%x-%s-%x.sig", sessionHash[:8], sanitized.String(), nameHash[:8]),
	), nil
}

func tmuxWaitForRuntimeDirectory() (string, error) {
	if xdgRuntime := strings.TrimSpace(os.Getenv("XDG_RUNTIME_DIR")); xdgRuntime != "" {
		if err := validateOwnedPrivateDirectory(xdgRuntime); err == nil {
			programaDir := filepath.Join(xdgRuntime, "programa")
			waitDir := filepath.Join(programaDir, "wait-for")
			for _, component := range []string{programaDir, waitDir} {
				if err := ensureOwnedPrivateDirectory(component); err != nil {
					return "", err
				}
			}
			return waitDir, nil
		}
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	programaDir := filepath.Join(home, ".programa")
	runDir := filepath.Join(programaDir, "run")
	waitDir := filepath.Join(runDir, "wait-for")
	for _, component := range []string{programaDir, runDir, waitDir} {
		if err := ensureOwnedPrivateDirectory(component); err != nil {
			return "", err
		}
	}
	return waitDir, nil
}

func validateOwnedPrivateDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || info.Mode().Perm() != 0700 {
		return fmt.Errorf("runtime directory is not a private real directory")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("runtime directory is not owned by the current user")
	}
	return nil
}

func validateOwnedPrivateSignal(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return fmt.Errorf("wait-for signal is not a private real file")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("wait-for signal is not owned by the current user")
	}
	return nil
}

func writeTmuxWaitForSignal(path string) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0600)
	if os.IsExist(err) {
		return validateOwnedPrivateSignal(path)
	}
	if err != nil {
		return fmt.Errorf("create wait-for signal: %w", err)
	}
	if _, err := file.WriteString("signal\n"); err != nil {
		file.Close()
		return fmt.Errorf("write wait-for signal: %w", err)
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return fmt.Errorf("sync wait-for signal: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close wait-for signal: %w", err)
	}
	if err := validateOwnedPrivateSignal(path); err != nil {
		return fmt.Errorf("verify wait-for signal: %w", err)
	}
	return nil
}
