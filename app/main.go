// Demo service used to prove zero-downtime deploys.
//
// One binary, three modes:
//
//	app http      API server (run as several replicas behind the proxy)
//	app worker    background job, guarded by a Redis lock (run as ONE replica)
//	app migrate   one-shot schema migration (run before each rollout)
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	mode := "http"
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}

	cfg := loadConfig()
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("version", cfg.Version, "mode", mode))

	// SIGTERM is what `docker stop` / `docker compose` sends first. Handling it
	// is the foundation of graceful shutdown.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var err error
	switch mode {
	case "http":
		err = runHTTP(ctx, cfg)
	case "worker":
		err = runWorker(ctx, cfg)
	case "migrate":
		err = runMigrate(ctx, cfg)
	default:
		err = fmt.Errorf("unknown mode %q (want http|worker|migrate)", mode)
	}
	if err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}
