package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/redis/go-redis/v9"
)

const jobLockKey = "lock:demo-job"

// Deletes the lock only if we still own it, so a slow run can never release a
// lock that has already expired and been taken by someone else.
var releaseLock = redis.NewScript(`
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
end
return 0`)

// runWorker is the background job. It is a separate service on purpose: if it
// lived inside the API process, scaling the API to N replicas would run the
// job N times. Run it as ONE replica. The Redis lock is a second line of
// defence for the moment a rollout has old and new running side by side.
func runWorker(ctx context.Context, cfg config) error {
	db, err := newDB(cfg)
	if err != nil {
		return err
	}
	defer db.Close()
	rdb := newRedis(cfg)
	defer rdb.Close()
	host, _ := os.Hostname()

	slog.Info("worker started", "interval", cfg.WorkerInterval.String())
	ticker := time.NewTicker(cfg.WorkerInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			// The current run (if any) has already returned, so nothing is
			// cut off half way.
			slog.Info("worker stopped cleanly")
			return nil
		case <-ticker.C:
		}

		got, err := rdb.SetNX(ctx, jobLockKey, host, 30*time.Second).Result()
		if err != nil {
			slog.Warn("lock error, skipping run", "err", err)
			continue
		}
		if !got {
			slog.Info("another worker holds the lock, skipping run")
			continue
		}
		if _, err := db.ExecContext(ctx,
			"INSERT INTO job_runs (host, version) VALUES ($1, $2)", host, cfg.Version); err != nil {
			slog.Warn("job failed", "err", err)
		}
		// Background context: release the lock even if we are shutting down.
		if err := releaseLock.Run(context.Background(), rdb, []string{jobLockKey}, host).Err(); err != nil {
			slog.Warn("lock release failed (it will expire on its own)", "err", err)
		}
	}
}
