CREATE TABLE users (
    username        text PRIMARY KEY,
    password_sha256 text NOT NULL
);

CREATE TABLE items (
    id   serial PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE job_runs (
    id      bigserial PRIMARY KEY,
    host    text        NOT NULL,
    version text        NOT NULL,
    ran_at  timestamptz NOT NULL DEFAULT now()
);

-- Demo login: demo / demo
INSERT INTO users (username, password_sha256)
VALUES ('demo', encode(sha256('demo'::bytea), 'hex'));

INSERT INTO items (name)
SELECT 'item-' || n FROM generate_series(1, 50) AS n;
