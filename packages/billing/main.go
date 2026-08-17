package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/ClickHouse/clickhouse-go/v2"
	"github.com/ClickHouse/clickhouse-go/v2/lib/driver"
	"github.com/google/uuid"
)

const (
	terminalQueryWithoutCursor = `SELECT id, version, type, timestamp, sandbox_id, sandbox_execution_id,
  sandbox_template_id, sandbox_build_id, sandbox_team_id,
  nullIf(JSONExtractRaw(event_data, 'execution'), ''),
  nullIf(JSONExtractString(event_data, 'kill_reason'), '')
FROM sandbox_events
WHERE type IN ('sandbox.lifecycle.paused', 'sandbox.lifecycle.killed')
  AND timestamp >= ? AND timestamp < ?
ORDER BY timestamp ASC, id ASC
LIMIT ?`

	terminalQueryWithCursor = `SELECT id, version, type, timestamp, sandbox_id, sandbox_execution_id,
  sandbox_template_id, sandbox_build_id, sandbox_team_id,
  nullIf(JSONExtractRaw(event_data, 'execution'), ''),
  nullIf(JSONExtractString(event_data, 'kill_reason'), '')
FROM sandbox_events
WHERE type IN ('sandbox.lifecycle.paused', 'sandbox.lifecycle.killed')
  AND timestamp >= ? AND timestamp < ?
  AND (timestamp, id) > (?, ?)
ORDER BY timestamp ASC, id ASC
LIMIT ?`

	// The lookback is the retention window, not a fixed 7 days: with a longer
	// retention an execution that started 10 days ago and never terminated
	// would otherwise never be reported.
	missingTerminalQuery = `SELECT count(), min(started_at)
FROM (
  SELECT sandbox_execution_id, min(timestamp) AS started_at
  FROM sandbox_events
  WHERE type IN ('sandbox.lifecycle.created', 'sandbox.lifecycle.resumed')
    AND timestamp >= now() - INTERVAL ? SECOND
    AND timestamp < now() - INTERVAL 24 HOUR
    AND sandbox_execution_id != ''
  GROUP BY sandbox_execution_id
) AS starts
LEFT ANTI JOIN (
  SELECT DISTINCT sandbox_execution_id
  FROM sandbox_events
  WHERE type IN ('sandbox.lifecycle.paused', 'sandbox.lifecycle.killed')
    AND timestamp >= now() - INTERVAL ? SECOND
    AND sandbox_execution_id != ''
) AS terminals USING sandbox_execution_id`

	defaultLimit = 500
	maxLimit     = 1000

	// Fallback only. The real bound is how long sandbox_events actually keeps
	// rows, which is per-team (tiers.events_ttl_days -> the events_ttl_days
	// column, enforced as a per-row TTL). Accepting a window wider than the
	// retention returns a silently short answer, so MAX_QUERY_RANGE must be
	// kept in step with the longest retention any team is on.
	defaultMaxRange = 7 * 24 * time.Hour
)

type config struct {
	address         string
	clickhouseDSN   string
	currentToken    string
	previousToken   string
	queryTimeout    time.Duration
	shutdownTimeout time.Duration
	maxRange        time.Duration
}

func loadConfig() (config, error) {
	queryTimeout, err := envDuration("QUERY_TIMEOUT", 5*time.Second)
	if err != nil {
		return config{}, err
	}
	shutdownTimeout, err := envDuration("SHUTDOWN_TIMEOUT", 15*time.Second)
	if err != nil {
		return config{}, err
	}
	maxRange, err := envDuration("MAX_QUERY_RANGE", defaultMaxRange)
	if err != nil {
		return config{}, err
	}
	if maxRange <= 0 {
		return config{}, errors.New("MAX_QUERY_RANGE must be positive")
	}
	port := strings.TrimSpace(os.Getenv("PORT"))
	if port == "" {
		port = "8080"
	}
	cfg := config{
		address:         ":" + port,
		clickhouseDSN:   strings.TrimSpace(os.Getenv("CLICKHOUSE_CONNECTION_STRING")),
		currentToken:    strings.TrimSpace(os.Getenv("BILLING_GATEWAY_TOKEN")),
		previousToken:   strings.TrimSpace(os.Getenv("BILLING_GATEWAY_PREVIOUS_TOKEN")),
		queryTimeout:    queryTimeout,
		maxRange:        maxRange,
		shutdownTimeout: shutdownTimeout,
	}
	if cfg.clickhouseDSN == "" {
		return config{}, errors.New("CLICKHOUSE_CONNECTION_STRING is required")
	}
	if len(cfg.currentToken) < 32 {
		return config{}, errors.New("BILLING_GATEWAY_TOKEN must be at least 32 characters")
	}
	if cfg.previousToken != "" && len(cfg.previousToken) < 32 {
		return config{}, errors.New("BILLING_GATEWAY_PREVIOUS_TOKEN must be at least 32 characters when set")
	}

	return cfg, nil
}

