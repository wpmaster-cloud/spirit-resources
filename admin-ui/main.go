// Spirit admin-ui — the fleet control plane in one binary.
//
// An agent is a folder under AGENTS_ROOT; its session-*.jsonl is its
// entire memory. This server scans, never mirrors: the filesystem is
// the single source of truth. What has no filesystem home lives in a
// small JSON file (schedules) or in memory (run history). The UI is
// embedded; the binary is the whole deployment.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type config struct {
	Addr       string // LISTEN_ADDR   default 127.0.0.1:8900 (yours, on your machine)
	Root       string // AGENTS_ROOT   the fleet folder; created if absent
	AgentSh    string // AGENT_SH_SOURCE  canonical agent.sh new agents copy
	AdminToken string // ADMIN_TOKEN   bearer for /api/* when set (health stays open)
	Overseer   string // OVERSEER_NAME the one agent granted the control-plane env
	WebDir     string // WEB_DIR       override the embedded UI (development)
}

func loadConfig() (*config, error) {
	c := &config{
		Addr:       getenv("LISTEN_ADDR", "127.0.0.1:8900"),
		Root:       getenv("AGENTS_ROOT", "../../agents"),
		AgentSh:    getenv("AGENT_SH_SOURCE", "../../agent/agent.sh"),
		AdminToken: getenv("ADMIN_TOKEN", ""),
		Overseer:   getenv("OVERSEER_NAME", "overseer"),
		WebDir:     getenv("WEB_DIR", ""),
	}
	for _, p := range []*string{&c.Root, &c.AgentSh} {
		abs, err := filepath.Abs(*p)
		if err != nil {
			return nil, err
		}
		*p = abs
	}
	if err := os.MkdirAll(c.Root, 0o755); err != nil {
		return nil, fmt.Errorf("create AGENTS_ROOT: %w", err)
	}
	return c, nil
}

func getenv(k, def string) string {
	if v, ok := os.LookupEnv(k); ok {
		return v
	}
	return def
}

