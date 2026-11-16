package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /ready", s.handleReady)
	mux.HandleFunc("GET /api/version", s.handleVersion)
	mux.HandleFunc("POST /login", s.handleLogin)
	mux.Handle("GET /api/items", s.requireSession(http.HandlerFunc(s.handleItems)))
	mux.HandleFunc("GET /api/limited", s.handleLimited)
	if s.cfg.TestHooks {
		mux.HandleFunc("GET /slow", s.handleSlow)
	}
	return s.instrument(mux)
}

// instrument stamps every response with the version and replica that served
// it, so a load test can see the traffic move from old to new.
func (s *server) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-App-Version", s.cfg.Version)
		w.Header().Set("X-Served-By", s.host)
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if rec.status >= 500 && r.URL.Path != "/ready" {
			slog.Error("5xx response", "path", r.URL.Path, "status", rec.status)
		}
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// handleHealth is LIVENESS: "the process is up". It never checks
// dependencies, so a database blip does not get the container restarted.
func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReady is READINESS: "send me traffic". The proxy and the rollout
// script both gate on it.
func (s *server) handleReady(w http.ResponseWriter, r *http.Request) {
	if reason := s.notReadyReason(r.Context()); reason != "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable", "reason": reason})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *server) notReadyReason(ctx context.Context) string {
	switch {
	case s.draining.Load():
		return "draining"
	case s.cfg.FailReady:
		return "forced failure (FAIL_READY)"
	case !s.warm.Load():
		return "warming up"
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	if err := s.db.PingContext(ctx); err != nil {
		return "postgres: " + err.Error()
	}
	if err := s.rdb.Ping(ctx).Err(); err != nil {
		return "redis: " + err.Error()
	}
	return ""
}

func (s *server) handleVersion(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"version": s.cfg.Version, "served_by": s.host})
}

// handleLogin stores the session in Redis, never in process memory, so any
// replica can serve the next request and a deploy logs nobody out.
func (s *server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}

	var want string
	err := s.db.QueryRowContext(r.Context(),
		"SELECT password_sha256 FROM users WHERE username = $1", req.Username).Scan(&want)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	case err != nil:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database error"})
		return
	}
	// Demo only: a real service must use a slow password hash (argon2, bcrypt).
	sum := sha256.Sum256([]byte(req.Password))
	if subtle.ConstantTimeCompare([]byte(hex.EncodeToString(sum[:])), []byte(want)) != 1 {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}

	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "token error"})
		return
	}
	token := hex.EncodeToString(raw)
	if err := s.rdb.Set(r.Context(), "session:"+token, req.Username, time.Hour).Err(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "session store error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": token})
}

func (s *server) requireSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing bearer token"})
			return
		}
		err := s.rdb.Get(r.Context(), "session:"+token).Err()
		switch {
		case errors.Is(err, redis.Nil):
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "session expired"})
			return
		case err != nil:
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "session store error"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) handleItems(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), "SELECT id, name FROM items ORDER BY id LIMIT 50")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database error"})
		return
	}
	defer rows.Close()

	type item struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	}
	items := make([]item, 0, 50)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Name); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database error"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "served_by": s.host})
}

// handleLimited is rate limited with a counter in Redis. Because the counter
// is shared, the limit holds across replicas: N replicas do not mean N times
// the limit.
func (s *server) handleLimited(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	key := "ratelimit:" + clientIP(r)
	// SET NX with a TTL first, so the key can never exist without an expiry.
	if err := s.rdb.SetNX(ctx, key, 0, s.cfg.RateWindow).Err(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "rate limit store error"})
		return
	}
	n, err := s.rdb.Incr(ctx, key).Result()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "rate limit store error"})
		return
	}
	if n > int64(s.cfg.RateLimit) {
		w.Header().Set("Retry-After", strconv.Itoa(int(s.cfg.RateWindow.Seconds())))
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "rate limit exceeded"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"count": n, "limit": s.cfg.RateLimit, "served_by": s.host})
}

// clientIP trusts X-Forwarded-For because the only way in is through the
// proxy. A service reachable directly must not trust this header.
func clientIP(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		first, _, _ := strings.Cut(fwd, ",")
		return strings.TrimSpace(first)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// handleSlow holds a request open for ?ms= milliseconds. Load tests use it to
// prove that requests in flight during a shutdown still complete.
func (s *server) handleSlow(w http.ResponseWriter, r *http.Request) {
	ms, err := strconv.Atoi(r.URL.Query().Get("ms"))
	if err != nil || ms < 0 {
		ms = 1000
	}
	ms = min(ms, 30000)
	select {
	case <-time.After(time.Duration(ms) * time.Millisecond):
		writeJSON(w, http.StatusOK, map[string]any{"slept_ms": ms, "served_by": s.host})
	case <-r.Context().Done(): // client went away
	}
}
