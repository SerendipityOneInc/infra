package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
)

type fakeStore struct {
	events        []rawEvent
	err           error
	lastQuery     pageQuery
	missingCount  uint64
	missingOldest *time.Time
}

func (f *fakeStore) QueryTerminalEvents(_ context.Context, query pageQuery) ([]rawEvent, error) {
	f.lastQuery = query

	return f.events, f.err
}
func (f *fakeStore) Ping(context.Context) error { return f.err }
func (f *fakeStore) QueryMissingTerminal(context.Context, time.Duration) (uint64, *time.Time, error) {
	return f.missingCount, f.missingOldest, f.err
}
func (f *fakeStore) Close() error { return nil }

func newTestServer(store eventStore, now time.Time) *server {
	return &server{store: store, currentToken: "01234567890123456789012345678901", queryTimeout: time.Second, maxRange: defaultMaxRange, now: func() time.Time { return now }, logger: slog.New(slog.DiscardHandler), limiter: newRequestLimiter(10, 20, now)}
}

func TestEventsAuthenticatesAndNormalizes(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	id := uuid.New()
	store := &fakeStore{events: []rawEvent{{
		ID: id, Version: "v2", Type: "sandbox.lifecycle.paused", Timestamp: now.Add(-time.Hour),
		SandboxID: "sbx-1", SandboxExecutionID: "exec-1", SandboxTemplateID: "tpl-1",
		SandboxBuildID: "build-1", SandboxTeamID: uuid.New(),
		ExecutionData: sql.NullString{Valid: true, String: `{"started_at":"2026-08-17T10:00:00Z","execution_time":3600000,"vcpu_count":2,"memory_mb":2048}`},
	}}}
	svc := newTestServer(store, now)

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z&limit=10", nil)
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
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	res := httptest.NewRecorder()
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z", nil)
	newTestServer(&fakeStore{}, now).handler().ServeHTTP(res, req)
	if res.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d", res.Code)
	}
}

func TestReadyReflectsClickHouseAvailability(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		name   string
		err    error
		status int
	}{
		{name: "available", status: http.StatusOK},
		{name: "unavailable", err: errors.New("internal ClickHouse detail"), status: http.StatusServiceUnavailable},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			res := httptest.NewRecorder()
			req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/ready", nil)
			newTestServer(&fakeStore{err: test.err}, now).handler().ServeHTTP(res, req)
			if res.Code != test.status {
				t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
			}
			if contains(res.Body.String(), "internal ClickHouse detail") {
				t.Fatalf("readiness response leaked source detail: %s", res.Body.String())
			}
		})
	}
}

func TestEventsMasksClickHouseFailure(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	svc := newTestServer(&fakeStore{err: errors.New("internal ClickHouse detail")}, now)
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z", nil)
	req.Header.Set("Authorization", "Bearer "+svc.currentToken)
	res := httptest.NewRecorder()
	svc.handler().ServeHTTP(res, req)

	if res.Code != http.StatusServiceUnavailable || !contains(res.Body.String(), `"error":"source_unavailable"`) {
		t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
	}
	if contains(res.Body.String(), "internal ClickHouse detail") {
		t.Fatalf("response leaked source detail: %s", res.Body.String())
	}
}

func TestRequestLogDoesNotExposeServiceToken(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	svc := newTestServer(&fakeStore{}, now)
	var output bytes.Buffer
	svc.logger = slog.New(slog.NewJSONHandler(&output, nil))
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z", nil)
	req.Header.Set("Authorization", "Bearer "+svc.currentToken)
	res := httptest.NewRecorder()
	svc.handler().ServeHTTP(res, req)

	log := output.String()
	if contains(log, svc.currentToken) || contains(log, "Authorization") {
		t.Fatalf("request log exposed service credentials: %s", log)
	}
}

func TestEventsAcceptsPreviousToken(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	svc := newTestServer(&fakeStore{}, now)
	svc.previousToken = "previous-token-012345678901234567"
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z", nil)
	req.Header.Set("Authorization", "Bearer "+svc.previousToken)
	res := httptest.NewRecorder()
	svc.handler().ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
	}
}

func TestUnauthorizedRequestsDoNotConsumeAuthenticatedRateLimit(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	svc := newTestServer(&fakeStore{}, now)
	svc.limiter = newRequestLimiter(0, 1, now)
	handler := svc.handler()
	url := "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z"

	for range 3 {
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, httptest.NewRequestWithContext(t.Context(), http.MethodGet, url, nil))
		if res.Code != http.StatusUnauthorized {
			t.Fatalf("unauthorized status = %d", res.Code)
		}
	}
	request := httptest.NewRequestWithContext(t.Context(), http.MethodGet, url, nil)
	request.Header.Set("Authorization", "Bearer "+svc.currentToken)
	res := httptest.NewRecorder()
	handler.ServeHTTP(res, request)
	if res.Code != http.StatusOK {
		t.Fatalf("first authenticated status = %d", res.Code)
	}

	request = httptest.NewRequestWithContext(t.Context(), http.MethodGet, url, nil)
	request.Header.Set("Authorization", "Bearer "+svc.currentToken)
	res = httptest.NewRecorder()
	handler.ServeHTTP(res, request)
	if res.Code != http.StatusTooManyRequests {
		t.Fatalf("second authenticated status = %d", res.Code)
	}
}