func main() {
	conf, err := loadConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(1)
	}
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))

	fl := newFleet(conf.Root, conf.AgentSh)
	tm := newTemplates(conf.Root)
	fl.tmpl = tm
	rn := newRunner(fl, conf, log)
	sc, err := newScheduler(conf.Root, rn, log)
	if err != nil {
		fmt.Fprintln(os.Stderr, "schedules:", err)
		os.Exit(1)
	}
	te, err := newTeams(conf.Root, fl, rn)
	if err != nil {
		fmt.Fprintln(os.Stderr, "teams:", err)
		os.Exit(1)
	}
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	go rn.watch(ctx, time.Second)
	go sc.loop(ctx, 15*time.Second)

	apiURL := "http://127.0.0.1" + conf.Addr[strings.LastIndex(conf.Addr, ":"):]

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, map[string]any{"ok": true, "agents_root": conf.Root, "overseer": conf.Overseer})
	})
	mux.HandleFunc("POST /api/overseer", func(w http.ResponseWriter, r *http.Request) {
		a, created, err := fl.ensureOverseer(conf.Overseer, apiURL, conf.AdminToken != "")
		if err != nil {
			fail(w, err)
			return
		}
		code := 200
		if created {
			code = 201
		}
		reply(w, code, map[string]any{"agent": a, "created": created})
	})

	mux.HandleFunc("GET /api/agents", fl.handleList)
	mux.HandleFunc("POST /api/agents", func(w http.ResponseWriter, r *http.Request) { fl.handleCreate(w, r, rn) })
	mux.HandleFunc("GET /api/agents/{name}", fl.handleDetail)
	mux.HandleFunc("POST /api/agents/{name}/archive", fl.handleArchive)
	mux.HandleFunc("POST /api/agents/{name}/resolve-conflict", fl.handleResolve)
	mux.HandleFunc("GET /api/agents/{name}/session", fl.handleGetSession)
	mux.HandleFunc("POST /api/agents/{name}/session", fl.handleSaveSession)
	mux.HandleFunc("POST /api/agents/{name}/messages", func(w http.ResponseWriter, r *http.Request) { fl.handleAppend(w, r, rn) })
	mux.HandleFunc("PUT /api/agents/{name}/profile", fl.handlePutProfile)
	mux.HandleFunc("GET /api/agents/{name}/backups", fl.handleBackups)
	mux.HandleFunc("POST /api/agents/{name}/backups/{backup}/restore", fl.handleRestore)
	mux.HandleFunc("GET /api/agents/{name}/files", fl.handleFiles)
	mux.HandleFunc("GET /api/agents/{name}/file", fl.handleFile)
	mux.HandleFunc("PUT /api/agents/{name}/file", fl.handleWriteFile)

	mux.HandleFunc("POST /api/agents/{name}/run", rn.handleRun)
	mux.HandleFunc("POST /api/agents/{name}/stop", rn.handleStop)
	mux.HandleFunc("GET /api/agents/{name}/log", rn.handleLog)
	mux.HandleFunc("GET /api/runs", rn.handleRuns)
	mux.HandleFunc("GET /api/events", rn.handleEvents)

	mux.HandleFunc("GET /api/templates", tm.handleList)
	mux.HandleFunc("POST /api/templates", tm.handleSave)
	mux.HandleFunc("DELETE /api/templates/{name}", tm.handleDelete)

	mux.HandleFunc("GET /api/teams", te.handleList)
	mux.HandleFunc("POST /api/teams", te.handleSave)
	mux.HandleFunc("DELETE /api/teams/{name}", te.handleDelete)
	mux.HandleFunc("POST /api/teams/{name}/launch", te.handleLaunch)

	mux.HandleFunc("GET /api/schedules", sc.handleList)
	mux.HandleFunc("POST /api/schedules", sc.handleCreate)
	mux.HandleFunc("PUT /api/schedules/{id}", sc.handleUpdate)
	mux.HandleFunc("DELETE /api/schedules/{id}", sc.handleDelete)
	mux.HandleFunc("POST /api/schedules/{id}/fire", sc.handleFire)

	registerStatic(mux, conf.WebDir)

	srv := &http.Server{Addr: conf.Addr, Handler: withAuth(conf.AdminToken, mux)}
	errCh := make(chan error, 1)
	go func() {
		log.Info("admin-ui listening", "addr", conf.Addr, "agents_root", conf.Root)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	select {
	case s := <-sig:
		log.Info("shutting down", "signal", s.String())
	case err := <-errCh:
		log.Error("server error", "err", err)
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

// ---- errors & responses --------------------------------------------

// apiErr is the one error type: a status code, a message, optional
// structured context. Anything else collapses to a generic 500.
type apiErr struct {
	Code  int
	Msg   string
	Extra map[string]any
}

func (e *apiErr) Error() string { return e.Msg }

func (e *apiErr) with(k string, v any) *apiErr {
	extra := map[string]any{k: v}
	for k2, v2 := range e.Extra {
		extra[k2] = v2
	}
	return &apiErr{Code: e.Code, Msg: e.Msg, Extra: extra}
}

// Is matches with-derived copies back to their sentinel for errors.Is.
func (e *apiErr) Is(target error) bool {
	t, ok := target.(*apiErr)
	return ok && t.Code == e.Code && t.Msg == e.Msg
}

func fail(w http.ResponseWriter, err error) {
	var e *apiErr
	if !errors.As(err, &e) {
		e = &apiErr{Code: 500, Msg: "internal error"}
	}
	body := map[string]any{"error": e.Msg}
	for k, v := range e.Extra {
		body[k] = v
	}
	reply(w, e.Code, body)
}

func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func badJSON(w http.ResponseWriter) {
	reply(w, 400, map[string]any{"error": "invalid json body"})
}

// ---- auth -----------------------------------------------------------

// withAuth guards /api/* with a bearer token when ADMIN_TOKEN is set.
// EventSource can't set headers, so ?token= is accepted too; health
// stays open for probes.
func withAuth(token string, next http.Handler) http.Handler {
	if token == "" {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") && r.URL.Path != "/api/health" {
			if r.Header.Get("Authorization") != "Bearer "+token && r.URL.Query().Get("token") != token {
				reply(w, 401, map[string]any{"error": "unauthorized"})
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// ---- static UI -------------------------------------------------------

//go:embed all:web
var embeddedWeb embed.FS

// registerStatic serves the embedded UI (or WEB_DIR during
// development) with an SPA fallback to index.html.
func registerStatic(mux *http.ServeMux, webDir string) {
	var fsys fs.FS
	if webDir != "" {
		fsys = os.DirFS(webDir)
	} else {
		fsys, _ = fs.Sub(embeddedWeb, "web")
	}
	index, err := fs.ReadFile(fsys, "index.html")
	if err != nil {
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "admin-ui API is up; no UI bundled", 404)
		})
		return
	}
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(filepath.Clean("/"+r.URL.Path), "/")
		if name != "" && name != "index.html" {
			if f, err := fsys.Open(name); err == nil {
				f.Close()
				http.ServeFileFS(w, r, fsys, name)
				return
			}
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(index)
	})
}