func envDuration(name string, fallback time.Duration) (time.Duration, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback, nil
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", name)
	}

	return value, nil
}

type rawEvent struct {
	ID                 uuid.UUID
	Version            string
	Type               string
	Timestamp          time.Time
	SandboxID          string
	SandboxExecutionID string
	SandboxTemplateID  string
	SandboxBuildID     string
	SandboxTeamID      uuid.UUID
	ExecutionData      sql.NullString
	KillReason         sql.NullString
}

type eventStore interface {
	QueryTerminalEvents(ctx context.Context, query pageQuery) ([]rawEvent, error)
	Ping(ctx context.Context) error
	QueryMissingTerminal(ctx context.Context, lookback time.Duration) (uint64, *time.Time, error)
	Close() error
}

type clickhouseStore struct{ conn driver.Conn }

func newClickhouseStore(dsn string) (*clickhouseStore, error) {
	options, err := clickhouse.ParseDSN(dsn)
	if err != nil {
		return nil, errors.New("invalid ClickHouse connection string")
	}
	options.MaxOpenConns = 5
	options.MaxIdleConns = 2
	options.ConnMaxLifetime = 10 * time.Minute
	conn, err := clickhouse.Open(options)
	if err != nil {
		return nil, errors.New("open ClickHouse connection")
	}

	return &clickhouseStore{conn: conn}, nil
}

type pageQuery struct {
	from           time.Time
	until          time.Time
	afterTimestamp *time.Time
	afterID        *uuid.UUID
	limit          uint64
}

func (s *clickhouseStore) QueryTerminalEvents(ctx context.Context, q pageQuery) ([]rawEvent, error) {
	query := terminalQueryWithoutCursor
	args := []any{q.from, q.until, q.limit + 1}
	if q.afterTimestamp != nil && q.afterID != nil {
		query = terminalQueryWithCursor
		args = []any{q.from, q.until, *q.afterTimestamp, *q.afterID, q.limit + 1}
	}
	rows, err := s.conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query terminal events: %w", err)
	}
	defer rows.Close()

	result := make([]rawEvent, 0, q.limit+1)
	for rows.Next() {
		var event rawEvent
		if err := rows.Scan(&event.ID, &event.Version, &event.Type, &event.Timestamp, &event.SandboxID,
			&event.SandboxExecutionID, &event.SandboxTemplateID, &event.SandboxBuildID,
			&event.SandboxTeamID, &event.ExecutionData, &event.KillReason); err != nil {
			return nil, fmt.Errorf("scan terminal event: %w", err)
		}
		result = append(result, event)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate terminal events: %w", err)
	}

	return result, nil
}

func (s *clickhouseStore) Ping(ctx context.Context) error { return s.conn.Ping(ctx) }
func (s *clickhouseStore) Close() error                   { return s.conn.Close() }

func (s *clickhouseStore) QueryMissingTerminal(ctx context.Context, lookback time.Duration) (uint64, *time.Time, error) {
	var count uint64
	var oldest sql.NullTime
	seconds := int64(lookback / time.Second)
	if err := s.conn.QueryRow(ctx, missingTerminalQuery, seconds, seconds).Scan(&count, &oldest); err != nil {
		return 0, nil, fmt.Errorf("query missing terminal aggregate: %w", err)
	}
	if !oldest.Valid {
		return count, nil, nil
	}
	value := oldest.Time.UTC()

	return count, &value, nil
}

type executionPayload struct {
	StartedAt       string      `json:"started_at"`
	ExecutionTimeMS json.Number `json:"execution_time"`
	VCPUCount       json.Number `json:"vcpu_count"`
	MemoryMB        json.Number `json:"memory_mb"`
}

type apiExecution struct {
	StartedAt       string `json:"started_at"`
	ExecutionTimeMS int64  `json:"execution_time_ms"`
	VCPUCount       int64  `json:"vcpu_count"`
	MemoryMB        int64  `json:"memory_mb"`
}

type apiEvent struct {
	EventID            string        `json:"event_id"`
	EventVersion       string        `json:"event_version"`
	EventType          string        `json:"event_type"`
	OccurredAt         string        `json:"occurred_at"`
	SandboxID          string        `json:"sandbox_id"`
	SandboxExecutionID string        `json:"sandbox_execution_id"`
	SandboxTemplateID  string        `json:"sandbox_template_id"`
	SandboxBuildID     string        `json:"sandbox_build_id"`
	SandboxTeamID      string        `json:"sandbox_team_id"`
	Execution          *apiExecution `json:"execution"`
	CloseReason        *string       `json:"close_reason"`
}

