package main

import (
	"context"
	"embed"
	"fmt"
	"log/slog"
	"time"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

// Arbitrary constant: every migrator takes the same Postgres advisory lock,
// so two of them can never apply the same file at once.
const migrationLockID = 727274

// runMigrate applies pending migrations and exits. It runs as its own step
// BEFORE a rollout, never at app start: with several replicas starting at
// once, migrate-on-boot is a race.
//
// Because the old version keeps serving while (and after) this runs, every
// migration must be backward compatible. Use expand/contract:
//
//	release N    add the new column or table (old code ignores it)
//	release N+1  start using it
//	release N+2  drop what is no longer used
func runMigrate(ctx context.Context, cfg config) error {
	db, err := newDB(cfg)
	if err != nil {
		return err
	}
	defer db.Close()

	deadline := time.Now().Add(60 * time.Second)
	for {
		if err = db.PingContext(ctx); err == nil {
			break
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return fmt.Errorf("database not reachable: %w", err)
		}
		time.Sleep(time.Second)
	}

	// One dedicated connection: an advisory lock belongs to its session.
	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, fmt.Sprintf("SELECT pg_advisory_lock(%d)", migrationLockID)); err != nil {
		return err
	}
	defer conn.ExecContext(context.Background(), fmt.Sprintf("SELECT pg_advisory_unlock(%d)", migrationLockID))

	if _, err := conn.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		name       text PRIMARY KEY,
		applied_at timestamptz NOT NULL DEFAULT now()
	)`); err != nil {
		return err
	}

	entries, err := migrationFiles.ReadDir("migrations") // sorted by filename
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		var applied bool
		if err := conn.QueryRowContext(ctx,
			"SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE name = $1)", name).Scan(&applied); err != nil {
			return err
		}
		if applied {
			continue
		}
		body, err := migrationFiles.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		tx, err := conn.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, string(body)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("%s: %w", name, err)
		}
		if _, err := tx.ExecContext(ctx, "INSERT INTO schema_migrations (name) VALUES ($1)", name); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("%s: %w", name, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		slog.Info("migration applied", "name", name)
	}
	slog.Info("schema up to date")
	return nil
}
