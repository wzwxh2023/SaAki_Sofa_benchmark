#!/usr/bin/env bash

# 快速查看 PostgreSQL 活跃会话

set -euo pipefail
IFS=$'\n\t'

: "${PGHOST:=172.19.160.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=mimiciv}"
: "${PGPASSWORD:=188211}"

export PGPASSWORD

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" <<'SQL'
\pset pager off
SELECT pid,
       usename,
       state,
       wait_event_type,
       wait_event,
       now() - query_start AS running_for,
       LEFT(query, 120) AS query_snippet
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY running_for DESC;
SQL
