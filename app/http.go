package main

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
)

type server struct {
	cfg  config
	db   *sql.DB
	rdb  *redis.Client
	host string

	warm     atomic.Bool // in-memory cache loaded; false until warm-up finishes
	draining atomic.Bool // SIGTERM received; readiness must fail from now on
	items    atomic.Int64
}

func newDB(cfg config) (*sql.DB, error) {
	db, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	// Total connections = replicas x DBMaxOpen, and a rollout briefly doubles
	// the replica count. Keep that product under Postgres max_connections.
	db.SetMaxOpenConns(cfg.DBMaxOpen)
	db.SetMaxIdleConns(cfg.DBMaxOpen)
	db.SetConnMaxLifetime(30 * time.Minute)
	return db, nil
}

func newRedis(cfg config) *redis.Client {
	return redis.NewClient(&redis.Options{Addr: cfg.RedisAddr})
}

func runHTTP(ctx context.Context, cfg config) error {
	db, err := newDB(cfg)
	if err != nil {
		return err
	}
	defer db.Close()
	rdb := newRedis(cfg)
	defer rdb.Close()

	host, _ := os.Hostname()
	s := &server{cfg: cfg, db: db, rdb: rdb, host: host}

	// The listener opens immediately so /health answers, but /ready stays 503
	// until warm-up is done. The proxy sends no traffic before that.
	go s.warmup(ctx)

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		// Must be LONGER than the proxy's idle timeout towards backends
		// (Traefik: 90s). Otherwise the app closes an idle keep-alive
		// connection at the moment the proxy reuses it, which gives a 502.
		IdleTimeout: 120 * time.Second,
	}

	if cfg.TestHooks {
		// Lets a test simulate a real crash: no drain, no goodbye.
		crash := make(chan os.Signal, 1)
		signal.Notify(crash, syscall.SIGUSR1)
		go func() {
			<-crash
			slog.Error("SIGUSR1: simulating a crash")
			os.Exit(2)
		}()
	}

	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	slog.Info("listening", "addr", srv.Addr)

	select {
	case err := <-errCh:
		return err // failed to bind, or crashed
	case <-ctx.Done():
	}

	// Graceful shutdown, in three steps:
	//
	// 1. Fail readiness, but KEEP SERVING. The proxy needs a moment to see the
	//    failed check and stop routing here. Closing the listener right away
	//    would turn requests already on their way into 502s.
	slog.Info("shutdown: failing readiness, still serving", "delay", cfg.ShutdownDelay.String())
	s.draining.Store(true)
	time.Sleep(cfg.ShutdownDelay)

	// 2. Stop accepting new connections and let in-flight requests finish.
	slog.Info("shutdown: draining in-flight requests", "timeout", cfg.ShutdownTimeout.String())
	drainCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(drainCtx); err != nil {
		// 3. Only if draining takes too long: cut the rest off.
		_ = srv.Close()
		return errors.Join(errors.New("drain timed out, connections were cut"), err)
	}
	slog.Info("shutdown: complete, no request was cut off")
	return nil
}

// warmup stands in for anything an app must load before it can answer
// correctly: an in-memory catalog, compiled templates, a primed cache. Until
// it finishes, the instance must not receive traffic.
func (s *server) warmup(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-time.After(s.cfg.WarmupDelay):
	}
	for {
		qctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		var n int64
		err := s.db.QueryRowContext(qctx, "SELECT count(*) FROM items").Scan(&n)
		cancel()
		if err == nil {
			s.items.Store(n)
			s.warm.Store(true)
			slog.Info("warm-up complete", "items", n)
			return
		}
		slog.Warn("warm-up failed, retrying", "err", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}
