// Run supervision: starting agent.sh with the agent's profile, stopping
// with the same process-group discipline as agent.sh's own watchdog,
// and a 1s watcher that adopts runs started by others (cron, a
// terminal), fires deliver-now nudges, and pushes fleet snapshots over
// SSE. History is a bounded in-memory ring — the session files and
// agent.log are the durable record.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var (
	errNotRunning   = &apiErr{Code: 409, Msg: "no live run for this agent"}
	errTaskRequired = &apiErr{Code: 400, Msg: "task is required"}
)

type Run struct {
	ID         int64      `json:"id"`
	Agent      string     `json:"agent"`
	Task       string     `json:"task,omitempty"`
	Source     string     `json:"source"` // manual | create | nudge | schedule:<id> | external
	Pid        int        `json:"pid"`
	StartedAt  time.Time  `json:"started_at"`
	FinishedAt *time.Time `json:"finished_at,omitempty"`
	ExitCode   *int       `json:"exit_code,omitempty"`
	LogStart   int64      `json:"log_start"`
	LogEnd     *int64     `json:"log_end,omitempty"`
}

const histCap = 500

type runner struct {
	fleet *fleet
	conf  *config
	log   *slog.Logger

	mu      sync.Mutex
	live    map[string]*Run // runs we spawned, by agent
	ext     map[string]*Run // runs someone else started, by agent
	nudges  map[string]bool // agents owed a deliver-now wake
	hist    []*Run          // newest last, capped
	nextID  int64
	last    string // last broadcast fleet snapshot
	clients map[chan []byte]bool
}

func newRunner(f *fleet, conf *config, log *slog.Logger) *runner {
	return &runner{
		fleet: f, conf: conf, log: log,
		live: map[string]*Run{}, ext: map[string]*Run{}, nudges: map[string]bool{},
		nextID: 1, clients: map[chan []byte]bool{},
	}
}

// env returns the environment for an agent's run: the process env with
// the control-plane secrets scrubbed — except for the overseer, the
// one agent that gets them — plus the agent's profile.env overrides.
func (rn *runner) env(name, dir string) []string {
	env := []string{}
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "ADMIN_TOKEN=") || strings.HasPrefix(kv, "SUPERADMIN_API=") {
			continue
		}
		env = append(env, kv)
	}
	for k, v := range readProfile(dir) {
		env = append(env, k+"="+v) // later entries win in exec env
	}
	// the grant comes last so a stray profile.env line can't shadow it
	if name == rn.conf.Overseer {
		apiURL := "http://127.0.0.1" + rn.conf.Addr[strings.LastIndex(rn.conf.Addr, ":"):]
		env = append(env, "SUPERADMIN_API="+apiURL)
		if rn.conf.AdminToken != "" {
			env = append(env, "ADMIN_TOKEN="+rn.conf.AdminToken)
		}
	}
	return env
}

// start launches one blocking agent.sh run, detached into its own
// session (Setsid), output appended to agent.log. Busy agents are
// refused up front; a lost race just means agent.sh exits 75 and the
// run records it honestly.
func (rn *runner) start(name, task, source string) (*Run, error) {
	a, err := rn.fleet.get(name)
	if err != nil {
		return nil, err
	}
	if a.SessionState == stateConflict {
		return nil, errConflict78
	}
	rn.mu.Lock()
	_, mine := rn.live[name]
	rn.mu.Unlock()
	if mine || a.Running {
		return nil, errBusy.with("hint", "queue a message instead (POST /messages) — appending is always safe")
	}

	logPath := filepath.Join(a.Dir, "agent.log")
	var logStart int64
	if st, err := os.Stat(logPath); err == nil {
		logStart = st.Size()
	}
	logf, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}

	cmd := exec.Command("./agent.sh", task)
	cmd.Dir = a.Dir
	cmd.Env = rn.env(name, a.Dir)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		logf.Close()
		return nil, err
	}

	r := &Run{
		Agent: name, Task: task, Source: source, Pid: cmd.Process.Pid,
		StartedAt: time.Now().UTC(), LogStart: logStart,
	}
	rn.mu.Lock()
	r.ID = rn.nextID
	rn.nextID++
	rn.hist = append(rn.hist, r)
	if len(rn.hist) > histCap {
		rn.hist = rn.hist[len(rn.hist)-histCap:]
	}
	rn.live[name] = r
	rn.mu.Unlock()

	go func() {
		defer logf.Close()
		exit := exitCode(cmd.Wait())
		now := time.Now().UTC()
		rn.mu.Lock()
		r.FinishedAt, r.ExitCode = &now, &exit
		if st, err := os.Stat(logPath); err == nil {
			n := st.Size()
			r.LogEnd = &n
		}
		delete(rn.live, name)
		rn.mu.Unlock()
		rn.log.Info("run finished", "agent", name, "exit", exit)
	}()
	return r, nil
}

