// Session files — the spirit agent's entire memory, replayed verbatim
// to the model. Design rules, in order:
//
//  1. Byte-perfect round-trips: an unedited record is written back
//     verbatim from its original line bytes (_raw), so editing one
//     message produces a one-line diff.
//  2. Lost updates are impossible: saves carry the base file's sha256
//     + size; a file that merely grew (pure appends — the fleet's
//     normal communication) is rebased automatically; anything else
//     is a 412.
//  3. Mirror agent.sh exactly: same discovery order, same lock
//     protocol, same backup naming, same atomic write.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var (
	errLocked         = &apiErr{Code: 409, Msg: "session is locked by a live agent run"}
	errStaleBase      = &apiErr{Code: 412, Msg: "session changed since it was loaded; reload and reapply"}
	errInvalidSession = &apiErr{Code: 400, Msg: "records violate session invariants"}
	errBadRecord      = &apiErr{Code: 400, Msg: "record is not a JSON object"}
	errSessionExists  = &apiErr{Code: 409, Msg: "session file already exists"}
	errBadBackup      = &apiErr{Code: 400, Msg: "not a backup of this session"}
	errNoBackup       = &apiErr{Code: 404, Msg: "backup not found"}
)

// Record is one parsed line: verbatim bytes plus the envelope the
// invariants care about and the parsed object for API responses.
type Record struct {
	Raw []byte
	Obj map[string]any
	Env Envelope
}

type Envelope struct {
	Kind       string
	Role       string
	ToolCallID string   // role:"tool" — which call this answers
	CallIDs    []string // role:"assistant" — ids of its tool_calls
}

// IsMessage mirrors agent.sh's is_msg: kind absent or "message".
func (e Envelope) IsMessage() bool { return e.Kind == "" || e.Kind == "message" }

type ParseError struct {
	Line  int    `json:"line"`
	Error string `json:"error"`
	Raw   string `json:"raw"`
}

type Doc struct {
	File      string
	Exists    bool
	Records   []Record
	Errors    []ParseError
	Locked    bool
	LockOwner int
	ETag      string
	Size      int64
}

func utcNow() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

func etagOf(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func readSession(file string) (*Doc, error) {
	d := &Doc{File: file, Errors: []ParseError{}}
	d.Locked, d.LockOwner = lockStatus(file)
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return d, nil
	}
	if err != nil {
		return nil, err
	}
	d.Exists = true
	d.ETag = etagOf(b)
	d.Size = int64(len(b))
	d.Records, d.Errors = parseLines(b)
	return d, nil
}

// parseLines reports unparseable lines instead of dropping them (a
// save would lose them); the error slice is always non-nil because it
// is marshaled straight into API responses.
func parseLines(b []byte) ([]Record, []ParseError) {
	var recs []Record
	errs := []ParseError{}
	for i, line := range strings.Split(string(b), "\n") {
		t := strings.TrimSpace(line)
		if t == "" {
			continue
		}
		var obj map[string]any
		if err := json.Unmarshal([]byte(t), &obj); err != nil || obj == nil {
			msg := "line is not a JSON object"
			if err != nil {
				msg = err.Error()
			}
			errs = append(errs, ParseError{Line: i + 1, Error: msg, Raw: t})
			continue
		}
		recs = append(recs, Record{Raw: []byte(t), Obj: obj, Env: envelopeOf(obj)})
	}
	return recs, errs
}

func envelopeOf(obj map[string]any) Envelope {
	e := Envelope{}
	e.Kind, _ = obj["kind"].(string)
	e.Role, _ = obj["role"].(string)
	e.ToolCallID, _ = obj["tool_call_id"].(string)
	if calls, ok := obj["tool_calls"].([]any); ok {
		for _, c := range calls {
			if m, ok := c.(map[string]any); ok {
				if id, ok := m["id"].(string); ok {
					e.CallIDs = append(e.CallIDs, id)
				}
			}
		}
	}
	return e
}

