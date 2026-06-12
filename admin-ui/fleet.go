// The fleet: an agent IS a folder under the agents root containing
// agent.sh. Scanning discovers, creating authors, archiving moves
// aside — nothing is mirrored anywhere, so an agent made by hand with
// mkdir appears immediately. Per-agent launch overrides live in the
// folder too (profile.env), because an agent is a folder.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

var (
	errAgentNotFound = &apiErr{Code: 404, Msg: "agent not found"}
	errBadName       = &apiErr{Code: 400, Msg: "agent name must be lowercase a-z, 0-9 and dashes (max 40)"}
	errAgentExists   = &apiErr{Code: 409, Msg: "agent already exists"}
	errBusy          = &apiErr{Code: 409, Msg: "agent is mid-run"}
	errConflict78    = &apiErr{Code: 409, Msg: "several session files in the agent folder (exit-78 state); keep exactly one"}
	errNotConflicted = &apiErr{Code: 409, Msg: "agent is not in the exit-78 conflict state"}
	errKeepInvalid   = &apiErr{Code: 400, Msg: "keep must name one of the conflicting session files"}
	errNoFile        = &apiErr{Code: 404, Msg: "no such file in the agent folder"}
)

// nameRx is the alphabet agent.sh normalizes AGENT_NAME to — and,
// having no separators or dots, also the path-traversal guard.
var nameRx = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,39}$`)

type Agent struct {
	Name         string   `json:"name"`
	Dir          string   `json:"dir"`
	SessionFile  string   `json:"session_file,omitempty"`
	SessionState string   `json:"session_state"` // ok | missing | conflict
	Conflicts    []string `json:"conflicts,omitempty"`
	Running      bool     `json:"running"`
	Pid          int      `json:"pid,omitempty"`
	Msgs         int      `json:"msgs"`
	Bytes        int64    `json:"bytes"`
	LastActivity string   `json:"last_activity,omitempty"`
	LastReply    string   `json:"last_reply,omitempty"`
	LogSize      int64    `json:"log_size"`
}

type fleet struct {
	root    string
	agentSh string
	tmpl    *templates // session blueprints for create; set by main

	// session-stat cache: a file with unchanged size+mtime is not
	// re-read, so the 1s watcher tick stays cheap.
	mu    sync.Mutex
	cache map[string]statEntry
}

type statEntry struct {
	size  int64
	mtime time.Time
	msgs  int
	last  string
	reply string
}

func newFleet(root, agentSh string) *fleet {
	return &fleet{root: root, agentSh: agentSh, cache: map[string]statEntry{}}
}

func (f *fleet) dir(name string) (string, error) {
	if !nameRx.MatchString(name) {
		return "", errBadName
	}
	return filepath.Join(f.root, name), nil
}

func (f *fleet) scan() ([]Agent, error) {
	entries, err := os.ReadDir(f.root)
	if err != nil {
		return nil, err
	}
	agents := []Agent{}
	for _, e := range entries {
		if !e.IsDir() || e.Name()[0] == '.' || !nameRx.MatchString(e.Name()) {
			continue
		}
		dir := filepath.Join(f.root, e.Name())
		if _, err := os.Stat(filepath.Join(dir, "agent.sh")); err != nil {
			continue // a folder without agent.sh is not an agent
		}
		agents = append(agents, f.inspect(e.Name(), dir))
	}
	return agents, nil
}

func (f *fleet) get(name string) (*Agent, error) {
	dir, err := f.dir(name)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(filepath.Join(dir, "agent.sh")); err != nil {
		return nil, errAgentNotFound
	}
	a := f.inspect(name, dir)
	return &a, nil
}

func (f *fleet) inspect(name, dir string) Agent {
	a := Agent{Name: name, Dir: dir}
	file, state, matches := discoverSession(dir)
	a.SessionState = state
	switch state {
	case stateConflict:
		a.Conflicts = matches
		for _, m := range matches { // any file may carry the lock
			if locked, pid := lockStatus(m); locked {
				a.Running, a.Pid = true, pid
				break
			}
		}
	default:
		a.SessionFile = file
		a.Running, a.Pid = lockStatus(file)
		if st, err := os.Stat(file); err == nil {
			a.Bytes = st.Size()
			a.Msgs, a.LastActivity, a.LastReply = f.stats(file, st.Size(), st.ModTime())
		}
	}
	if st, err := os.Stat(filepath.Join(dir, "agent.log")); err == nil {
		a.LogSize = st.Size()
	}
	return a
}

func (f *fleet) stats(file string, size int64, mtime time.Time) (int, string, string) {
	f.mu.Lock()
	if c, ok := f.cache[file]; ok && c.size == size && c.mtime.Equal(mtime) {
		f.mu.Unlock()
		return c.msgs, c.last, c.reply
	}
	f.mu.Unlock()

	doc, err := readSession(file)
	if err != nil {
		return 0, "", ""
	}
	c := statEntry{size: size, mtime: mtime, msgs: len(doc.Records)}
	for i := len(doc.Records) - 1; i >= 0; i-- {
		obj := doc.Records[i].Obj
		if c.last == "" {
			c.last, _ = obj["created_at"].(string)
		}
		if doc.Records[i].Env.Role == "assistant" {
			if txt, _ := obj["content"].(string); txt != "" {
				if r := []rune(txt); len(r) > 200 {
					txt = string(r[:200]) + "…"
				}
				c.reply = txt
				break
			}
		}
	}
	f.mu.Lock()
	f.cache[file] = c
	f.mu.Unlock()
	return c.msgs, c.last, c.reply
}

// create makes the folder, installs agent.sh, authors the session and
// profile. On any failure the half-made folder is removed.
func (f *fleet) create(name string, records []map[string]any, env map[string]string, link bool) (*Agent, error) {
	dir, err := f.dir(name)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(dir); err == nil {
		return nil, errAgentExists
	}
	if err := os.Mkdir(dir, 0o755); err != nil {
		return nil, err
	}
	cleanup := func(err error) (*Agent, error) { os.RemoveAll(dir); return nil, err }

	target := filepath.Join(dir, "agent.sh")
	if link {
		if err := os.Symlink(f.agentSh, target); err != nil {
			return cleanup(fmt.Errorf("symlink agent.sh: %w", err))
		}
	} else {
		b, err := os.ReadFile(f.agentSh)
		if err != nil {
			return cleanup(fmt.Errorf("read %s: %w", f.agentSh, err))
		}
		if err := os.WriteFile(target, b, 0o755); err != nil {
			return cleanup(err)
		}
	}
	if len(records) > 0 {
		// the legacy name — honored by agent.sh forever
		if err := authorNew(filepath.Join(dir, "session.jsonl"), records); err != nil {
			return cleanup(err)
		}
	}
	if len(env) > 0 {
		if err := writeProfile(dir, env); err != nil {
			return cleanup(err)
		}
	}
	a := f.inspect(name, dir)
	return &a, nil
}

// archive moves the agent folder to .archive/<name>-<stamp> — never a
// hard delete, and never while a run is live.
func (f *fleet) archive(name string) (string, error) {
	a, err := f.get(name)
	if err != nil {
		return "", err
	}
	if a.Running {
		return "", errBusy.with("pid", a.Pid)
	}
	archiveDir := filepath.Join(f.root, ".archive")
	if err := os.MkdirAll(archiveDir, 0o755); err != nil {
		return "", err
	}
	dest := filepath.Join(archiveDir, name+"-"+time.Now().UTC().Format("20060102T150405Z"))
	return dest, os.Rename(a.Dir, dest)
}

// resolveConflict executes a HUMAN's choice in the exit-78 state: the
// chosen file stays, every other session file is set aside by rename
// — out of agent.sh's glob, still on disk. Never auto-resolved.
func (f *fleet) resolveConflict(name, keep string) (kept string, setAside []string, err error) {
	a, err := f.get(name)
	if err != nil {
		return "", nil, err
	}
	if a.SessionState != stateConflict {
		return "", nil, errNotConflicted
	}
	keepPath := ""
	for _, m := range a.Conflicts {
		if filepath.Base(m) == filepath.Base(keep) {
			keepPath = m
		}
		if locked, pid := lockStatus(m); locked {
			return "", nil, errBusy.with("pid", pid)
		}
	}
	if keepPath == "" {
		return "", nil, errKeepInvalid.with("candidates", a.Conflicts)
	}
	stamp := time.Now().UTC().Format("20060102T150405Z")
	for _, m := range a.Conflicts {
		if m == keepPath {
			continue
		}
		dest := m + ".set-aside." + stamp
		if err := os.Rename(m, dest); err != nil {
			return "", setAside, err
		}
		setAside = append(setAside, filepath.Base(dest))
	}
	return filepath.Base(keepPath), setAside, nil
}

// ---- launch profile: agents/<name>/profile.env -----------------------

// Non-secret env overrides (MODEL, MAX_TURNS, …) for an agent's runs.
// LLM_API_KEY never goes here — keys live in the process env only.
func readProfile(dir string) map[string]string {
	env := map[string]string{}
	b, err := os.ReadFile(filepath.Join(dir, "profile.env"))
	if err != nil {
		return env
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok {
			env[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return env
}

func writeProfile(dir string, env map[string]string) error {
	delete(env, "LLM_API_KEY")
	path := filepath.Join(dir, "profile.env")
	if len(env) == 0 {
		err := os.Remove(path)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var buf bytes.Buffer
	for _, k := range keys {
		fmt.Fprintf(&buf, "%s=%s\n", k, env[k])
	}
	return atomicWrite(path, buf.Bytes())
}

// ---- workspace: read-only browsing of the agent folder ---------------

type FileEntry struct {
	Name    string `json:"name"`
	Path    string `json:"path"` // relative to the agent folder
	Dir     bool   `json:"dir"`
	Size    int64  `json:"size"`
	ModTime string `json:"mod_time"`
}

// resolvePath maps a client path into the agent folder; Clean("/"+rel)
// collapses any ".." before the join, so it cannot escape.
func (f *fleet) resolvePath(name, rel string) (abs, cleanRel string, err error) {
	dir, err := f.dir(name)
	if err != nil {
		return "", "", err
	}
	cleanRel = strings.TrimPrefix(filepath.Clean("/"+rel), "/")
	return filepath.Join(dir, cleanRel), cleanRel, nil
}

func (f *fleet) listFiles(name, rel string) ([]FileEntry, string, error) {
	abs, cleanRel, err := f.resolvePath(name, rel)
	if err != nil {
		return nil, "", err
	}
	entries, err := os.ReadDir(abs)
	if err != nil {
		return nil, "", errNoFile
	}
	out := []FileEntry{}
	for _, e := range entries {
		st, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, FileEntry{
			Name: e.Name(), Path: filepath.Join(cleanRel, e.Name()), Dir: e.IsDir(),
			Size: st.Size(), ModTime: st.ModTime().UTC().Format("2006-01-02T15:04:05Z"),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Dir != out[j].Dir {
			return out[i].Dir
		}
		return out[i].Name < out[j].Name
	})
	return out, cleanRel, nil
}

const fileViewCap = 256 * 1024

func (f *fleet) readFile(name, rel string) (content []byte, size int64, truncated, binary bool, err error) {
	abs, _, err := f.resolvePath(name, rel)
	if err != nil {
		return nil, 0, false, false, err
	}
	st, err := os.Stat(abs)
	if err != nil || st.IsDir() {
		return nil, 0, false, false, errNoFile
	}
	fh, err := os.Open(abs)
	if err != nil {
		return nil, 0, false, false, err
	}
	defer fh.Close()
	buf := make([]byte, fileViewCap+1)
	n, _ := fh.Read(buf)
	content = buf[:n]
	if len(content) > fileViewCap {
		content, truncated = content[:fileViewCap], true
	}
	return content, st.Size(), truncated, bytes.IndexByte(content, 0) >= 0, nil
}

// ---- the overseer -----------------------------------------------------

// ensureOverseer creates the fleet-managing agent if missing —
// idempotent; an existing folder of that name is returned untouched.
// Its runs alone receive SUPERADMIN_API (+ ADMIN_TOKEN); see runner.
func (f *fleet) ensureOverseer(name, apiURL string, hasToken bool) (*Agent, bool, error) {
	if a, err := f.get(name); err == nil {
		return a, false, nil
	}
	records := []map[string]any{{
		"kind": "message", "role": "system", "content": overseerPrompt(name, f.root, apiURL, hasToken),
	}}
	a, err := f.create(name, records, nil, false)
	if err != nil {
		return nil, false, err
	}
	return a, true, nil
}

func overseerPrompt(name, root, apiURL string, hasToken bool) string {
	auth := ""
	if hasToken {
		auth = ` Every call needs: -H "Authorization: Bearer $ADMIN_TOKEN" (it is in your env).`
	}
	return fmt.Sprintf(`You are %s, the OVERSEER — the spirit admin's own agent, living inside the control plane. Your job is to manage the fleet of spirit agents on behalf of the human operator.

