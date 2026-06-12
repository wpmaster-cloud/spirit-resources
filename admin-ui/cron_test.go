package main

import (
	"testing"
	"time"
)

func at(s string) time.Time {
	t, err := time.Parse("2006-01-02T15:04:05Z", s)
	if err != nil {
		panic(err)
	}
	return t
}

func TestParseSpecEvery(t *testing.T) {
	next, err := parseSpec("@every 15m")
	if err != nil {
		t.Fatal(err)
	}
	got := next(at("2026-06-11T10:00:00Z"))
	if want := at("2026-06-11T10:15:00Z"); !got.Equal(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	if _, err := parseSpec("@every 10s"); err == nil {
		t.Fatal("sub-minute interval must be refused")
	}
	if _, err := parseSpec("@every nonsense"); err == nil {
		t.Fatal("bad duration must be refused")
	}
}

func TestParseSpecCron(t *testing.T) {
	cases := []struct {
		spec, from, want string
	}{
		{"*/5 * * * *", "2026-06-11T10:02:30Z", "2026-06-11T10:05:00Z"},
		{"0 9 * * *", "2026-06-11T10:00:00Z", "2026-06-12T09:00:00Z"},
		// 2026-06-12 is a Friday; the next weekday 09:00 after Friday 09:00 is Monday the 15th
		{"0 9 * * 1-5", "2026-06-12T09:00:00Z", "2026-06-15T09:00:00Z"},
		{"30 8,18 * * *", "2026-06-11T09:00:00Z", "2026-06-11T18:30:00Z"},
		{"0 0 1 * *", "2026-06-11T00:00:00Z", "2026-07-01T00:00:00Z"},
	}
	for _, c := range cases {
		next, err := parseSpec(c.spec)
		if err != nil {
			t.Fatalf("%s: %v", c.spec, err)
		}
		if got := next(at(c.from)); !got.Equal(at(c.want)) {
			t.Errorf("%s after %s: got %v want %s", c.spec, c.from, got, c.want)
		}
	}
}

func TestParseSpecCronExclusiveLowerBound(t *testing.T) {
	// nextAfter must be STRICTLY after t, or a due schedule re-fires
	next, _ := parseSpec("0 9 * * *")
	got := next(at("2026-06-11T09:00:00Z"))
	if want := at("2026-06-12T09:00:00Z"); !got.Equal(want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestParseSpecRejects(t *testing.T) {
	for _, bad := range []string{"", "* * * *", "60 * * * *", "* 24 * * *", "x * * * *", "5-1 * * * *"} {
		if _, err := parseSpec(bad); err == nil {
			t.Errorf("%q must be refused", bad)
		}
	}
}