// ---- locks (mirror agent.sh's acquire_session_lock from outside) ----

// lockStatus: a `<session>.lock/` dir whose pid file names a live
// process means a run is in flight. A dead owner reads as unlocked
// (agent.sh takes over its own stale locks; we never touch them).
func lockStatus(sessionFile string) (locked bool, owner int) {
	b, err := os.ReadFile(filepath.Join(sessionFile+".lock", "pid"))
	if err != nil {
		return false, 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 0 {
		return false, 0
	}
	return pidAlive(pid), pid
}

func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// ---- discovery (mirror agent.sh's resolve_session_file) -------------

const (
	stateOK       = "ok"
	stateMissing  = "missing"  // no session yet; the agent self-seeds on first run
	stateConflict = "conflict" // several session-*.jsonl: agent.sh exits 78
)

func discoverSession(dir string) (file, state string, matches []string) {
	legacy := filepath.Join(dir, "session.jsonl")
	if st, err := os.Stat(legacy); err == nil && !st.IsDir() {
		return legacy, stateOK, nil
	}
	matches, _ = filepath.Glob(filepath.Join(dir, "session-*.jsonl"))
	sort.Strings(matches)
	switch len(matches) {
	case 0:
		return legacy, stateMissing, nil
	case 1:
		return matches[0], stateOK, matches
	default:
		return "", stateConflict, matches
	}
}

// ---- validation (the agent-workshop invariants) ----------------------

// validateSession enforces, before anything is written: every tool
// result answers an id from the most recent assistant tool_calls block
// exactly once; a new block may not start while one is unanswered;
// only the FINAL block may be left in flight (what compact_session
// deliberately preserves). Interleaved user/system messages inside an
// in-flight block are a warning — queued appends land there.
func validateSession(envs []Envelope) (errs, warns []string) {
	pending := map[string]bool{}
	pendingLine := 0
	for i, e := range envs {
		if !e.IsMessage() {
			continue
		}
		line := i + 1
		switch {
		case e.Role == "tool":
			if e.ToolCallID == "" {
				errs = append(errs, fmt.Sprintf("record %d: tool result without tool_call_id", line))
			} else if !pending[e.ToolCallID] {
				errs = append(errs, fmt.Sprintf("record %d: tool result %q answers no pending tool call (orphaned or duplicate)", line, e.ToolCallID))
			} else {
				delete(pending, e.ToolCallID)
			}
		case e.Role == "assistant" && len(e.CallIDs) > 0:
			if len(pending) > 0 {
				errs = append(errs, fmt.Sprintf("record %d: new tool_calls while record %d still has %d unanswered result(s) — this breaks the pairing", line, pendingLine, len(pending)))
			}
			pending = map[string]bool{}
			for _, id := range e.CallIDs {
				pending[id] = true
			}
			pendingLine = line
		default:
			if len(pending) > 0 {
				warns = append(warns, fmt.Sprintf("record %d: %s message inside an in-flight tool turn (started at record %d)", line, e.Role, pendingLine))
			}
		}
	}
	if len(envs) > 0 && envs[0].IsMessage() && envs[0].Role != "system" {
		warns = append(warns, "first record is not a system message — the agent will run without a system prompt")
	}
	return errs, warns
}

// ---- writing ----------------------------------------------------------

type SaveInput struct {
	Messages []map[string]any
	BaseETag string
	BaseSize int64
	Force    bool
}

type SaveResult struct {
	OK       bool     `json:"ok"`
	Backup   string   `json:"backup,omitempty"`
	Count    int      `json:"count"`
	Rebased  int      `json:"rebased"`
	Warnings []string `json:"warnings,omitempty"`
	ETag     string   `json:"etag"`
	Size     int64    `json:"size"`
}

// saveSession rewrites the file with backup + atomic rename. A record
// carrying "_raw" is unedited and written back verbatim; the rest are
// normalized. If the file grew by pure appends since the client's base
// (prefix bytes hash to BaseETag), the new tail records are replayed
// onto the end instead of being clobbered.
func saveSession(file string, in SaveInput) (*SaveResult, error) {
	if locked, owner := lockStatus(file); locked && !in.Force {
		return nil, errLocked.with("lock_owner", owner)
	}
	cur, err := os.ReadFile(file)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	rebased := 0
	var tail []Record
	if exists && !in.Force {
		switch curTag := etagOf(cur); {
		case in.BaseETag == curTag:
			// clean save
		case in.BaseETag != "" && in.BaseSize > 0 && int64(len(cur)) > in.BaseSize &&
			etagOf(cur[:in.BaseSize]) == in.BaseETag:
			var tailErrs []ParseError
			tail, tailErrs = parseLines(cur[in.BaseSize:])
			if len(tailErrs) > 0 {
				return nil, errStaleBase.with("detail", "appended tail has unparseable lines")
			}
			rebased = len(tail)
		default:
			return nil, errStaleBase.with("current_etag", curTag)
		}
	}

	lines := make([][]byte, 0, len(in.Messages)+len(tail))
	envs := make([]Envelope, 0, cap(lines))
	for i, m := range in.Messages {
		line, env, err := toLine(m)
		if err != nil {
			return nil, errBadRecord.with("index", i)
		}
		lines = append(lines, line)
		envs = append(envs, env)
	}
	for _, r := range tail {
		lines = append(lines, r.Raw)
		envs = append(envs, r.Env)
	}
	errsList, warns := validateSession(envs)
	if len(errsList) > 0 {
		return nil, errInvalidSession.with("problems", errsList)
	}

	res := &SaveResult{OK: true, Count: len(lines), Rebased: rebased, Warnings: warns}
	if exists {
		res.Backup = file + ".bak." + time.Now().UTC().Format("20060102T150405Z")
		if err := os.WriteFile(res.Backup, cur, 0o644); err != nil {
			return nil, fmt.Errorf("backup: %w", err)
		}
	}
	body := joinLines(lines)
	if err := atomicWrite(file, body); err != nil {
		return nil, err
	}
	res.ETag = etagOf(body)
	res.Size = int64(len(body))
	return res, nil
}

// authorNew writes a brand-new session (agent creation). Refuses to
// touch an existing file: never overwrite a history.
func authorNew(file string, messages []map[string]any) error {
	if _, err := os.Stat(file); err == nil {
		return errSessionExists
	}
	var lines [][]byte
	var envs []Envelope
	for i, m := range messages {
		line, env, err := toLine(m)
		if err != nil {
			return errBadRecord.with("index", i)
		}
		lines = append(lines, line)
		envs = append(envs, env)
	}
	if errsList, _ := validateSession(envs); len(errsList) > 0 {
		return errInvalidSession.with("problems", errsList)
	}
	return atomicWrite(file, joinLines(lines))
}

// appendMessage queues one message with a single O_APPEND write — the
// same atomicity the shell's `>>` gives jq, and why queueing is safe
// even while a run holds the lock.
func appendMessage(file, role, content string) (map[string]any, error) {
	rec := map[string]any{"kind": "message", "created_at": utcNow(), "role": role, "content": content}
	line, _, err := toLine(rec)
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	_, err = f.Write(append(line, '\n'))
	return rec, err
}

func joinLines(lines [][]byte) []byte {
	body := bytes.Join(lines, []byte("\n"))
	if len(body) > 0 {
		body = append(body, '\n')
	}
	return body
}

func atomicWrite(file string, body []byte) error {
	tmp := fmt.Sprintf("%s.tmp.%d", file, os.Getpid())
	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}

// toLine turns one client record into its on-disk line + envelope.
// "_raw" present → verbatim bytes (checked to parse); else normalize
// (default kind/created_at, drop _keys) and marshal with canonical key
// order — deterministic where JS object order is not.
func toLine(m map[string]any) ([]byte, Envelope, error) {
	if raw, ok := m["_raw"].(string); ok {
		t := strings.TrimSpace(raw)
		var obj map[string]any
		if err := json.Unmarshal([]byte(t), &obj); err != nil || obj == nil {
			return nil, Envelope{}, fmt.Errorf("_raw is not a JSON object")
		}
		return []byte(t), envelopeOf(obj), nil
	}

	rec := make(map[string]any, len(m)+2)
	for k, v := range m {
		if !strings.HasPrefix(k, "_") {
			rec[k] = v
		}
	}
	if _, ok := rec["kind"]; !ok {
		rec["kind"] = "message"
	}
	if s, _ := rec["created_at"].(string); s == "" {
		rec["created_at"] = utcNow()
	}

	keys := make([]string, 0, len(rec))
	seen := map[string]bool{}
	for _, k := range []string{"kind", "created_at", "role", "content"} {
		if _, ok := rec[k]; ok {
			keys = append(keys, k)
			seen[k] = true
		}
	}
	var rest []string
	for k := range rec {
		if !seen[k] {
			rest = append(rest, k)
		}
	}
	sort.Strings(rest)
	keys = append(keys, rest...)

	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			buf.WriteByte(',')
		}
		kb, _ := json.Marshal(k)
		buf.Write(kb)
		buf.WriteByte(':')
		vb, err := marshalValue(rec[k])
		if err != nil {
			return nil, Envelope{}, err
		}
		buf.Write(vb)
	}
	buf.WriteByte('}')
	return buf.Bytes(), envelopeOf(rec), nil
}

