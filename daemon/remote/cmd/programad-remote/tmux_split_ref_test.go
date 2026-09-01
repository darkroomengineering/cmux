package main

import (
	"bufio"
	"encoding/json"
	"net"
	"sync"
	"testing"
)

const (
	tmuxLeaderWorkspace = "11111111-1111-4111-8111-111111111111"
	tmuxTeamWorkspaceA  = "22222222-2222-4222-8222-222222222222"
	tmuxOtherWorkspace  = "33333333-3333-4333-8333-333333333333"
	tmuxTeamWorkspaceB  = "44444444-4444-4444-8444-444444444444"
	tmuxSpawnWorkspace  = "55555555-5555-4555-8555-555555555555"
	tmuxLeaderSurface   = "66666666-6666-4666-8666-666666666666"
	tmuxSpawnSurface    = "77777777-7777-4777-8777-777777777777"
	tmuxLeaderPane      = "88888888-8888-4888-8888-888888888888"
	tmuxSpawnPane       = "99999999-9999-4999-8999-999999999999"
)

type tmuxAgentRequest struct {
	method string
	params map[string]any
}

func tmuxHelperFixture(id string, parentId string, host string) map[string]any {
	return map[string]any{
		"id":                        id,
		"ref":                       "workspace:" + id[:1],
		"title":                     id,
		"agent_parent_workspace_id": parentId,
		"helpers": []map[string]any{{
			"id":           "agent-" + id,
			"host":         host,
			"workspace_id": id,
		}},
	}
}

func tmuxTeamWorkspaceFixture() []map[string]any {
	return []map[string]any{
		{
			"id":    tmuxLeaderWorkspace,
			"ref":   "workspace:1",
			"index": 1,
			"title": "Lead",
		},
		tmuxHelperFixture(tmuxTeamWorkspaceA, tmuxLeaderWorkspace, "claude-teams"),
		tmuxHelperFixture(tmuxOtherWorkspace, tmuxTeamWorkspaceA, "codex"),
		tmuxHelperFixture(tmuxTeamWorkspaceB, tmuxTeamWorkspaceA, "claude-teams"),
	}
}

