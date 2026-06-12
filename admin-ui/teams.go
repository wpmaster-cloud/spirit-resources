// Teams: named multi-agent compositions, persisted as one JSON file
// (.admin/teams.json). A member is "count agents from a template":
// the name pattern's {{N}} numbers them, vars flow into the template,
// and an optional task starts each one on creation. Launching is just
// repeated agent creation — same path, same guarantees, one call.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var (
	errTeamNotFound = &apiErr{Code: 404, Msg: "team not found"}
	errTeamInvalid  = &apiErr{Code: 400, Msg: "team needs a name and members with template + name_pattern"}
)

type TeamMember struct {
	Template    string            `json:"template"`
	NamePattern string            `json:"name_pattern"` // {{N}} = member number
	Count       int               `json:"count"`
	Vars        map[string]string `json:"vars,omitempty"`
	Env         map[string]string `json:"env,omitempty"`
	Task        string            `json:"task,omitempty"` // autostart task
}

type Team struct {
	Name    string       `json:"name"`
	Members []TeamMember `json:"members"`
}

type teams struct {
	path string
	fl   *fleet
	rn   *runner

	mu    sync.Mutex
	items []*Team
}

func newTeams(root string, fl *fleet, rn *runner) (*teams, error) {
	t := &teams{path: filepath.Join(root, ".admin", "teams.json"), fl: fl, rn: rn}
	b, err := os.ReadFile(t.path)
	if errors.Is(err, os.ErrNotExist) {
		return t, nil
	}
	if err != nil {
		return nil, err
	}
	return t, json.Unmarshal(b, &t.items)
}

func (t *teams) persist() error {
	if err := os.MkdirAll(filepath.Dir(t.path), 0o755); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(t.items, "", " ")
	return atomicWrite(t.path, b)
}

func (t *teams) validate(tm *Team) error {
	if !nameRx.MatchString(tm.Name) || len(tm.Members) == 0 {
		return errTeamInvalid
	}
	for i := range tm.Members {
		m := &tm.Members[i]
		if m.Template == "" || m.NamePattern == "" {
			return errTeamInvalid
		}
		if m.Count < 1 {
			m.Count = 1
		}
		if _, err := t.fl.tmpl.read(m.Template); err != nil {
			return err
		}
	}
	return nil
}

// LaunchResult reports one agent of the launch — creations are
// independent, so one failure (e.g. name taken) never aborts the rest.
type LaunchResult struct {
	Agent   string `json:"agent"`
	Created bool   `json:"created"`
	Started bool   `json:"started,omitempty"`
	Error   string `json:"error,omitempty"`
}

func (t *teams) launch(tm *Team) []LaunchResult {
	out := []LaunchResult{}
	for _, m := range tm.Members {
		for n := 1; n <= m.Count; n++ {
			name := strings.ReplaceAll(m.NamePattern, "{{N}}", fmt.Sprint(n))
			res := LaunchResult{Agent: name}
			_, resp, err := t.fl.createFrom(createReq{
				Name: name, Template: m.Template, Vars: m.Vars, Env: m.Env, AutostartTask: m.Task,
			}, t.rn)
			if err != nil {
				res.Error = err.Error()
			} else {
				res.Created = true
				res.Started, _ = resp["started"].(bool)
				if e, ok := resp["start_error"].(string); ok {
					res.Error = e
				}
			}
			out = append(out, res)
		}
	}
	return out
}

// ---- HTTP -------------------------------------------------------------

func (t *teams) find(name string) *Team {
	for _, tm := range t.items {
		if tm.Name == name {
			return tm
		}
	}
	return nil
}

func (t *teams) handleList(w http.ResponseWriter, r *http.Request) {
	t.mu.Lock()
	defer t.mu.Unlock()
	reply(w, 200, map[string]any{"teams": t.items})
}

// handleSave upserts by name — a team is a named value, not a row.
func (t *teams) handleSave(w http.ResponseWriter, r *http.Request) {
	var tm Team
	if err := json.NewDecoder(r.Body).Decode(&tm); err != nil {
		badJSON(w)
		return
	}
	if err := t.validate(&tm); err != nil {
		fail(w, err)
		return
	}
	t.mu.Lock()
	if cur := t.find(tm.Name); cur != nil {
		*cur = tm
	} else {
		t.items = append(t.items, &tm)
	}
	err := t.persist()
	t.mu.Unlock()
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 201, map[string]any{"ok": true, "team": tm})
}

func (t *teams) handleDelete(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	t.mu.Lock()
	found := false
	items := t.items[:0]
	for _, tm := range t.items {
		if tm.Name == name {
			found = true
			continue
		}
		items = append(items, tm)
	}
	t.items = items
	var err error
	if found {
		err = t.persist()
	}
	t.mu.Unlock()
	if !found {
		fail(w, errTeamNotFound)
		return
	}
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true})
}

func (t *teams) handleLaunch(w http.ResponseWriter, r *http.Request) {
	t.mu.Lock()
	tm := t.find(r.PathValue("name"))
	t.mu.Unlock()
	if tm == nil {
		fail(w, errTeamNotFound)
		return
	}
	reply(w, 200, map[string]any{"results": t.launch(tm)})
}
