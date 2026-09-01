package main

import (
	"fmt"
	"math"
	"os"
	"strings"
	"time"
)

// --- Command implementations ---

func tmuxIsClaudeTeamWorkspace(item map[string]any) bool {
	workspaceId, _ := item["id"].(string)
	if workspaceId == "" {
		return false
	}
	helpers := []any{}
	switch rawHelpers := item["helpers"].(type) {
	case []any:
		helpers = rawHelpers
	case []map[string]any:
		for _, helper := range rawHelpers {
			helpers = append(helpers, helper)
		}
	}
	for _, rawHelper := range helpers {
		helper, _ := rawHelper.(map[string]any)
		if helper == nil {
			continue
		}
		host, _ := helper["host"].(string)
		helperWorkspaceId, _ := helper["workspace_id"].(string)
		if host == "claude-teams" && helperWorkspaceId == workspaceId {
			return true
		}
	}
	return false
}

func tmuxTeamWorkspaceIds(workspaceId string, workspaceItems []map[string]any) []string {
	orderedIds := make([]string, 0, len(workspaceItems))
	liveWorkspaceIds := make(map[string]bool, len(workspaceItems))
	teamWorkspaceIds := make(map[string]bool, len(workspaceItems))
	orderById := make(map[string]int, len(workspaceItems))
	for _, item := range workspaceItems {
		id, _ := item["id"].(string)
		if id == "" {
			continue
		}
		orderById[id] = len(orderedIds)
		orderedIds = append(orderedIds, id)
		liveWorkspaceIds[id] = true
		if tmuxIsClaudeTeamWorkspace(item) {
			teamWorkspaceIds[id] = true
		}
	}

	parentById := make(map[string]string, len(teamWorkspaceIds))
	for _, item := range workspaceItems {
		id, _ := item["id"].(string)
		parentId, _ := item["agent_parent_workspace_id"].(string)
		if teamWorkspaceIds[id] && liveWorkspaceIds[parentId] {
			parentById[id] = parentId
		}
	}

	lineage := []string{workspaceId}
	lineageIndex := map[string]int{workspaceId: 0}
	rootWorkspaceId := workspaceId
	for {
		parentId, ok := parentById[rootWorkspaceId]
		if !ok {
			break
		}
		if cycleStart, seen := lineageIndex[parentId]; seen {
			rootWorkspaceId = lineage[cycleStart]
			for _, candidate := range lineage[cycleStart:] {
				if orderById[candidate] < orderById[rootWorkspaceId] {
					rootWorkspaceId = candidate
				}
			}
			break
		}
		lineageIndex[parentId] = len(lineage)
		lineage = append(lineage, parentId)
		rootWorkspaceId = parentId
	}

	workspaceIds := []string{}
	visited := map[string]bool{}
	var appendSubtree func(string)
	appendSubtree = func(parentId string) {
		if visited[parentId] {
			return
		}
		visited[parentId] = true
		workspaceIds = append(workspaceIds, parentId)
		for _, childId := range orderedIds {
			if parentById[childId] == parentId {
				appendSubtree(childId)
			}
		}
	}
	appendSubtree(rootWorkspaceId)
	return workspaceIds
}

func tmuxDescendantWorkspaceIds(workspaceId string, workspaceItems []map[string]any) []string {
	orderedIds := make([]string, 0, len(workspaceItems))
	parentById := map[string]string{}
	for _, item := range workspaceItems {
		id, _ := item["id"].(string)
		if id == "" {
			continue
		}
		orderedIds = append(orderedIds, id)
		parentId, _ := item["agent_parent_workspace_id"].(string)
		if tmuxIsClaudeTeamWorkspace(item) && parentId != "" {
			parentById[id] = parentId
		}
	}

	descendants := []string{}
	visited := map[string]bool{workspaceId: true}
	var appendDescendants func(string)
	appendDescendants = func(parentId string) {
		for _, childId := range orderedIds {
			if parentById[childId] != parentId || visited[childId] {
				continue
			}
			visited[childId] = true
			appendDescendants(childId)
			descendants = append(descendants, childId)
		}
	}
	appendDescendants(workspaceId)
	return descendants
}

func tmuxFinishLiveAgents(rc *rpcContext, workspaceId string) {
	payload, err := rc.call("agent.task.list", map[string]any{
		"workspace_id":    workspaceId,
		"include_finished": false,
	})
	if err != nil {
		return
	}
	agents, _ := payload["agents"].([]any)
	for _, rawAgent := range agents {
		agent, _ := rawAgent.(map[string]any)
		agentId, _ := agent["id"].(string)
		if agentId == "" {
			continue
		}
		_, _ = rc.call("agent.task.finish", map[string]any{
			"agent_id": agentId,
			"state":    "cancelled",
		})
	}
}