func startMockAgentTmuxSocket(
	t *testing.T,
	workspaceItems []map[string]any,
) (string, *[]tmuxAgentRequest, *sync.Mutex) {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)
	cwd := t.TempDir()
	requests := []tmuxAgentRequest{}
	var lock sync.Mutex
	if len(workspaceItems) > 0 {
		workspaceItems[0]["active"] = true
		workspaceItems[0]["current_directory"] = cwd
	}

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				line, err := bufio.NewReader(conn).ReadBytes('\n')
				if err != nil {
					return
				}
				var req map[string]any
				if err := json.Unmarshal(line, &req); err != nil {
					return
				}
				method, _ := req["method"].(string)
				params, _ := req["params"].(map[string]any)
				lock.Lock()
				requests = append(requests, tmuxAgentRequest{method: method, params: params})
				lock.Unlock()

				workspaceId, _ := params["workspace_id"].(string)
				paneId := tmuxLeaderPane
				surfaceId := tmuxLeaderSurface
				paneRef := "pane:1"
				surfaceRef := "surface:1"
				if workspaceId == tmuxSpawnWorkspace {
					paneId = tmuxSpawnPane
					surfaceId = tmuxSpawnSurface
					paneRef = "pane:2"
					surfaceRef = "surface:2"
				}
				resp := map[string]any{"id": req["id"], "ok": true}
				switch method {
				case "system.identify":
					resp["result"] = map[string]any{
						"focused": map[string]any{
							"workspace_id":  tmuxLeaderWorkspace,
							"workspace_ref": "workspace:1",
							"pane_id":       "pane:1",
							"pane_ref":      "pane:1",
							"surface_ref":   "surface:1",
						},
					}
				case "workspace.list":
					resp["result"] = map[string]any{"workspaces": workspaceItems}
				case "surface.current":
					resp["result"] = map[string]any{
						"workspace_id": workspaceId,
						"pane_id":      paneId,
						"surface_id":   surfaceId,
					}
				case "surface.list":
					resp["result"] = map[string]any{"surfaces": []map[string]any{{
						"id":                          surfaceId,
						"ref":                         surfaceRef,
						"focused":                     true,
						"selected_in_pane":            true,
						"pane_id":                     paneId,
						"pane_ref":                    paneRef,
						"title":                       "leader",
						"requested_working_directory": cwd,
					}}}
				case "pane.list":
					resp["result"] = map[string]any{
						"panes": []map[string]any{{
							"id":                  paneId,
							"ref":                 paneRef,
							"index":               1,
							"focused":             true,
							"columns":             120,
							"rows":                40,
							"cell_width_px":       10,
							"cell_height_px":      20,
							"pixel_frame":         map[string]any{"x": 0, "y": 0, "width": 1200, "height": 800},
							"surface_ids":         []any{surfaceId},
							"surface_refs":        []any{surfaceRef},
							"surface_count":       1,
							"selected_surface_id": surfaceId,
						}},
						"container_frame": map[string]any{"width": 1200, "height": 800},
					}
				case "pane.surfaces":
					resp["result"] = map[string]any{"surfaces": []map[string]any{{
						"id":       surfaceId,
						"ref":      surfaceRef,
						"selected": true,
						"focused":  true,
					}}}
				case "agent.spawn":
					resp["result"] = map[string]any{
						"workspace_id": tmuxSpawnWorkspace,
						"surface_id":   tmuxSpawnSurface,
					}
				case "agent.task.list":
					resp["result"] = map[string]any{"agents": []map[string]any{{
						"id": "agent-" + workspaceId,
					}}}
				case "agent.task.finish", "workspace.close", "surface.close", "workspace.equalize_splits":
					resp["result"] = map[string]any{"ok": true}
				default:
					resp["ok"] = false
					resp["error"] = map[string]any{"code": "unsupported", "message": method}
				}

				payload, _ := json.Marshal(resp)
				_, _ = conn.Write(append(payload, '\n'))
			}(conn)
		}
	}()

	return sockPath, &requests, &lock
}

func TestTmuxSplitWindowSpawnsNestedTeamHelper(t *testing.T) {
	t.Setenv("PROGRAMA_WORKSPACE_ID", tmuxLeaderWorkspace)
	t.Setenv("PROGRAMA_SURFACE_ID", tmuxLeaderSurface)
	sockPath, requests, lock := startMockAgentTmuxSocket(t, tmuxTeamWorkspaceFixture())
	rc := &rpcContext{socketPath: sockPath}

	output := captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "split-window", []string{
			"-h", "-P", "-F", "#{pane_id}", "-c", "/repo", "claude", "--agent",
		}); err != nil {
			t.Fatalf("split-window: %v", err)
		}
	})

	wantOutput := "%" + tmuxStableNumericId(tmuxSpawnPane) + "\n"
	if output != wantOutput {
		t.Fatalf("stdout = %q, want %q", output, wantOutput)
	}

	lock.Lock()
	defer lock.Unlock()
	spawnCount := 0
	for _, request := range *requests {
		if request.method == "surface.split" || request.method == "surface.send_text" {
			t.Fatalf("split-window used obsolete surface path: %s", request.method)
		}
		if request.method != "agent.spawn" {
			continue
		}
		spawnCount++
		if request.params["parent_workspace_id"] != tmuxLeaderWorkspace ||
			request.params["host"] != "claude-teams" ||
			request.params["task"] != "Helper" || request.params["focus"] != false {
			t.Errorf("agent.spawn params = %v", request.params)
		}
		if request.params["initial_command"] != "cd -- '/repo' && claude --agent\r" {
			t.Errorf("initial_command = %q", request.params["initial_command"])
		}
	}
	if spawnCount != 1 {
		t.Fatalf("agent.spawn calls = %d, want 1", spawnCount)
	}
}