type cursor struct {
	Timestamp string `json:"timestamp"`
	ID        string `json:"id"`
}

type pageResponse struct {
	SchemaVersion int        `json:"schema_version"`
	GeneratedAt   string     `json:"generated_at"`
	Events        []apiEvent `json:"events"`
	NextCursor    *cursor    `json:"next_cursor"`
}

type server struct {
	store         eventStore
	currentToken  string
	previousToken string
	queryTimeout  time.Duration
	maxRange      time.Duration
	now           func() time.Time
	logger        *slog.Logger
	limiter       *requestLimiter
}

type requestLimiter struct {
	mu        sync.Mutex
	rate      float64
	burst     float64
	tokens    float64
	updatedAt time.Time
}

func newRequestLimiter(rate float64, burst int, now time.Time) *requestLimiter {
	return &requestLimiter{rate: rate, burst: float64(burst), tokens: float64(burst), updatedAt: now}
}

func (l *requestLimiter) allow(now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	elapsed := now.Sub(l.updatedAt).Seconds()
	if elapsed > 0 {
		l.tokens = min(l.burst, l.tokens+elapsed*l.rate)
		l.updatedAt = now
	}
	if l.tokens < 1 {
		return false
	}
	l.tokens--

	return true
}

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /live", s.live)
	mux.HandleFunc("GET /ready", s.ready)
	mux.HandleFunc("GET /internal/v1/sandbox-events", s.authorize(s.events))

	return s.requestLog(mux)
}

func (s *server) authorize(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") || !s.validToken(strings.TrimPrefix(header, "Bearer ")) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})

			return
		}
		if s.limiter != nil && !s.limiter.allow(s.now()) {
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "rate_limited"})

			return
		}
		next(w, r)
	}
}

func (s *server) validToken(token string) bool {
	for _, expected := range []string{s.currentToken, s.previousToken} {
		if expected != "" && len(token) == len(expected) && subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1 {
			return true
		}
	}

	return false
}

func (s *server) live(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), s.queryTimeout)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})

		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) events(w http.ResponseWriter, r *http.Request) {
	q, err := parsePageQuery(r, s.now().UTC(), s.maxRange)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_request", "detail": err.Error()})

		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.queryTimeout)
	defer cancel()
	raw, err := s.store.QueryTerminalEvents(ctx, q)
	if err != nil {
		s.logger.Error("billing_gateway_query_failed", "error", err.Error())
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "source_unavailable"})

		return
	}

	hasMore := len(raw) > int(q.limit)
	if hasMore {
		raw = raw[:q.limit]
	}
	events := make([]apiEvent, 0, len(raw))
	for _, item := range raw {
		normalized := normalizeEvent(item)
		if normalized.Execution == nil {
			s.logger.Error("billing_terminal_malformed", "event_id", item.ID.String(), "sandbox_id", item.SandboxID)
		}
		events = append(events, normalized)
	}
	response := pageResponse{SchemaVersion: 1, GeneratedAt: s.now().UTC().Format(time.RFC3339Nano), Events: events}
	if hasMore && len(raw) > 0 {
		last := raw[len(raw)-1]
		response.NextCursor = &cursor{Timestamp: last.Timestamp.UTC().Format(time.RFC3339Nano), ID: last.ID.String()}
	}
	writeJSON(w, http.StatusOK, response)
}

func parsePageQuery(r *http.Request, now time.Time, maxRange time.Duration) (pageQuery, error) {
	values := r.URL.Query()
	from, err := time.Parse(time.RFC3339Nano, values.Get("from"))
	if err != nil {
		return pageQuery{}, errors.New("from must be RFC3339")
	}
	until, err := time.Parse(time.RFC3339Nano, values.Get("until"))
	if err != nil {
		return pageQuery{}, errors.New("until must be RFC3339")
	}
	from, until = from.UTC(), until.UTC()
	if !until.After(from) || until.Sub(from) > maxRange {
		return pageQuery{}, errors.New("time range must be positive and at most 7 days")
	}
	if until.After(now) {
		return pageQuery{}, errors.New("until cannot be in the future")
	}

	q := pageQuery{from: from, until: until, limit: defaultLimit}
	if raw := values.Get("limit"); raw != "" {
		parsed, err := strconv.ParseUint(raw, 10, 32)
		if err != nil || parsed < 1 || parsed > maxLimit {
			return pageQuery{}, errors.New("limit must be between 1 and 1000")
		}
		q.limit = parsed
	}
	afterTimestamp, afterID := values.Get("after_timestamp"), values.Get("after_id")
	if (afterTimestamp == "") != (afterID == "") {
		return pageQuery{}, errors.New("after_timestamp and after_id must be provided together")
	}
	if afterTimestamp != "" {
		parsedTimestamp, err := time.Parse(time.RFC3339Nano, afterTimestamp)
		if err != nil {
			return pageQuery{}, errors.New("after_timestamp must be RFC3339")
		}
		parsedID, err := uuid.Parse(afterID)
		if err != nil {
			return pageQuery{}, errors.New("after_id must be a UUID")
		}
		parsedTimestamp = parsedTimestamp.UTC()
		if parsedTimestamp.Before(from) || !parsedTimestamp.Before(until) {
			return pageQuery{}, errors.New("cursor must be inside the requested range")
		}
		q.afterTimestamp, q.afterID = &parsedTimestamp, &parsedID
	}

	return q, nil
}