func TestMalformedExecutionDoesNotBlockPage(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	store := &fakeStore{events: []rawEvent{{
		ID: uuid.New(), Type: "sandbox.lifecycle.killed", Timestamp: now.Add(-time.Hour), SandboxTeamID: uuid.New(),
		ExecutionData: sql.NullString{Valid: true, String: `{"vcpu_count":"bad"}`},
		KillReason:    sql.NullString{Valid: true, String: "timeout"},
	}}}
	svc := newTestServer(store, now)
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z", nil)
	req.Header.Set("Authorization", "Bearer "+svc.currentToken)
	res := httptest.NewRecorder()
	svc.handler().ServeHTTP(res, req)
	if res.Code != http.StatusOK || !contains(res.Body.String(), `"execution":null`) || !contains(res.Body.String(), `"close_reason":"timeout"`) {
		t.Fatalf("status = %d body = %s", res.Code, res.Body.String())
	}
}

func TestCursorPairRequired(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z&after_id="+uuid.NewString(), nil)
	_, err := parsePageQuery(req, now, defaultMaxRange)
	if err == nil {
		t.Fatal("expected cursor validation error")
	}
}

func TestEventsReturnsCompositeCursorForSameTimestamp(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	timestamp := now.Add(-time.Hour)
	ids := []uuid.UUID{
		uuid.MustParse("00000000-0000-0000-0000-000000000001"),
		uuid.MustParse("00000000-0000-0000-0000-000000000002"),
		uuid.MustParse("00000000-0000-0000-0000-000000000003"),
	}
	store := &fakeStore{events: []rawEvent{
		{ID: ids[0], Type: "sandbox.lifecycle.paused", Timestamp: timestamp, SandboxTeamID: uuid.New()},
		{ID: ids[1], Type: "sandbox.lifecycle.paused", Timestamp: timestamp, SandboxTeamID: uuid.New()},
		{ID: ids[2], Type: "sandbox.lifecycle.paused", Timestamp: timestamp, SandboxTeamID: uuid.New()},
	}}
	svc := newTestServer(store, now)
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/internal/v1/sandbox-events?from=2026-08-17T10:00:00Z&until=2026-08-17T12:00:00Z&limit=2", nil)
	req.Header.Set("Authorization", "Bearer "+svc.currentToken)
	res := httptest.NewRecorder()
	svc.handler().ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
	}
	var page pageResponse
	if err := json.NewDecoder(res.Body).Decode(&page); err != nil {
		t.Fatalf("decode page: %v", err)
	}
	if len(page.Events) != 2 || page.NextCursor == nil {
		t.Fatalf("unexpected page: %#v", page)
	}
	if page.NextCursor.ID != ids[1].String() || page.NextCursor.Timestamp != timestamp.Format(time.RFC3339Nano) {
		t.Fatalf("unexpected cursor: %#v", page.NextCursor)
	}
	if store.lastQuery.limit != 2 {
		t.Fatalf("query limit = %d", store.lastQuery.limit)
	}
}

func TestLoadConfigRejectsShortPreviousToken(t *testing.T) {
	t.Setenv("CLICKHOUSE_CONNECTION_STRING", "clickhouse://reader:secret@clickhouse.invalid/default")
	t.Setenv("BILLING_GATEWAY_TOKEN", "01234567890123456789012345678901")
	t.Setenv("BILLING_GATEWAY_PREVIOUS_TOKEN", "short")
	if _, err := loadConfig(); err == nil || !contains(err.Error(), "PREVIOUS_TOKEN") {
		t.Fatalf("expected previous-token validation error, got %v", err)
	}
}

func TestTerminalQueriesDoNotReturnWholeEventData(t *testing.T) {
	t.Parallel()

	for _, query := range []string{terminalQueryWithoutCursor, terminalQueryWithCursor} {
		if contains(query, "sandbox_team_id, event_data") {
			t.Fatal("terminal query returns the complete event_data payload")
		}
		if !contains(query, "JSONExtractRaw(event_data, 'execution')") {
			t.Fatal("terminal query does not project execution")
		}
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

func TestParsePageQueryHonoursConfiguredMaxRange(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	// 30 days, wider than the 7-day fallback but inside a 60-day retention.
	target := "/internal/v1/sandbox-events?from=2026-07-18T12:00:00Z&until=2026-08-17T12:00:00Z"

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, target, nil)
	if _, err := parsePageQuery(req, now, defaultMaxRange); err == nil {
		t.Fatal("expected a 30-day window to be rejected under the 7-day fallback")
	}

	req = httptest.NewRequestWithContext(t.Context(), http.MethodGet, target, nil)
	if _, err := parsePageQuery(req, now, 60*24*time.Hour); err != nil {
		t.Fatalf("expected a 30-day window to be accepted under a 60-day range: %v", err)
	}
}

func TestMissingTerminalLoggerEmitsAggregateOnly(t *testing.T) {
	t.Parallel()

	oldest := time.Now().UTC().Add(-25 * time.Hour)
	store := &fakeStore{missingCount: 2, missingOldest: &oldest}
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	ctx, cancel := context.WithCancel(t.Context())
	cancel()

	runMissingTerminalLogger(ctx, store, time.Second, defaultMaxRange, logger)

	log := output.String()
	if !contains(log, `"msg":"sandbox_billing_terminal_missing"`) || !contains(log, `"missing_count":2`) {
		t.Fatalf("unexpected log: %s", log)
	}
}
