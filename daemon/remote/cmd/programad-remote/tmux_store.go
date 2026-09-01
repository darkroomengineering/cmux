package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// --- TmuxCompatStore (local JSON state) ---

type tmuxCompatStore struct {
	Buffers map[string]string `json:"buffers,omitempty"`
	Hooks   map[string]string `json:"hooks,omitempty"`
}

func tmuxCompatStoreURL() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".programaterm", "tmux-compat-store.json")
}

func loadTmuxCompatStore() tmuxCompatStore {
	data, err := os.ReadFile(tmuxCompatStoreURL())
	if err != nil {
		return tmuxCompatStore{
			Buffers: make(map[string]string),
			Hooks:   make(map[string]string),
		}
	}
	var store tmuxCompatStore
	if err := json.Unmarshal(data, &store); err != nil {
		return tmuxCompatStore{
			Buffers: make(map[string]string),
			Hooks:   make(map[string]string),
		}
	}
	if store.Buffers == nil {
		store.Buffers = make(map[string]string)
	}
	if store.Hooks == nil {
		store.Hooks = make(map[string]string)
	}
	return store
}

func saveTmuxCompatStore(store tmuxCompatStore) error {
	path := tmuxCompatStoreURL()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.Marshal(store)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}