func tmuxCloseHelperWorkspace(rc *rpcContext, workspaceId string) error {
	tmuxFinishLiveAgents(rc, workspaceId)
	_, err := rc.call("workspace.close", map[string]any{"workspace_id": workspaceId})
	return err
}

func tmuxNewSession(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-n", "-s"}, []string{"-A", "-d", "-P"})
	if p.hasFlag("-A") {
		return fmt.Errorf("new-session -A is not supported")
	}
	params := map[string]any{"focus": false}
	if cwd := p.value("-c"); cwd != "" {
		params["cwd"] = cwd
	}
	created, err := rc.call("workspace.create", params)
	if err != nil {
		return err
	}
	workspaceId, _ := created["workspace_id"].(string)
	if workspaceId == "" {
		return fmt.Errorf("workspace.create did not return workspace_id")
	}
	if title := strings.TrimSpace(firstNonEmpty(p.value("-n"), p.value("-s"))); title != "" {
		_, _ = rc.call("workspace.rename", map[string]any{"workspace_id": workspaceId, "title": title})
	}
	if text := tmuxShellCommandText(p.positional, p.value("-c")); text != "" {
		if surfaceId, surfaceErr := tmuxGetFirstSurface(rc, workspaceId); surfaceErr == nil {
			_, _ = rc.call("surface.send_text", map[string]any{
				"workspace_id": workspaceId,
				"surface_id":   surfaceId,
				"text":         text,
			})
		}
	}
	if p.hasFlag("-P") {
		ctx, formatErr := tmuxFormatContext(rc, workspaceId, "", "")
		if formatErr != nil {
			fmt.Printf("@%s\n", workspaceId)
		} else {
			fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, "@"+workspaceId))
		}
	}
	return nil
}

func tmuxNewWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-n", "-t"}, []string{"-d", "-P"})
	if strings.TrimSpace(p.value("-t")) != "" {
		return fmt.Errorf("new-window -t is not supported in programa claude-teams mode")
	}
	parentWorkspaceId := tmuxResolvedCallerWorkspaceId(rc)
	if parentWorkspaceId == "" {
		var err error
		parentWorkspaceId, err = tmuxResolveWorkspaceTarget(rc, "")
		if err != nil {
			return err
		}
	}
	task := strings.TrimSpace(p.value("-n"))
	if task == "" {
		task = "Helper"
	}
	params := map[string]any{
		"parent_workspace_id": parentWorkspaceId,
		"host":                "claude-teams",
		"task":                task,
		"focus":               false,
	}
	if initialCommand := tmuxShellCommandText(p.positional, p.value("-c")); initialCommand != "" {
		params["initial_command"] = initialCommand
	}
	created, err := rc.call("agent.spawn", params)
	if err != nil {
		return err
	}
	workspaceId, _ := created["workspace_id"].(string)
	if workspaceId == "" {
		return fmt.Errorf("agent.spawn did not return workspace_id")
	}
	if p.hasFlag("-P") {
		surfaceId, _ := created["surface_id"].(string)
		if surfaceId == "" {
			return fmt.Errorf("agent.spawn did not return surface_id")
		}
		ctx, err := tmuxFormatContext(rc, workspaceId, "", surfaceId)
		if err != nil {
			fmt.Printf("@%s\n", workspaceId)
			return nil
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, "@"+workspaceId))
	}
	return nil
}

func tmuxSplitWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-c", "-F", "-l", "-t"}, []string{"-P", "-b", "-d", "-h", "-v"})

	targetWs, _, _, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	parentWorkspaceId := tmuxResolvedCallerWorkspaceId(rc)
	if parentWorkspaceId == "" {
		parentWorkspaceId = targetWs
	}
	params := map[string]any{
		"parent_workspace_id": parentWorkspaceId,
		"host":                "claude-teams",
		"task":                "Helper",
		"focus":               false,
	}
	if initialCommand := tmuxShellCommandText(p.positional, p.value("-c")); initialCommand != "" {
		params["initial_command"] = initialCommand
	}
	created, err := rc.call("agent.spawn", params)
	if err != nil {
		return err
	}
	workspaceId, _ := created["workspace_id"].(string)
	if workspaceId == "" {
		return fmt.Errorf("agent.spawn did not return workspace_id")
	}
	surfaceId, _ := created["surface_id"].(string)
	if surfaceId == "" {
		return fmt.Errorf("agent.spawn did not return surface_id")
	}

	if p.hasFlag("-P") {
		ctx, err := tmuxFormatContext(rc, workspaceId, "", surfaceId)
		if err != nil {
			fmt.Println(surfaceId)
			return nil
		}
		fallback := surfaceId
		if pid, ok := ctx["pane_id"]; ok {
			fallback = pid
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
	}
	return nil
}

func tmuxSelectWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("workspace.select", map[string]any{"workspace_id": wsId})
	return err
}

func tmuxSelectPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-P", "-T", "-t"}, nil)
	// -P (style) and -T (title) are no-ops
	if p.value("-P") != "" || p.value("-T") != "" {
		return nil
	}
	wsId, paneId, err := tmuxResolvePaneTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("pane.focus", map[string]any{"workspace_id": wsId, "pane_id": paneId})
	return err
}

func tmuxKillWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	workspaceItems, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return err
	}
	for _, descendantId := range tmuxDescendantWorkspaceIds(wsId, workspaceItems) {
		if err := tmuxCloseHelperWorkspace(rc, descendantId); err != nil {
			return err
		}
	}
	for _, item := range workspaceItems {
		itemId, _ := item["id"].(string)
		if itemId == wsId && tmuxIsClaudeTeamWorkspace(item) {
			return tmuxCloseHelperWorkspace(rc, wsId)
		}
	}
	_, err = rc.call("workspace.close", map[string]any{"workspace_id": wsId})
	return err
}

func tmuxKillPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
	if err != nil {
		return err
	}
	panes, _ := panePayload["panes"].([]any)
	workspaceItems, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return err
	}
	teamWorkspace := false
	for _, item := range workspaceItems {
		itemId, _ := item["id"].(string)
		if itemId == wsId {
			teamWorkspace = tmuxIsClaudeTeamWorkspace(item)
			break
		}
	}
	if len(panes) <= 1 && teamWorkspace {
		for _, descendantId := range tmuxDescendantWorkspaceIds(wsId, workspaceItems) {
			if err := tmuxCloseHelperWorkspace(rc, descendantId); err != nil {
				return err
			}
		}
		return tmuxCloseHelperWorkspace(rc, wsId)
	}
	_, err = rc.call("surface.close", map[string]any{"workspace_id": wsId, "surface_id": surfId})
	if err == nil {
		_, _ = rc.call("workspace.equalize_splits", map[string]any{"workspace_id": wsId, "orientation": "vertical"})
	}
	return err
}

func tmuxSendKeys(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, []string{"-l"})
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	text := tmuxSendKeysText(p.positional, p.hasFlag("-l"))
	if text != "" {
		_, err = rc.call("surface.send_text", map[string]any{
			"workspace_id": wsId,
			"surface_id":   surfId,
			"text":         text,
		})
	}
	return err
}

func tmuxCapturePane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-E", "-S", "-t"}, []string{"-J", "-N", "-p"})
	wsId, _, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	params := map[string]any{
		"workspace_id": wsId,
		"surface_id":   surfId,
		"scrollback":   true,
	}
	if start := p.value("-S"); start != "" {
		if lines := parseInt(start); lines < 0 {
			params["lines"] = int(math.Abs(float64(lines)))
		}
	}
	payload, err := rc.call("surface.read_text", params)
	if err != nil {
		return err
	}
	text, _ := payload["text"].(string)
	if p.hasFlag("-p") {
		fmt.Print(text)
	} else {
		store := loadTmuxCompatStore()
		store.Buffers["default"] = text
		saveTmuxCompatStore(store)
	}
	return nil
}

func tmuxDisplayMessage(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, []string{"-p"})
	wsId, paneId, surfId, err := tmuxResolveSurfaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	ctx, err := tmuxFormatContext(rc, wsId, paneId, surfId)
	if err != nil {
		ctx = map[string]string{}
	}

	// Enrich with geometry
	panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
	if err == nil {
		panes, _ := panePayload["panes"].([]any)
		containerFrame, _ := panePayload["container_frame"].(map[string]any)
		var matchingPane map[string]any
		if paneId != "" {
			for _, p := range panes {
				pn, _ := p.(map[string]any)
				if pid, _ := pn["id"].(string); pid == paneId {
					matchingPane = pn
					break
				}
			}
		}
		if matchingPane == nil {
			for _, p := range panes {
				pn, _ := p.(map[string]any)
				if focused, _ := boolFromAnyGo(pn["focused"]); focused {
					matchingPane = pn
					break
				}
			}
		}
		if matchingPane == nil && len(panes) > 0 {
			matchingPane, _ = panes[0].(map[string]any)
		}
		if matchingPane != nil {
			tmuxEnrichContextWithGeometry(ctx, matchingPane, containerFrame)
		}
	}

	format := p.value("-F")
	if len(p.positional) > 0 {
		format = strings.Join(p.positional, " ")
	}
	rendered := tmuxRenderFormat(format, ctx, "")
	if p.hasFlag("-p") || rendered != "" {
		fmt.Println(rendered)
	}
	return nil
}

