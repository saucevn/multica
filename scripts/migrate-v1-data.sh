#!/usr/bin/env bash
#
# migrate-v1-data.sh — copy Hira v1 (saucevn/app-hira) production data into a FRESH
# database for this newer Multica fork, preserving users/workspaces/issues/etc.
#
# Why this exists: v1 and this fork share the same Multica lineage (singular table
# names, UUID primary keys via gen_random_uuid(), no sequences), but their migration
# HISTORIES are incompatible — you cannot point this fork's backend at v1's DB and
# run migrations (number collisions at 050+). So: stand up a fresh DB, let this fork's
# migrations run clean, then copy the DATA across with this tool.
#
# It copies, per table, only the columns present in BOTH databases:
#   - columns v1 has but this fork dropped  → silently excluded
#   - columns this fork added (e.g. user.language) → get their DEFAULT
# FK triggers are disabled during load, so load order doesn't matter.
#
# NOT migrated (dropped on purpose / ephemeral / fork-managed):
#   knowledge_* (knowledge-graph, removed), admin_audit_log (admin panel, removed),
#   verification_code (ephemeral OTPs), schema_migrations (keep THIS fork's).
#
# Requirements: psql reachable to both DBs. The new DB must already be migrated & empty.
# All PKs are UUID, so there are NO sequences to reset.
#
# Usage:
#   OLD_URL='postgres://multica:***@127.0.0.1:5432/multica' \
#   NEW_URL='postgres://multica:***@127.0.0.1:5433/multica' \
#   ./scripts/migrate-v1-data.sh check     # dry-run: per-table column diff + FLAG breakers
#   ... run                                # do the copy (one transaction, FK-safe)
#   ... verify                             # compare row counts old vs new
#
set -euo pipefail

OLD_URL="${OLD_URL:?set OLD_URL=postgres://USER:PASS@OLDHOST:PORT/DB (Hira v1 DB)}"
NEW_URL="${NEW_URL:?set NEW_URL=postgres://USER:PASS@NEWHOST:PORT/DB (fresh new-fork DB)}"
WORKDIR="${WORKDIR:-/tmp/hira-mig}"

# Dropped / ephemeral / fork-managed — never copied.
EXCLUDE="knowledge_doc knowledge_chunk knowledge_chunk_mention knowledge_citation knowledge_entity knowledge_relation admin_audit_log schema_migrations verification_code"

oq(){ psql "$OLD_URL" -At -c "$1"; }   # query OLD, tuples-only
nq(){ psql "$NEW_URL" -At -c "$1"; }   # query NEW, tuples-only

list_tables(){ psql "$1" -At -c \
  "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1"; }
list_cols(){ psql "$1" -At -c \
  "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$2' ORDER BY 1"; }

# tables in BOTH dbs, minus the exclude list
shared_tables(){
  comm -12 <(list_tables "$OLD_URL") <(list_tables "$NEW_URL") \
    | grep -vxF -f <(printf '%s\n' $EXCLUDE)
}
# columns of $1 in BOTH dbs, quoted + comma-joined (for SELECT / COPY column lists)
shared_cols(){
  comm -12 <(list_cols "$OLD_URL" "$1") <(list_cols "$NEW_URL" "$1") \
    | sed 's/.*/"&"/' | paste -sd, -
}

warn_old_only_tables(){
  comm -23 <(list_tables "$OLD_URL" | grep -vxF -f <(printf '%s\n' $EXCLUDE)) \
           <(list_tables "$NEW_URL") | while read -r t; do
    [ -n "$t" ] && echo "  ! OLD-only table not in new fork (skipped): $t"
  done
}

case "${1:-check}" in
check)
  echo "== Pre-flight diff (OLD → NEW), excludes: $EXCLUDE =="
  warn_old_only_tables
  printf '%-30s %s\n' "TABLE" "DROPPED v1 cols | ⚠ NEW NOT-NULL no-default (BREAKERS)"
  brk_total=0
  for t in $(shared_tables); do
    dropped=$(comm -23 <(list_cols "$OLD_URL" "$t") <(list_cols "$NEW_URL" "$t") | paste -sd' ' -)
    # NEW columns that are NOT NULL + have no default + don't exist in OLD → break the insert
    new_req=$(nq "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$t' AND is_nullable='NO' AND column_default IS NULL ORDER BY 1")
    breakers=$(comm -23 <(printf '%s\n' "$new_req") <(list_cols "$OLD_URL" "$t") | paste -sd' ' -)
    [ -n "$breakers" ] && brk_total=$((brk_total+1))
    printf '%-30s %s | %s\n' "$t" "${dropped:-—}" "${breakers:-—}"
  done
  echo
  if [ "$brk_total" -gt 0 ]; then
    echo "⚠ $brk_total table(s) have NEW NOT-NULL-no-default columns v1 can't supply."
    echo "  Backfill those columns after 'run' (or add a default) — ask before running."
  else
    echo "✓ No breakers. Safe to: $0 run"
  fi
  ;;
run)
  mkdir -p "$WORKDIR"
  LOAD="$WORKDIR/_load.sql"; : > "$LOAD"
  echo "SET session_replication_role = replica;" >> "$LOAD"   # FK triggers off during load
  for t in $(shared_tables); do
    cols=$(shared_cols "$t")
    if [ -z "$cols" ]; then echo ">> skip $t (no shared columns)"; continue; fi
    echo ">> dump $t ($cols)"
    psql "$OLD_URL" -v ON_ERROR_STOP=1 -c "\copy (SELECT $cols FROM \"$t\") TO '$WORKDIR/$t.csv' (FORMAT csv)"
    echo "\copy \"$t\" ($cols) FROM '$WORKDIR/$t.csv' (FORMAT csv)" >> "$LOAD"
  done
  echo "RESET session_replication_role;" >> "$LOAD"
  echo ">> load into NEW (single transaction, FK-safe)"
  psql "$NEW_URL" -1 -v ON_ERROR_STOP=1 -f "$LOAD"
  psql "$NEW_URL" -c "ANALYZE;" >/dev/null
  echo "✓ load complete. Run '$0 verify' to compare row counts."
  ;;
verify)
  printf '%-30s %10s %10s %6s\n' "TABLE" "OLD" "NEW" "OK?"
  for t in $(shared_tables); do
    o=$(oq "SELECT count(*) FROM \"$t\""); n=$(nq "SELECT count(*) FROM \"$t\"")
    [ "$o" = "$n" ] && ok="✓" || ok="✗"
    printf '%-30s %10s %10s %6s\n' "$t" "$o" "$n" "$ok"
  done
  ;;
*) echo "usage: $0 {check|run|verify}  (set OLD_URL and NEW_URL)"; exit 2 ;;
esac
