// Templates: reusable session blueprints as files —
// <root>/.admin/templates/<name>.jsonl holds records whose
// {{VAR}} placeholders are substituted at agent creation. No registry,
// no versions: the folder IS the template list, and git (or backups)
// is the history.
package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var (
	errTmplNotFound = &apiErr{Code: 404, Msg: "template not found"}
	errTmplInvalid  = &apiErr{Code: 400, Msg: "template needs a name (lowercase a-z 0-9 dashes) and at least one record"}
)

var varRx = regexp.MustCompile(`\{\{([A-Z][A-Z0-9_]*)\}\}`)

type templates struct {
	dir string
}

func newTemplates(root string) *templates {
	return &templates{dir: filepath.Join(root, ".admin", "templates")}
}

type TemplateInfo struct {
	Name    string   `json:"name"`
	Records int      `json:"records"`
	Vars    []string `json:"vars"`
}

func (t *templates) path(name string) (string, error) {
	if !nameRx.MatchString(name) {
		return "", errTmplInvalid
	}
	return filepath.Join(t.dir, name+".jsonl"), nil
}

func (t *templates) list() []TemplateInfo {
	matches, _ := filepath.Glob(filepath.Join(t.dir, "*.jsonl"))
	sort.Strings(matches)
	out := []TemplateInfo{}
	for _, m := range matches {
		b, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		recs, _ := parseLines(b)
		vars := map[string]bool{}
		for _, match := range varRx.FindAllStringSubmatch(string(b), -1) {
			vars[match[1]] = true
		}
		names := make([]string, 0, len(vars))
		for v := range vars {
			names = append(names, v)
		}
		sort.Strings(names)
		out = append(out, TemplateInfo{
			Name: strings.TrimSuffix(filepath.Base(m), ".jsonl"), Records: len(recs), Vars: names,
		})
	}
	return out
}

func (t *templates) read(name string) ([]Record, error) {
	p, err := t.path(name)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, errTmplNotFound
	}
	recs, errs := parseLines(b)
	if len(errs) > 0 {
		return nil, errTmplInvalid.with("detail", "template file has unparseable lines")
	}
	return recs, nil
}

func (t *templates) save(name string, records []map[string]any) error {
	p, err := t.path(name)
	if err != nil {
		return err
	}
	if len(records) == 0 {
		return errTmplInvalid
	}
	var lines [][]byte
	for i, m := range records {
		line, _, err := toLine(m)
		if err != nil {
			return errBadRecord.with("index", i)
		}
		lines = append(lines, line)
	}
	if err := os.MkdirAll(t.dir, 0o755); err != nil {
		return err
	}
	return atomicWrite(p, joinLines(lines))
}

func (t *templates) delete(name string) error {
	p, err := t.path(name)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil {
		return errTmplNotFound
	}
	return nil
}

// render substitutes {{VAR}} through every string value (nested
// included). Unknown placeholders are left visible rather than
// silently blanked — a half-rendered prompt should look half-rendered.
func (t *templates) render(name string, vars map[string]string) ([]map[string]any, error) {
	recs, err := t.read(name)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, len(recs))
	for i, r := range recs {
		out[i] = substAny(r.Obj, vars).(map[string]any)
	}
	return out, nil
}

func substAny(v any, vars map[string]string) any {
	switch x := v.(type) {
	case string:
		for k, val := range vars {
			x = strings.ReplaceAll(x, "{{"+k+"}}", val)
		}
		return x
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[k] = substAny(val, vars)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = substAny(val, vars)
		}
		return out
	default:
		return v
	}
}

// ---- HTTP -------------------------------------------------------------

func (t *templates) handleList(w http.ResponseWriter, r *http.Request) {
	reply(w, 200, map[string]any{"templates": t.list()})
}

func (t *templates) handleSave(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name    string           `json:"name"`
		Records []map[string]any `json:"records"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		badJSON(w)
		return
	}
	if err := t.save(req.Name, req.Records); err != nil {
		fail(w, err)
		return
	}
	reply(w, 201, map[string]any{"ok": true, "name": req.Name})
}

func (t *templates) handleDelete(w http.ResponseWriter, r *http.Request) {
	if err := t.delete(r.PathValue("name")); err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true})
}