func tmuxListWindows(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, nil)
	items, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return err
	}
	for _, item := range items {
		wsId, _ := item["id"].(string)
		if wsId == "" {
			continue
		}
		ctx, err := tmuxFormatContext(rc, wsId, "", "")
		if err != nil {
			continue
		}
		fallback := ""
		if idx, ok := ctx["window_index"]; ok {
			fallback = idx
		} else {
			fallback = "?"
		}
		if name, ok := ctx["window_name"]; ok {
			fallback += " " + name
		} else {
			fallback += " " + wsId
		}
		fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
	}
	return nil
}

func tmuxListPanes(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-F", "-t"}, nil)

	target := p.value("-t")
	var wsId string
	var err error

	if target != "" && tmuxPaneSelector(target) != "" {
		wsId, _, err = tmuxResolvePaneTarget(rc, target)
	} else {
		wsId, err = tmuxResolveWorkspaceTarget(rc, target)
	}
	if err != nil {
		return err
	}

	workspaceItems, err := tmuxWorkspaceItems(rc)
	if err != nil {
		return err
	}
	for _, listedWorkspaceId := range tmuxTeamWorkspaceIds(wsId, workspaceItems) {
		payload, err := rc.call("pane.list", map[string]any{"workspace_id": listedWorkspaceId})
		if err != nil {
			return err
		}
		panes, _ := payload["panes"].([]any)
		containerFrame, _ := payload["container_frame"].(map[string]any)

		for _, p2 := range panes {
			pane, _ := p2.(map[string]any)
			if pane == nil {
				continue
			}
			paneId, _ := pane["id"].(string)
			if paneId == "" {
				continue
			}
			ctx, err := tmuxFormatContext(rc, listedWorkspaceId, paneId, "")
			if err != nil {
				continue
			}
			tmuxEnrichContextWithGeometry(ctx, pane, containerFrame)
			fallback := "%" + paneId
			if pid, ok := ctx["pane_id"]; ok {
				fallback = pid
			}
			fmt.Println(tmuxRenderFormat(p.value("-F"), ctx, fallback))
		}
	}
	return nil
}

func tmuxRenameWindow(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	title := strings.TrimSpace(strings.Join(p.positional, " "))
	if title == "" {
		return fmt.Errorf("rename-window requires a title")
	}
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("workspace.rename", map[string]any{"workspace_id": wsId, "title": title})
	return err
}

func tmuxResizePane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t", "-x", "-y"}, []string{"-D", "-L", "-R", "-U"})
	wsId, paneId, err := tmuxResolvePaneTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}

	hasDirectional := p.hasFlag("-L") || p.hasFlag("-R") || p.hasFlag("-U") || p.hasFlag("-D")

	if !hasDirectional {
		if absWidthStr := p.value("-x"); absWidthStr != "" {
			absWidth := parseInt(strings.ReplaceAll(absWidthStr, "%", ""))
			// Get current width to compute delta
			panePayload, err := rc.call("pane.list", map[string]any{"workspace_id": wsId})
			if err != nil {
				return err
			}
			panes, _ := panePayload["panes"].([]any)
			for _, pp := range panes {
				pane, _ := pp.(map[string]any)
				if pane == nil {
					continue
				}
				if pid, _ := pane["id"].(string); pid == paneId {
					cellW := intFromAnyGo(pane["cell_width_px"])
					currentCols := intFromAnyGo(pane["columns"])
					if cellW > 0 && currentCols >= 0 {
						delta := absWidth - currentCols
						if delta != 0 {
							dir := "right"
							if delta < 0 {
								dir = "left"
								delta = -delta
							}
							rc.call("pane.resize", map[string]any{
								"workspace_id": wsId,
								"pane_id":      paneId,
								"direction":    dir,
								"amount":       delta * cellW,
							})
						}
					}
					break
				}
			}
			return nil
		}
	}

	if hasDirectional {
		dir := "right"
		if p.hasFlag("-L") {
			dir = "left"
		} else if p.hasFlag("-U") {
			dir = "up"
		} else if p.hasFlag("-D") {
			dir = "down"
		}
		rawAmount := firstNonEmpty(p.value("-x"), p.value("-y"), "5")
		rawAmount = strings.ReplaceAll(rawAmount, "%", "")
		amount := parseInt(rawAmount)
		if amount <= 0 {
			amount = 5
		}
		_, err := rc.call("pane.resize", map[string]any{
			"workspace_id": wsId,
			"pane_id":      paneId,
			"direction":    dir,
			"amount":       amount,
		})
		return err
	}
	return nil
}