// stop: SIGTERM to the process group, SIGKILL after a grace period —
// agent.sh's own watchdog discipline. The lock dir is never touched.
func (rn *runner) stop(name string) error {
	rn.mu.Lock()
	r := rn.live[name]
	rn.mu.Unlock()

	pid := 0
	if r != nil {
		pid = r.Pid
	} else {
		a, err := rn.fleet.get(name)
		if err != nil {
			return err
		}
		if !a.Running {
			return errNotRunning
		}
		pid = a.Pid // external run: the lock's owner
	}
	if err := syscall.Kill(-pid, syscall.SIGTERM); err != nil {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	go func() {
		time.Sleep(2 * time.Second)
		if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}()
	return nil
}

// nudge arms deliver-now: the watcher fires a "process pending
// messages" run the moment the agent's lock frees.
func (rn *runner) nudge(name string) {
	rn.mu.Lock()
	rn.nudges[name] = true
	rn.mu.Unlock()
}

// watch is one loop behind three features: external-run tracking,
// deliver-now nudges, and SSE fleet snapshots.
func (rn *runner) watch(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			rn.tick()
		}
	}
}

func (rn *runner) tick() {
	agents, err := rn.fleet.scan()
	if err != nil {
		rn.log.Error("scan", "err", err)
		return
	}
	byName := map[string]Agent{}
	for _, a := range agents {
		byName[a.Name] = a
	}

	var fire []string
	rn.mu.Lock()
	for _, a := range agents {
		if a.Running && rn.live[a.Name] == nil {
			if e := rn.ext[a.Name]; e == nil || e.Pid != a.Pid {
				r := &Run{
					ID: rn.nextID, Agent: a.Name, Source: "external", Pid: a.Pid,
					StartedAt: time.Now().UTC(), LogStart: a.LogSize,
				}
				rn.nextID++
				rn.hist = append(rn.hist, r)
				rn.ext[a.Name] = r
			}
		}
	}
	for name, e := range rn.ext {
		if a, ok := byName[name]; !ok || !a.Running || a.Pid != e.Pid {
			now := time.Now().UTC()
			e.FinishedAt = &now
			if ok {
				n := a.LogSize
				e.LogEnd = &n
			}
			delete(rn.ext, name)
		}
	}
	if len(rn.hist) > histCap {
		rn.hist = rn.hist[len(rn.hist)-histCap:]
	}
	for name := range rn.nudges {
		if a, ok := byName[name]; ok && !a.Running && rn.live[name] == nil {
			delete(rn.nudges, name)
			fire = append(fire, name)
		}
	}
	rn.mu.Unlock()

	for _, name := range fire {
		if _, err := rn.start(name, "Process any pending messages above.", "nudge"); err != nil {
			rn.log.Error("nudge", "agent", name, "err", err)
		}
	}

	if snap, err := json.Marshal(map[string]any{"agents": agents}); err == nil {
		if s := string(snap); s != rn.last {
			rn.last = s
			rn.broadcast(snap)
		}
	}
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// ---- SSE --------------------------------------------------------------

func (rn *runner) broadcast(data []byte) {
	rn.mu.Lock()
	defer rn.mu.Unlock()
	for ch := range rn.clients {
		select {
		case ch <- data:
		default: // slow client: skip; the next snapshot supersedes
		}
	}
}

func (rn *runner) handleEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", 500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")

	ch := make(chan []byte, 8)
	rn.mu.Lock()
	rn.clients[ch] = true
	rn.mu.Unlock()
	defer func() {
		rn.mu.Lock()
		delete(rn.clients, ch)
		rn.mu.Unlock()
	}()

	if agents, err := rn.fleet.scan(); err == nil {
		snap, _ := json.Marshal(map[string]any{"agents": agents})
		fmt.Fprintf(w, "event: fleet\ndata: %s\n\n", snap)
		fl.Flush()
	}
	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case data := <-ch:
			fmt.Fprintf(w, "event: fleet\ndata: %s\n\n", data)
			fl.Flush()
		case <-heartbeat.C:
			fmt.Fprint(w, ": ping\n\n")
			fl.Flush()
		}
	}
}