The fleet lives at %s — each agent is a folder holding agent.sh, its session-*.jsonl (the agent's ENTIRE memory), optional profile.env (launch overrides), agent.log, and work files. Your own folder is your private workspace. You have two powers no other agent has:

1. THE SUPERADMIN API at %s — PREFER IT for anything it can do: it validates session invariants, backs up before every rewrite, and auto-rebases concurrent appends.%s
   - GET  /api/agents                      fleet with live status (running/idle/conflict)
   - POST /api/agents                      {"name":"x","records":[{"role":"system","content":"..."}],"env":{"MODEL":"..."},"autostart_task":"..."}
   - GET  /api/agents/N                    detail + profile        POST /api/agents/N/archive  (move aside, never delete)
   - GET|POST /api/agents/N/session        read / full-save (save carries base_etag+base_size)
   - POST /api/agents/N/messages           {"content":"...","deliver_now":true}  ← ALWAYS-SAFE, works mid-run;
                                           deliver_now auto-runs the agent the moment it goes idle
   - POST /api/agents/N/run {"task":".."}  409 = busy → queue a message instead    POST /api/agents/N/stop
   - GET  /api/agents/N/log?lines=200      GET /api/runs?agent=N
   - GET  /api/agents/N/backups            POST /api/agents/N/backups/<backup>/restore  (present backed up first)
   - GET  /api/agents/N/files?path=        GET /api/agents/N/file?path=   workspace browsing
   - PUT  /api/agents/N/file?path=         {"content":"..."} write a text file (e.g. patch an agent.sh)
   - POST /api/agents/N/resolve-conflict {"keep":"<file>"}  exit-78; ONLY when the human said which file wins
   - GET|POST /api/templates  DELETE /api/templates/{name}   session blueprints ({{VAR}} placeholders);
     create an agent from one: POST /api/agents {"name":"x","template":"researcher","vars":{"TOPIC":"..."}}
   - GET|POST /api/teams  DELETE /api/teams/{name}  POST /api/teams/{name}/launch
     a team = members [{template, name_pattern with {{N}}, count, vars, task, autostart}] — one call
     launches the whole composition
   - GET|POST /api/schedules  PUT|DELETE /api/schedules/{id}  POST /api/schedules/{id}/fire
     {"agent":"x","task":"...","spec":"@every 30m"} — spec is "@every <dur>" or 5-field cron, UTC.
     Schedule YOURSELF for standing duties (patrols, reports, cleanups).

2. THE FILESYSTEM — you may read any agent folder directly; the session invariants are sacred:
   build JSONL lines ONLY with jq -nc, never by hand; foreign or live sessions are APPEND-ONLY; an
   assistant record carrying tool_calls and its role:"tool" results are paired by id — breaking a pair
   makes the LLM API reject the agent's whole session; a <session>.lock/ directory means a run is live
   (exit 75 = busy, normal); NEVER delete a lock dir; several session-*.jsonl files in one folder is the
   exit-78 state — resolve via the API, never by deleting.

Rules: never write LLM_API_KEY or any secret to disk or into a session; prefer queueing (deliver_now) over stopping a live run; archive, never rm -rf, when retiring an agent; report what you did and found, precisely and briefly.`,
		name, root, apiURL, auth)
}

// ---- HTTP -------------------------------------------------------------

func (f *fleet) handleList(w http.ResponseWriter, r *http.Request) {
	agents, err := f.scan()
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"agents": agents})
}

type createReq struct {
	Name          string            `json:"name"`
	Records       []map[string]any  `json:"records"`
	Template      string            `json:"template"` // render records from a blueprint instead
	Vars          map[string]string `json:"vars"`
	Env           map[string]string `json:"env"`
	LinkScript    bool              `json:"link_script"`
	AutostartTask string            `json:"autostart_task"`
}

// createFrom is the one create path the HTTP handler and team launches
// share: resolve the template if named, author, optionally autostart.
func (f *fleet) createFrom(req createReq, rn *runner) (*Agent, map[string]any, error) {
	records := req.Records
	if req.Template != "" {
		vars := map[string]string{"AGENT_NAME": req.Name}
		for k, v := range req.Vars {
			vars[k] = v
		}
		var err error
		if records, err = f.tmpl.render(req.Template, vars); err != nil {
			return nil, nil, err
		}
	}
	a, err := f.create(req.Name, records, req.Env, req.LinkScript)
	if err != nil {
		return nil, nil, err
	}
	resp := map[string]any{"agent": a}
	if req.AutostartTask != "" {
		if _, err := rn.start(req.Name, req.AutostartTask, "create"); err != nil {
			resp["start_error"] = err.Error()
		} else {
			resp["started"] = true
		}
	}
	return a, resp, nil
}

func (f *fleet) handleCreate(w http.ResponseWriter, r *http.Request, rn *runner) {
	var req createReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		badJSON(w)
		return
	}
	_, resp, err := f.createFrom(req, rn)
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 201, resp)
}

func (f *fleet) handleDetail(w http.ResponseWriter, r *http.Request) {
	a, err := f.get(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"agent": a, "profile": readProfile(a.Dir)})
}

func (f *fleet) handleArchive(w http.ResponseWriter, r *http.Request) {
	dest, err := f.archive(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true, "archived_to": dest})
}

func (f *fleet) handleResolve(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Keep string `json:"keep"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Keep == "" {
		badJSON(w)
		return
	}
	kept, setAside, err := f.resolveConflict(r.PathValue("name"), req.Keep)
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true, "kept": kept, "set_aside": setAside})
}