func tmuxWaitFor(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"--timeout"}, []string{"-S"})
	name := ""
	for _, pos := range p.positional {
		if !strings.HasPrefix(pos, "-") {
			name = pos
			break
		}
	}
	if name == "" {
		return fmt.Errorf("wait-for requires a name")
	}

	socketIdentity := ""
	if rc != nil {
		socketIdentity = rc.socketPath
	}
	signalPath, err := tmuxWaitForSignalPath(name, socketIdentity)
	if err != nil {
		return err
	}

	if p.hasFlag("-S") {
		if err := writeTmuxWaitForSignal(signalPath); err != nil {
			return err
		}
		fmt.Println("OK")
		return nil
	}

	// Wait mode: poll for the file
	timeoutStr := p.value("--timeout")
	timeout := 30.0
	if timeoutStr != "" {
		if t := parseFloat(timeoutStr); t > 0 {
			timeout = t
		}
	}

	deadline := time.Now().Add(time.Duration(timeout * float64(time.Second)))
	for time.Now().Before(deadline) {
		if err := validateOwnedPrivateSignal(signalPath); err == nil {
			if err := os.Remove(signalPath); err != nil {
				return fmt.Errorf("consume wait-for signal: %w", err)
			}
			return nil
		} else if !os.IsNotExist(err) {
			return err
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("wait-for timeout: %s", name)
}

func tmuxLastPane(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	wsId, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	if err != nil {
		return err
	}
	_, err = rc.call("pane.last", map[string]any{"workspace_id": wsId})
	return err
}

func tmuxHasSession(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	_, err := tmuxResolveWorkspaceTarget(rc, p.value("-t"))
	return err
}

func tmuxSelectLayout(rc *rpcContext, args []string) error {
	p := parseTmuxArgs(args, []string{"-t"}, nil)
	layoutName := ""
	if len(p.positional) > 0 {
		layoutName = p.positional[0]
	}

	// Resolve workspace from target (may be a pane reference)
	var wsId string
	var err error
	if target := p.value("-t"); target != "" {
		if tmuxPaneSelector(target) != "" {
			wsId, _, err = tmuxResolvePaneTarget(rc, target)
		} else {
			wsId, err = tmuxResolveWorkspaceTarget(rc, target)
		}
	} else {
		wsId, err = tmuxResolveWorkspaceTarget(rc, "")
	}
	if err != nil {
		return err
	}

	if layoutName == "main-vertical" || layoutName == "main-horizontal" {
		orientation := "vertical"
		if layoutName == "main-horizontal" {
			orientation = "horizontal"
		}
		rc.call("workspace.equalize_splits", map[string]any{
			"workspace_id": wsId,
			"orientation":  orientation,
		})
	} else {
		rc.call("workspace.equalize_splits", map[string]any{"workspace_id": wsId})
	}

	return nil
}

func tmuxShowBuffer(args []string) error {
	p := parseTmuxArgs(args, []string{"-b"}, nil)
	name := p.value("-b")
	if name == "" {
		name = "default"
	}
	store := loadTmuxCompatStore()
	if buf, ok := store.Buffers[name]; ok {
		fmt.Print(buf)
	}
	return nil
}

func tmuxSaveBuffer(args []string) error {
	p := parseTmuxArgs(args, []string{"-b"}, nil)
	name := p.value("-b")
	if name == "" {
		name = "default"
	}
	store := loadTmuxCompatStore()
	buf, ok := store.Buffers[name]
	if !ok {
		return fmt.Errorf("buffer not found: %s", name)
	}
	if len(p.positional) > 0 {
		outputPath := strings.TrimSpace(p.positional[len(p.positional)-1])
		if outputPath != "" {
			return os.WriteFile(outputPath, []byte(buf), 0644)
		}
	}
	fmt.Print(buf)
	return nil
}
