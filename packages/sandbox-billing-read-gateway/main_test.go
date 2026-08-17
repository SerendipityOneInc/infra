package main

import (
	"context"
	"database/sql"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
)

type fakeStore struct {
	events []rawEvent
	err    error
}

func (f *fakeStore) QueryTerminalEvents(context.Context, pageQuery) ([]rawEvent, error) {
	return f.events, f.err
}
func (f *fakeStore) Ping(context.Context) error { return f.err }
func (f *fakeStore) QueryMissingTerminal(context.Context) (uint64, *time.Time, error) {
	return 0, nil, f.err
}
func (f *fakeStore) Close() error { return nil }

func newTestServer(store eventStore, now time.Time) *server {
	return &server{store: store, currentToken: "01234567890123456789012345678901", queryTimeout: time.Second, now: func() time.Time { return now }, logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func TestEventsAuthenticatesAndNormalizes(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	id := uuid.New()
	store := &fakeStore{events: []rawEvent{{
		ID: id, Version: "v2", Type: "sandbox.lifecycle.paused", Timestamp: now.Add(-time.Hour),
		SandboxID: "sbx-1", SandboxExecutionID: "exec-1", SandboxTemplateID: "tpl-1",
		SandboxBuildID: "build-1", SandboxTeamID: uuid.New(),
		EventData: sql.NullString{Valid: true, String: `{"execution":{"started_at":"2026-08-17T10:00:00Z","execution_time":3600000,"vcpu_count":2,"memory_mb":2048}}`},
	}}}
	svc := newTestServer(store, now)

	req := httptest.NewRequest(http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z&limit=10", nil)
	req.Header.Set("Authorization", "Bearer "+svc.currentToken)
	res := httptest.NewRecorder()
	svc.handler().ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
	}
	want := `"event_type":"paused"`
	if body := res.Body.String(); !contains(body, want) || !contains(body, `"execution_time_ms":3600000`) {
		t.Fatalf("unexpected body: %s", body)
	}
}

func TestEventsRejectsMissingAuth(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	res := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z", nil)
	newTestServer(&fakeStore{}, now).handler().ServeHTTP(res, req)
	if res.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d", res.Code)
	}
}

func TestMalformedExecutionDoesNotBlockPage(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	store := &fakeStore{events: []rawEvent{{ID: uuid.New(), Type: "sandbox.lifecycle.killed", Timestamp: now.Add(-time.Hour), SandboxTeamID: uuid.New(), EventData: sql.NullString{Valid: true, String: `{"execution":{"vcpu_count":"bad"}}`}}}}
	svc := newTestServer(store, now)
	req := httptest.NewRequest(http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z", nil)
	req.Header.Set("Authorization", "Bearer "+svc.currentToken)
	res := httptest.NewRecorder()
	svc.handler().ServeHTTP(res, req)
	if res.Code != http.StatusOK || !contains(res.Body.String(), `"execution":null`) {
		t.Fatalf("status = %d body = %s", res.Code, res.Body.String())
	}
}

func TestCursorPairRequired(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	req := httptest.NewRequest(http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z&after_id="+uuid.NewString(), nil)
	_, err := parsePageQuery(req, now)
	if err == nil {
		t.Fatal("expected cursor validation error")
	}
}

func contains(value, substring string) bool {
	for i := 0; i+len(substring) <= len(value); i++ {
		if value[i:i+len(substring)] == substring {
			return true
		}
	}
	return false
}