func normalizeEvent(raw rawEvent) apiEvent {
	eventType := strings.TrimPrefix(raw.Type, "sandbox.lifecycle.")
	result := apiEvent{
		EventID: raw.ID.String(), EventVersion: raw.Version, EventType: eventType,
		OccurredAt: raw.Timestamp.UTC().Format(time.RFC3339Nano), SandboxID: raw.SandboxID,
		SandboxExecutionID: raw.SandboxExecutionID, SandboxTemplateID: raw.SandboxTemplateID,
		SandboxBuildID: raw.SandboxBuildID, SandboxTeamID: raw.SandboxTeamID.String(),
	}
	if raw.KillReason.Valid {
		result.CloseReason = &raw.KillReason.String
	}
	if !raw.ExecutionData.Valid {
		return result
	}
	decoder := json.NewDecoder(strings.NewReader(raw.ExecutionData.String))
	decoder.UseNumber()
	var execution executionPayload
	if err := decoder.Decode(&execution); err != nil {
		return result
	}
	startedAt, err := time.Parse(time.RFC3339Nano, execution.StartedAt)
	duration, durationErr := execution.ExecutionTimeMS.Int64()
	vcpu, vcpuErr := execution.VCPUCount.Int64()
	memory, memoryErr := execution.MemoryMB.Int64()
	if err != nil || durationErr != nil || vcpuErr != nil || memoryErr != nil || duration < 0 || vcpu <= 0 || memory <= 0 {
		return result
	}
	result.Execution = &apiExecution{
		StartedAt: startedAt.UTC().Format(time.RFC3339Nano), ExecutionTimeMS: duration,
		VCPUCount: vcpu, MemoryMB: memory,
	}

	return result
}

type statusRecorder struct {
	http.ResponseWriter

	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (s *server) requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(recorder, r)
		s.logger.Info("http_request", "method", r.Method, "path", r.URL.Path, "status", recorder.status, "duration_ms", time.Since(started).Milliseconds())
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Default().Error("http_response_encode_failed", "error", err.Error())
	}
}

func runMissingTerminalLogger(ctx context.Context, store eventStore, timeout, lookback time.Duration, logger *slog.Logger) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	check := func() {
		queryCtx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		count, oldest, err := store.QueryMissingTerminal(queryCtx, lookback)
		if err != nil {
			logger.Error("billing_terminal_missing_check_failed")

			return
		}
		if count == 0 {
			return
		}
		attrs := []any{"missing_count", count}
		if oldest != nil {
			attrs = append(attrs, "oldest_started_at", oldest.Format(time.RFC3339Nano), "oldest_age_seconds", int64(time.Since(*oldest).Seconds()))
		}
		logger.Warn("sandbox_billing_terminal_missing", attrs...)
	}
	check()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			check()
		}
	}
}

func run() int {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := loadConfig()
	if err != nil {
		logger.Error("configuration_error", "error", err.Error())

		return 1
	}
	store, err := newClickhouseStore(cfg.clickhouseDSN)
	if err != nil {
		logger.Error("clickhouse_initialization_failed")

		return 1
	}
	defer store.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	svc := &server{
		store: store, currentToken: cfg.currentToken, previousToken: cfg.previousToken,
		queryTimeout: cfg.queryTimeout, maxRange: cfg.maxRange, now: time.Now, logger: logger,
		limiter: newRequestLimiter(10, 20, time.Now()),
	}
	httpServer := &http.Server{
		Addr: cfg.address, Handler: svc.handler(), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second,
	}
	go runMissingTerminalLogger(ctx, store, cfg.queryTimeout, cfg.maxRange, logger)
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cfg.shutdownTimeout)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()
	logger.Info("billing_started", "address", cfg.address)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("http_server_failed", "error", err.Error())

		return 1
	}

	return 0
}

func main() {
	os.Exit(run())
}
