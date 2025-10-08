# DBLens MVP Starter (Docker + Postgres + URL Loader)

**What you get**
- Dockerized Postgres with two roles: `loader_rw` (ingestion only) and `app_ro` (read-only by default).
- A Python CLI to ingest CSV/Parquet/JSONL from a URL into a new table with inferred schema + optional indexes.
- A small `dbtools.py` utility to dump Schema Cards, run EXPLAIN validation, and preview query rows.
- Makefile and scripts to speed up common tasks.

## Quick Start

```bash
# 1) cd into the repo and bootstrap
bash scripts/bootstrap.sh

# 2) Ingest a dataset (example)
make ingest URL="https://people.sc.fsu.edu/~jburkardt/data/csv/airtravel.csv" TABLE=airtravel FORMAT=csv

# 3) See the Schema Card (first 200 lines for brevity)
make schema

# 4) Preview a query
make preview SQL="select * from airtravel limit 5"

# 5) Validate a query (EXPLAIN)
make validate SQL="select * from airtravel limit 10"
```

> Connection strings live in `.env`. You can copy `.env.example` to `.env` and edit as needed.

## Roles & Safety

- `app_ro`: `default_transaction_read_only=on`, `statement_timeout=5s` so previews/validation are fast and safe.
- `loader_rw`: has `CREATE` on `public` for ingestion only. The app should **always** use `app_ro`.

All ingestions are logged to `public.ingestion_log` with URL, bytes, row_count, sha256, and columns JSON.

## Useful Make targets

- `make up` / `make down` — start/stop the stack
- `make ingest URL=... TABLE=... [FORMAT=auto]`
- `make schema` — writes `/tmp/schema_cards.json` and prints a snippet
- `make preview SQL="..."
- `make validate SQL="..."`

## Notes

- JSON support expects **line-delimited** JSON (one object per line) for MVP.
- Gz/zip are auto-handled. Size is capped to 250MB by default.
- The loader uses `COPY` under the hood for speed.
- Simple helpful indexes are added if a column looks like an id or date/timestamp.