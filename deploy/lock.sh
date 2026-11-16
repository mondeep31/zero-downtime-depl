#!/usr/bin/env bash
# One lock for everything that changes the replica count (rollout.sh and
# autoscale.sh), so they never act at the same time. Source it from deploy/.
#
# A directory is the lock: mkdir is atomic, and unlike flock it exists on
# macOS too. The holder's PID is stored inside so a lock left behind by a
# killed process is detected and taken over.
LOCK_DIR="${LOCK_DIR:-$PWD/.scale.lock}"

lock_owner() { cat "$LOCK_DIR/pid" 2>/dev/null || true; }

# True while another live process holds the lock.
lock_busy() {
  local pid
  pid="$(lock_owner)"
  [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null
}

# Take the lock without waiting. Returns 1 if someone else holds it.
lock_try() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$LOCK_DIR/pid"
    return 0
  fi
  local pid
  pid="$(lock_owner)"
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR" # the holder is gone: stale lock
    lock_try
    return
  fi
  return 1
}

# lock_wait SECONDS: keep trying until the lock is free or time runs out.
lock_wait() {
  local deadline=$((SECONDS + $1))
  until lock_try; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 1
  done
}

# Release the lock, but only if this process holds it.
lock_release() {
  if [ "$(lock_owner)" = "$$" ]; then rm -rf "$LOCK_DIR"; fi
}
