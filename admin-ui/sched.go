// Schedules: standing tasks on a timetable, persisted as one JSON file
// under the agents root (.superadmin/schedules.json — no database).
// At each due moment the task starts like a manual run; when the agent
// is mid-run and queue_if_busy is set, it is appended + nudged instead,
// so nothing is lost to the busy signal. Missed moments (server down)
// are skipped, cron semantics, never replayed in a burst.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	errSchedNotFound = &apiErr{Code: 404, Msg: "schedule not found"}
	errSchedInvalid  = &apiErr{Code: 400, Msg: "agent, task and a valid spec are required"}
	errBadSpec       = &apiErr{Code: 400, Msg: `spec must be "@every <duration>" (min 1m) or 5-field cron, UTC`}
)

type Schedule struct {
	ID          int64      `json:"id"`
	Agent       string     `json:"agent"`
	Task        string     `json:"task"`
	Spec        string     `json:"spec"`
	Enabled     bool       `json:"enabled"`
	QueueIfBusy bool       `json:"queue_if_busy"`
	LastFired   *time.Time `json:"last_fired,omitempty"`
	LastResult  string     `json:"last_result,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	NextAt      *time.Time `json:"next_at,omitempty"` // computed, not persisted
}

type scheduler struct {
	path string
	rn   *runner
	log  *slog.Logger

	mu    sync.Mutex
	items []*Schedule
	next  map[int64]time.Time // armed fire times; reset on edit
}

func newScheduler(root string, rn *runner, log *slog.Logger) (*scheduler, error) {
	s := &scheduler{
		path: filepath.Join(root, ".superadmin", "schedules.json"),
		rn:   rn, log: log, next: map[int64]time.Time{},
	}
	b, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	return s, json.Unmarshal(b, &s.items)
}

// persist writes the schedule file atomically; callers hold s.mu.
func (s *scheduler) persist() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(s.items, "", " ")
	return atomicWrite(s.path, b)
}

func (s *scheduler) validate(it *Schedule) error {
	if strings.TrimSpace(it.Agent) == "" || strings.TrimSpace(it.Task) == "" {
		return errSchedInvalid
	}
	if _, err := parseSpec(it.Spec); err != nil {
		return errBadSpec.with("detail", err.Error())
	}
	return nil
}

// loop arms newly-seen schedules for their NEXT moment (never an
// immediate catch-up fire) and fires the due ones.
func (s *scheduler) loop(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.tick()
		}
	}
}

func (s *scheduler) tick() {
	now := time.Now().UTC()
	var due []*Schedule
	s.mu.Lock()
	alive := map[int64]bool{}
	for _, it := range s.items {
		alive[it.ID] = true
		if !it.Enabled {
			delete(s.next, it.ID)
			continue
		}
		nextFn, err := parseSpec(it.Spec)
		if err != nil {
			continue // refused at write time; never fires
		}
		nx, armed := s.next[it.ID]
		if !armed {
			s.next[it.ID] = nextFn(now)
			continue
		}
		if now.Before(nx) {
			continue
		}
		s.next[it.ID] = nextFn(now)
		due = append(due, it)
	}
	for id := range s.next { // deleted rows must not keep firing
		if !alive[id] {
			delete(s.next, id)
		}
	}
	s.mu.Unlock()

	for _, it := range due {
		s.fire(it, "")
	}
}

// fire starts the run — or queues + nudges on busy when allowed — and
// records the outcome on the schedule.
func (s *scheduler) fire(it *Schedule, suffix string) (string, error) {
	source := fmt.Sprintf("schedule:%d", it.ID)
	result := "started"
	_, err := s.rn.start(it.Agent, it.Task, source)
	if err != nil && errors.Is(err, errBusy) && it.QueueIfBusy {
		_, file, ferr := s.rn.fleet.sessionFile(it.Agent)
		if ferr == nil {
			_, ferr = appendMessage(file, "user", it.Task)
		}
		if ferr == nil {
			s.rn.nudge(it.Agent)
			result, err = "queued", nil
		} else {
			err = ferr
		}
	}
	if err != nil {
		result = "error: " + err.Error()
		s.log.Error("schedule fire", "id", it.ID, "agent", it.Agent, "err", err)
	}
	now := time.Now().UTC()
	s.mu.Lock()
	it.LastFired, it.LastResult = &now, result+suffix
	_ = s.persist()
	s.mu.Unlock()
	return result, err
}

func (s *scheduler) find(id int64) *Schedule {
	for _, it := range s.items {
		if it.ID == id {
			return it
		}
	}
	return nil
}

func (s *scheduler) decorate(it *Schedule) Schedule {
	cp := *it
	if nx, ok := s.next[it.ID]; ok && it.Enabled {
		cp.NextAt = &nx
	}
	return cp
}

// ---- HTTP -------------------------------------------------------------

func schedID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil && id > 0
}

func (s *scheduler) handleList(w http.ResponseWriter, r *http.Request) {
	agent := r.URL.Query().Get("agent")
	out := []Schedule{}
	s.mu.Lock()
	for _, it := range s.items {
		if agent == "" || it.Agent == agent {
			out = append(out, s.decorate(it))
		}
	}
	s.mu.Unlock()
	reply(w, 200, map[string]any{"schedules": out})
}

func (s *scheduler) handleCreate(w http.ResponseWriter, r *http.Request) {
	it := &Schedule{Enabled: true, QueueIfBusy: true}
	if err := json.NewDecoder(r.Body).Decode(it); err != nil {
		badJSON(w)
		return
	}
	if err := s.validate(it); err != nil {
		fail(w, err)
		return
	}
	s.mu.Lock()
	for _, x := range s.items {
		if x.ID >= it.ID {
			it.ID = x.ID + 1
		}
	}
	if it.ID == 0 {
		it.ID = 1
	}
	it.CreatedAt = time.Now().UTC()
	s.items = append(s.items, it)
	err := s.persist()
	out := s.decorate(it)
	s.mu.Unlock()
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 201, map[string]any{"schedule": out})
}

func (s *scheduler) handleUpdate(w http.ResponseWriter, r *http.Request) {
	id, ok := schedID(r)
	if !ok {
		fail(w, errSchedNotFound)
		return
	}
	s.mu.Lock()
	it := s.find(id)
	if it == nil {
		s.mu.Unlock()
		fail(w, errSchedNotFound)
		return
	}
	// decode over the current row: omitted fields keep their values,
	// so a bare {"enabled":false} is a valid toggle
	cp := *it
	s.mu.Unlock()
	if err := json.NewDecoder(r.Body).Decode(&cp); err != nil {
		badJSON(w)
		return
	}
	cp.ID = id
	if err := s.validate(&cp); err != nil {
		fail(w, err)
		return
	}
	s.mu.Lock()
	*it = cp
	delete(s.next, id) // re-arm from the (possibly new) spec
	err := s.persist()
	out := s.decorate(it)
	s.mu.Unlock()
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"schedule": out})
}

func (s *scheduler) handleDelete(w http.ResponseWriter, r *http.Request) {
	id, ok := schedID(r)
	if !ok {
		fail(w, errSchedNotFound)
		return
	}
	s.mu.Lock()
	found := false
	items := s.items[:0]
	for _, it := range s.items {
		if it.ID == id {
			found = true
			continue
		}
		items = append(items, it)
	}
	s.items = items
	delete(s.next, id)
	var err error
	if found {
		err = s.persist()
	}
	s.mu.Unlock()
	if !found {
		fail(w, errSchedNotFound)
		return
	}
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true})
}

func (s *scheduler) handleFire(w http.ResponseWriter, r *http.Request) {
	id, ok := schedID(r)
	if !ok {
		fail(w, errSchedNotFound)
		return
	}
	s.mu.Lock()
	it := s.find(id)
	s.mu.Unlock()
	if it == nil {
		fail(w, errSchedNotFound)
		return
	}
	result, err := s.fire(it, " (manual)")
	if err != nil {
		fail(w, err)
		return
	}
	reply(w, 200, map[string]any{"ok": true, "result": result})
}

// ---- specs --------------------------------------------------------------

// Two dialects, both UTC:
//
//	@every <duration>   — interval, armed from "now" each fire ("@every 15m")
//	m h dom mon dow     — five-field cron: * */n a a-b a,b-c ("0 9 * * 1-5")
//
// parseSpec returns a nextAfter func: the first moment strictly after t.
func parseSpec(spec string) (func(time.Time) time.Time, error) {
	spec = strings.TrimSpace(spec)
	if rest, ok := strings.CutPrefix(spec, "@every "); ok {
		d, err := time.ParseDuration(strings.TrimSpace(rest))
		if err != nil {
			return nil, fmt.Errorf("@every: %w", err)
		}
		if d < time.Minute {
			return nil, fmt.Errorf("@every: minimum interval is 1m, got %s", d)
		}
		return func(t time.Time) time.Time { return t.Add(d) }, nil
	}
	c, err := parseCron(spec)
	if err != nil {
		return nil, err
	}
	return c.nextAfter, nil
}

type cron struct {
	min, hour, dom, mon, dow map[int]bool
}

var cronRanges = [5]struct{ lo, hi int }{{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 6}}

func parseCron(spec string) (*cron, error) {
	fields := strings.Fields(spec)
	if len(fields) != 5 {
		return nil, fmt.Errorf(`want 5 cron fields or "@every <duration>", got %d field(s)`, len(fields))
	}
	var sets [5]map[int]bool
	for i, f := range fields {
		set, err := parseCronField(f, cronRanges[i].lo, cronRanges[i].hi)
		if err != nil {
			return nil, fmt.Errorf("field %d (%q): %w", i+1, f, err)
		}
		sets[i] = set
	}
	return &cron{min: sets[0], hour: sets[1], dom: sets[2], mon: sets[3], dow: sets[4]}, nil
}

// parseCronField handles *, */step, a, a-b, a-b/step and comma lists.
func parseCronField(f string, lo, hi int) (map[int]bool, error) {
	set := map[int]bool{}
	for _, part := range strings.Split(f, ",") {
		body, stepStr, hasStep := strings.Cut(part, "/")
		step := 1
		if hasStep {
			n, err := strconv.Atoi(stepStr)
			if err != nil || n < 1 {
				return nil, fmt.Errorf("bad step %q", stepStr)
			}
			step = n
		}
		from, to := lo, hi
		if body != "*" {
			a, b, isRange := strings.Cut(body, "-")
			n, err := strconv.Atoi(a)
			if err != nil {
				return nil, fmt.Errorf("bad value %q", a)
			}
			from, to = n, n
			if isRange {
				m, err := strconv.Atoi(b)
				if err != nil {
					return nil, fmt.Errorf("bad value %q", b)
				}
				to = m
			} else if hasStep {
				to = hi // "a/step" means a..hi by step, cron convention
			}
		}
		if from < lo || to > hi || from > to {
			return nil, fmt.Errorf("out of range %d-%d (allowed %d-%d)", from, to, lo, hi)
		}
		for v := from; v <= to; v += step {
			set[v] = true
		}
	}
	return set, nil
}

func (c *cron) matches(t time.Time) bool {
	return c.min[t.Minute()] && c.hour[t.Hour()] && c.dom[t.Day()] &&
		c.mon[int(t.Month())] && c.dow[int(t.Weekday())]
}

// nextAfter scans minute by minute — at most a year of map lookups;
// simplicity over cleverness.
func (c *cron) nextAfter(t time.Time) time.Time {
	t = t.UTC().Truncate(time.Minute).Add(time.Minute)
	limit := t.AddDate(1, 0, 1)
	for ; t.Before(limit); t = t.Add(time.Minute) {
		if c.matches(t) {
			return t
		}
	}
	return time.Time{} // unsatisfiable; never fires
}