// ---- HTTP -------------------------------------------------------------

func (rn *runner) handleRun(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Task string `json:"task"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Task) == "" {
		fail(w, errTaskRequired)
		return
	}
	run, err := rn.start(r.PathValue("name"), req.Task, "manual")
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 201, map[string]any{"run": run})
}

func (rn *runner) handleStop(w http.ResponseWriter, r *http.Request) {
	if err := rn.stop(r.PathValue("name")); err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true})
}

func (rn *runner) handleRuns(w http.ResponseWriter, r *http.Request) {
	agent := r.URL.Query().Get("agent")
	limit := 100
	if n, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && n > 0 && n <= histCap {
		limit = n
	}
	out := []Run{}
	rn.mu.Lock()
	for i := len(rn.hist) - 1; i >= 0 && len(out) < limit; i-- {
		if agent == "" || rn.hist[i].Agent == agent {
			out = append(out, *rn.hist[i])
		}
	}
	rn.mu.Unlock()
	reply(w, 200, map[string]any{"runs": out})
}

const tailChunk = 64 * 1024

// handleLog serves the agent's log: a JSON tail by default, a live SSE
// stream with ?follow=1, or one run's byte slice via ?from/?to.
func (rn *runner) handleLog(w http.ResponseWriter, r *http.Request) {
	a, err := rn.fleet.get(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	logPath := filepath.Join(a.Dir, "agent.log")
	q := r.URL.Query()

	if from, err := strconv.ParseInt(q.Get("from"), 10, 64); err == nil {
		to := int64(-1)
		if t, err := strconv.ParseInt(q.Get("to"), 10, 64); err == nil {
			to = t
		}
		content, size := readSlice(logPath, from, to)
		reply(w, 200, map[string]any{"content": content, "size": size})
		return
	}

	lines := 200
	if n, err := strconv.Atoi(q.Get("lines")); err == nil && n > 0 && n <= 5000 {
		lines = n
	}
	content, size := tailLines(logPath, lines)
	if q.Get("follow") != "1" {
		reply(w, 200, map[string]any{"content": content, "size": size})
		return
	}

	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", 500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	chunk, _ := json.Marshal(content)
	fmt.Fprintf(w, "event: log\ndata: %s\n\n", chunk)
	fl.Flush()
	offset := size
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-t.C:
			st, err := os.Stat(logPath)
			if err != nil {
				continue
			}
			if st.Size() < offset {
				offset = 0 // truncated/rotated: start over
			}
			if st.Size() > offset {
				delta, _ := readSlice(logPath, offset, st.Size())
				offset = st.Size()
				chunk, _ := json.Marshal(delta)
				fmt.Fprintf(w, "event: log\ndata: %s\n\n", chunk)
				fl.Flush()
			}
		}
	}
}

func tailLines(path string, n int) (string, int64) {
	st, err := os.Stat(path)
	if err != nil {
		return "", 0
	}
	from := st.Size() - tailChunk
	if from < 0 {
		from = 0
	}
	content, size := readSlice(path, from, st.Size())
	lines := strings.Split(content, "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n"), size
}

func readSlice(path string, from, to int64) (string, int64) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return "", 0
	}
	if to < 0 || to > st.Size() {
		to = st.Size()
	}
	if from < 0 {
		from = 0
	}
	if from >= to {
		return "", st.Size()
	}
	if to-from > 4*tailChunk { // cap a single response at 256 KiB
		from = to - 4*tailChunk
	}
	buf := make([]byte, to-from)
	if _, err := f.ReadAt(buf, from); err != nil {
		return "", st.Size()
	}
	return string(buf), st.Size()
}
