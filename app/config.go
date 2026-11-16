package main

import (
	"os"
	"strconv"
	"time"
)

// buildVersion is set at build time with -ldflags "-X main.buildVersion=...".
var buildVersion = "dev"

type config struct {
	Port        string
	DatabaseURL string
	RedisAddr   string
	Version     string

	// Deploy-safety knobs. See README "The timings that matter".
	WarmupDelay     time.Duration // simulated slow start before the app is ready
	ShutdownDelay   time.Duration // keep serving after SIGTERM while the proxy notices
	ShutdownTimeout time.Duration // max time to finish in-flight requests

	// Test hooks. Leave off in production.
	TestHooks bool // exposes GET /slow?ms= and makes SIGUSR1 crash the process
	FailReady bool // /ready always fails: simulates a broken release

	RateLimit      int
	RateWindow     time.Duration
	WorkerInterval time.Duration
	DBMaxOpen      int
}

func loadConfig() config {
	return config{
		Port:            env("PORT", "8080"),
		DatabaseURL:     env("DATABASE_URL", "postgres://demo:demo@localhost:5432/demo?sslmode=disable"),
		RedisAddr:       env("REDIS_ADDR", "localhost:6379"),
		Version:         env("VERSION", buildVersion),
		WarmupDelay:     envDuration("WARMUP_DELAY", 2*time.Second),
		ShutdownDelay:   envDuration("SHUTDOWN_DELAY", 4*time.Second),
		ShutdownTimeout: envDuration("SHUTDOWN_TIMEOUT", 25*time.Second),
		TestHooks:       envBool("TEST_HOOKS", false),
		FailReady:       envBool("FAIL_READY", false),
		RateLimit:       envInt("RATE_LIMIT", 20),
		RateWindow:      envDuration("RATE_WINDOW", 60*time.Second),
		WorkerInterval:  envDuration("WORKER_INTERVAL", 5*time.Second),
		DBMaxOpen:       envInt("DB_MAX_OPEN", 10),
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	if v, err := strconv.ParseBool(os.Getenv(key)); err == nil {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(key)); err == nil {
		return v
	}
	return fallback
}