// marshalValue is compact JSON without HTML escaping, matching jq's
// output style (agent.sh builds every line with jq).
func marshalValue(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// ---- backups: time travel ---------------------------------------------

// Every save and compaction leaves `<session>.bak.<stamp>` behind;
// restoring one backs up the present first, so going back never burns
// the bridge forward. Nothing is ever deleted.

type Backup struct {
	Name    string `json:"name"`
	Size    int64  `json:"size"`
	ModTime string `json:"mod_time"`
}

func listBackups(file string) []Backup {
	matches, _ := filepath.Glob(file + ".bak.*")
	sort.Sort(sort.Reverse(sort.StringSlice(matches))) // stamp sorts lexically = newest first
	out := []Backup{}
	for _, m := range matches {
		if st, err := os.Stat(m); err == nil && !st.IsDir() {
			out = append(out, Backup{
				Name: filepath.Base(m), Size: st.Size(),
				ModTime: st.ModTime().UTC().Format("2006-01-02T15:04:05Z"),
			})
		}
	}
	return out
}

// restoreBackup rewrites the session from a backup, backing up the
// present first. Refused while a run holds the lock — rewriting a
// session mid-run corrupts the replay. The backup name is user input:
// it must be a plain name belonging to this very session.
func restoreBackup(file, backupName string) (*SaveResult, error) {
	if locked, owner := lockStatus(file); locked {
		return nil, errLocked.with("lock_owner", owner)
	}
	base := filepath.Base(file)
	if backupName != filepath.Base(backupName) || !strings.HasPrefix(backupName, base+".bak.") {
		return nil, errBadBackup
	}
	src := filepath.Join(filepath.Dir(file), backupName)
	body, err := os.ReadFile(src)
	if err != nil {
		return nil, errNoBackup
	}

	res := &SaveResult{OK: true}
	if cur, err := os.ReadFile(file); err == nil {
		res.Backup = file + ".bak." + time.Now().UTC().Format("20060102T150405Z")
		if err := os.WriteFile(res.Backup, cur, 0o644); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err := atomicWrite(file, body); err != nil {
		return nil, err
	}
	recs, _ := parseLines(body)
	res.Count = len(recs)
	res.ETag = etagOf(body)
	res.Size = int64(len(body))
	return res, nil
}