// sessionFile resolves the agent's session, mapping conflict to its
// API error.
func (f *fleet) sessionFile(name string) (*Agent, string, error) {
	a, err := f.get(name)
	if err != nil {
		return nil, "", err
	}
	if a.SessionState == stateConflict {
		return nil, "", errConflict78.with("matches", a.Conflicts)
	}
	return a, a.SessionFile, nil
}

func (f *fleet) handleGetSession(w http.ResponseWriter, r *http.Request) {
	_, file, err := f.sessionFile(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	doc, err := readSession(file)
	if err != nil {
		fail(w, err)
		return
	}
	msgs := make([]map[string]any, len(doc.Records))
	for i, rec := range doc.Records {
		m := make(map[string]any, len(rec.Obj)+1)
		for k, v := range rec.Obj {
			m[k] = v
		}
		m["_raw"] = string(rec.Raw)
		msgs[i] = m
	}
	reply(w, 200, map[string]any{
		"session_file": doc.File, "exists": doc.Exists, "messages": msgs,
		"errors": doc.Errors, "locked": doc.Locked, "lock_owner": doc.LockOwner,
		"etag": doc.ETag, "size": doc.Size,
	})
}

func (f *fleet) handleSaveSession(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Messages []map[string]any `json:"messages"`
		BaseETag string           `json:"base_etag"`
		BaseSize int64            `json:"base_size"`
		Force    bool             `json:"force"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Messages == nil {
		badJSON(w)
		return
	}
	_, file, err := f.sessionFile(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	res, err := saveSession(file, SaveInput{
		Messages: req.Messages, BaseETag: req.BaseETag, BaseSize: req.BaseSize, Force: req.Force,
	})
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, res)
}

// handleAppend queues one message — the always-safe channel, no lock
// needed. deliver_now arms the nudge: the watcher fires a run the
// moment the agent goes idle.
func (f *fleet) handleAppend(w http.ResponseWriter, r *http.Request, rn *runner) {
	var req struct {
		Role       string `json:"role"`
		Content    string `json:"content"`
		DeliverNow bool   `json:"deliver_now"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		badJSON(w)
		return
	}
	if req.Role == "" {
		req.Role = "user"
	}
	if req.Content == "" || (req.Role != "user" && req.Role != "system" && req.Role != "assistant") {
		reply(w, 400, map[string]any{"error": "content required; role must be user, system or assistant"})
		return
	}
	a, file, err := f.sessionFile(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	rec, err := appendMessage(file, req.Role, req.Content)
	if err != nil {
		fail(w, err)
		return
	}
	resp := map[string]any{"ok": true, "appended": rec}
	if a.SessionState == stateMissing {
		resp["warning"] = "session did not exist; the appended line created it, so agent.sh will NOT seed a system prompt"
	}
	if req.DeliverNow {
		rn.nudge(a.Name)
		resp["nudge_armed"] = true
	}
	reply(w, 200, resp)
}

func (f *fleet) handlePutProfile(w http.ResponseWriter, r *http.Request) {
	var env map[string]string
	if err := json.NewDecoder(r.Body).Decode(&env); err != nil {
		badJSON(w)
		return
	}
	a, err := f.get(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	if err := writeProfile(a.Dir, env); err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true, "env": env})
}

