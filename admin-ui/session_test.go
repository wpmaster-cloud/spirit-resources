package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func msg(role, content string) map[string]any {
	return map[string]any{"role": role, "content": content}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestValidatePairing(t *testing.T) {
	asst := func(ids ...string) Envelope {
		return Envelope{Role: "assistant", CallIDs: ids}
	}
	tool := func(id string) Envelope { return Envelope{Role: "tool", ToolCallID: id} }
	sys := Envelope{Role: "system"}
	user := Envelope{Role: "user"}

	cases := []struct {
		name      string
		envs      []Envelope
		wantErrs  int
		wantWarns int
	}{
		{"clean turn", []Envelope{sys, user, asst("a"), tool("a")}, 0, 0},
		{"in-flight tail allowed", []Envelope{sys, asst("a")}, 0, 0},
		{"orphan tool result", []Envelope{sys, tool("ghost")}, 1, 0},
		{"duplicate result", []Envelope{sys, asst("a"), tool("a"), tool("a")}, 1, 0},
		{"new calls over unanswered", []Envelope{sys, asst("a"), asst("b"), tool("b")}, 1, 0},
		{"queued append mid-turn warns", []Envelope{sys, asst("a"), user, tool("a")}, 0, 1},
		{"no system prompt warns", []Envelope{user}, 0, 1},
	}
	for _, c := range cases {
		errs, warns := validateSession(c.envs)
		if len(errs) != c.wantErrs || len(warns) != c.wantWarns {
			t.Errorf("%s: got %d errs %d warns, want %d/%d (%v %v)",
				c.name, len(errs), len(warns), c.wantErrs, c.wantWarns, errs, warns)
		}
	}
}

func TestSaveRoundTripIsBytePerfect(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "session.jsonl")
	// deliberately odd formatting the normalizer would change:
	// unsorted keys, a float with trailing zero, unicode escape
	original := `{"role":"system","kind":"message","content":"You are x","weird":1.50,"u":"<"}` + "\n" +
		`{"kind":"message","created_at":"2026-01-01T00:00:00Z","role":"user","content":"hi"}` + "\n"
	writeFile(t, file, original)

	doc, err := readSession(file)
	if err != nil {
		t.Fatal(err)
	}
	// simulate the client sending everything back unedited (_raw kept)
	var msgs []map[string]any
	for _, r := range doc.Records {
		msgs = append(msgs, map[string]any{"_raw": string(r.Raw)})
	}
	res, err := saveSession(file, SaveInput{Messages: msgs, BaseETag: doc.ETag, BaseSize: doc.Size})
	if err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(file)
	if string(after) != original {
		t.Fatalf("round trip changed bytes:\n%q\n%q", original, string(after))
	}
	if res.Backup == "" {
		t.Fatal("expected a backup")
	}
}

func TestSaveRebasesPureAppends(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "session.jsonl")
	writeFile(t, file, `{"kind":"message","role":"system","content":"You are x"}`+"\n")

	doc, _ := readSession(file)
	baseETag, baseSize := doc.ETag, doc.Size

	// a sibling agent queues a message while the editor is open
	if _, err := appendMessage(file, "user", "queued by another agent"); err != nil {
		t.Fatal(err)
	}

	// the editor saves an edit from its stale base
	res, err := saveSession(file, SaveInput{
		Messages: []map[string]any{msg("system", "You are x, edited")},
		BaseETag: baseETag, BaseSize: baseSize,
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Rebased != 1 {
		t.Fatalf("rebased = %d, want 1", res.Rebased)
	}
	after, _ := os.ReadFile(file)
	if !strings.Contains(string(after), "queued by another agent") {
		t.Fatal("the queued append was clobbered")
	}
	if !strings.Contains(string(after), "edited") {
		t.Fatal("the edit was lost")
	}
}

func TestSaveConflictsOnNonAppendChange(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "session.jsonl")
	writeFile(t, file, `{"kind":"message","role":"system","content":"v1"}`+"\n")
	doc, _ := readSession(file)

	// out-of-band rewrite (not an append)
	writeFile(t, file, `{"kind":"message","role":"system","content":"v2-rewritten"}`+"\n")

	_, err := saveSession(file, SaveInput{
		Messages: []map[string]any{msg("system", "v3")},
		BaseETag: doc.ETag, BaseSize: doc.Size,
	})
	if !errors.Is(err, errStaleBase) {
		t.Fatalf("want errStaleBase, got %v", err)
	}
}

func TestSaveRejectsBrokenPairing(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "session.jsonl")
	_, err := saveSession(file, SaveInput{Messages: []map[string]any{
		msg("system", "x"),
		{"role": "tool", "tool_call_id": "orphan", "content": "{}"},
	}})
	if !errors.Is(err, errInvalidSession) {
		t.Fatalf("want errInvalidSession, got %v", err)
	}
}

func TestSaveRefusesLocked(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "session.jsonl")
	writeFile(t, file, `{"kind":"message","role":"system","content":"x"}`+"\n")
	// fake a live lock owned by this test process
	if err := os.Mkdir(file+".lock", 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(file+".lock", "pid"), strconv.Itoa(os.Getpid()))

	doc, _ := readSession(file)
	_, err := saveSession(file, SaveInput{Messages: []map[string]any{msg("system", "y")}, BaseETag: doc.ETag, BaseSize: doc.Size})
	if !errors.Is(err, errLocked) {
		t.Fatalf("want errLocked, got %v", err)
	}
	// force overrides, same as resources/ui
	if _, err := saveSession(file, SaveInput{Messages: []map[string]any{msg("system", "y")}, Force: true}); err != nil {
		t.Fatalf("force save failed: %v", err)
	}
}

func TestDiscover(t *testing.T) {
	dir := t.TempDir()
	if _, state, _ := discoverSession(dir); state != stateMissing {
		t.Fatalf("empty dir: want missing, got %s", state)
	}
	writeFile(t, filepath.Join(dir, "session-x-1.jsonl"), "")
	if f, state, _ := discoverSession(dir); state != stateOK || !strings.HasSuffix(f, "session-x-1.jsonl") {
		t.Fatalf("single named: got %s %s", state, f)
	}
	writeFile(t, filepath.Join(dir, "session-x-2.jsonl"), "")
	if _, state, m := discoverSession(dir); state != stateConflict || len(m) != 2 {
		t.Fatalf("two named: want conflict/2, got %s/%d", state, len(m))
	}
	// legacy always wins
	writeFile(t, filepath.Join(dir, "session.jsonl"), "")
	if f, state, _ := discoverSession(dir); state != stateOK || !strings.HasSuffix(f, "session.jsonl") {
		t.Fatalf("legacy: got %s %s", state, f)
	}
}