func TestTmuxListPanesOnlyTraversesClaudeTeamSubtree(t *testing.T) {
	t.Setenv("PROGRAMA_WORKSPACE_ID", tmuxLeaderWorkspace)
	sockPath, _, _ := startMockAgentTmuxSocket(t, tmuxTeamWorkspaceFixture())
	rc := &rpcContext{socketPath: sockPath}

	output := captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "list-panes", []string{"-F", "#{window_uuid}"}); err != nil {
			t.Fatalf("list-panes: %v", err)
		}
	})
	want := tmuxLeaderWorkspace + "\n" + tmuxTeamWorkspaceA + "\n" + tmuxTeamWorkspaceB + "\n"
	if output != want {
		t.Fatalf("stdout = %q, want %q", output, want)
	}
}

func TestTmuxKillWindowFinishesTeamHelpersDeepestFirst(t *testing.T) {
	t.Setenv("PROGRAMA_WORKSPACE_ID", tmuxLeaderWorkspace)
	sockPath, requests, lock := startMockAgentTmuxSocket(t, tmuxTeamWorkspaceFixture())
	rc := &rpcContext{socketPath: sockPath}

	if err := dispatchTmuxCommand(rc, "kill-window", []string{"-t", tmuxLeaderWorkspace}); err != nil {
		t.Fatalf("kill-window: %v", err)
	}

	lock.Lock()
	defer lock.Unlock()
	finished := []string{}
	closed := []string{}
	for _, request := range *requests {
		switch request.method {
		case "agent.task.list":
			if request.params["include_finished"] != false {
				t.Errorf("agent.task.list params = %v", request.params)
			}
		case "agent.task.finish":
			if request.params["state"] != "cancelled" {
				t.Errorf("agent.task.finish params = %v", request.params)
			}
			finished = append(finished, stringFromAnyGo(request.params["agent_id"]))
		case "workspace.close":
			closed = append(closed, stringFromAnyGo(request.params["workspace_id"]))
		}
	}
	wantFinished := []string{"agent-" + tmuxTeamWorkspaceB, "agent-" + tmuxTeamWorkspaceA}
	if !equalStringSlices(finished, wantFinished) {
		t.Fatalf("finished helpers = %v, want %v", finished, wantFinished)
	}
	wantClosed := []string{tmuxTeamWorkspaceB, tmuxTeamWorkspaceA, tmuxLeaderWorkspace}
	if !equalStringSlices(closed, wantClosed) {
		t.Fatalf("closed workspaces = %v, want %v", closed, wantClosed)
	}
}

func TestTmuxKillSinglePaneClosesTeamWorkspaceLifecycle(t *testing.T) {
	t.Setenv("PROGRAMA_WORKSPACE_ID", tmuxTeamWorkspaceA)
	sockPath, requests, lock := startMockAgentTmuxSocket(t, tmuxTeamWorkspaceFixture())
	rc := &rpcContext{socketPath: sockPath}

	if err := dispatchTmuxCommand(rc, "kill-pane", []string{"-t", tmuxTeamWorkspaceA}); err != nil {
		t.Fatalf("kill-pane: %v", err)
	}

	lock.Lock()
	defer lock.Unlock()
	closed := []string{}
	for _, request := range *requests {
		if request.method == "surface.close" {
			t.Fatal("single-pane team helper used surface.close")
		}
		if request.method == "workspace.close" {
			closed = append(closed, stringFromAnyGo(request.params["workspace_id"]))
		}
	}
	want := []string{tmuxTeamWorkspaceB, tmuxTeamWorkspaceA}
	if !equalStringSlices(closed, want) {
		t.Fatalf("closed workspaces = %v, want %v", closed, want)
	}
}

func TestTmuxTeamWorkspaceIdsUsesStableOrderForCycles(t *testing.T) {
	items := []map[string]any{
		tmuxHelperFixture(tmuxTeamWorkspaceB, tmuxTeamWorkspaceA, "claude-teams"),
		tmuxHelperFixture(tmuxTeamWorkspaceA, tmuxTeamWorkspaceB, "claude-teams"),
	}
	got := tmuxTeamWorkspaceIds(tmuxTeamWorkspaceA, items)
	want := []string{tmuxTeamWorkspaceB, tmuxTeamWorkspaceA}
	if !equalStringSlices(got, want) {
		t.Fatalf("team cycle order = %v, want %v", got, want)
	}
}

func equalStringSlices(got []string, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}