func (f *fleet) handleBackups(w http.ResponseWriter, r *http.Request) {
	_, file, err := f.sessionFile(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"backups": listBackups(file)})
}

func (f *fleet) handleRestore(w http.ResponseWriter, r *http.Request) {
	_, file, err := f.sessionFile(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	res, err := restoreBackup(file, r.PathValue("backup"))
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, res)
}

func (f *fleet) handleFiles(w http.ResponseWriter, r *http.Request) {
	files, rel, err := f.listFiles(r.PathValue("name"), r.URL.Query().Get("path"))
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"path": rel, "files": files})
}

func (f *fleet) handleFile(w http.ResponseWriter, r *http.Request) {
	name, rel := r.PathValue("name"), r.URL.Query().Get("path")
	if r.URL.Query().Get("download") == "1" {
		abs, _, err := f.resolvePath(name, rel)
		if err != nil {
			fail(w, err)
			return
		}
		if st, err := os.Stat(abs); err != nil || st.IsDir() {
			fail(w, errNoFile)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", `attachment; filename="`+filepath.Base(abs)+`"`)
		http.ServeFile(w, r, abs)
		return
	}
	content, size, truncated, binary, err := f.readFile(name, rel)
	if err != nil {
		fail(w, err)
		return
	}
	body := map[string]any{"size": size, "truncated": truncated, "binary": binary}
	if !binary {
		body["content"] = string(content)
	}
	reply(w, 200, body)
}

const fileWriteCap = 1 << 20 // 1 MiB: scripts, prompts, configs — not data

// handleWriteFile writes one text file inside the agent folder — the
// "patch agent.sh from the UI" power. Session files are refused: they
// have their own guarded write path (etag + rebase + backup); this one
// preserves the file mode (agent.sh must stay executable) and backs up
// the previous content next to it.
func (f *fleet) handleWriteFile(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Content) > fileWriteCap {
		badJSON(w)
		return
	}
	abs, cleanRel, err := f.resolvePath(r.PathValue("name"), r.URL.Query().Get("path"))
	if err != nil {
		fail(w, err)
		return
	}
	if cleanRel == "" {
		fail(w, errNoFile)
		return
	}
	if strings.Contains(filepath.Base(cleanRel), ".jsonl") {
		reply(w, 400, map[string]any{"error": "session files have their own guarded API — use /session and /backups"})
		return
	}
	mode := os.FileMode(0o644)
	backup := ""
	if st, err := os.Stat(abs); err == nil {
		if st.IsDir() {
			fail(w, errNoFile)
			return
		}
		mode = st.Mode()
		if prev, err := os.ReadFile(abs); err == nil {
			backup = abs + ".bak." + time.Now().UTC().Format("20060102T150405Z")
			if err := os.WriteFile(backup, prev, mode); err != nil {
				fail(w, err)
				return
			}
		}
	}
	tmp := fmt.Sprintf("%s.tmp.%d", abs, os.Getpid())
	if err := os.WriteFile(tmp, []byte(req.Content), mode); err != nil {
		fail(w, err)
		return
	}
	if err := os.Rename(tmp, abs); err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true, "size": len(req.Content), "backup": filepath.Base(backup)})
}
