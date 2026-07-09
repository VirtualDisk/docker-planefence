#!/command/with-contenv bash
#shellcheck shell=bash
#shellcheck disable=SC1091,SC2154,SC2034
# send_pa_postgres.sh
# Logs Plane-Alert detections to a Postgres database for querying/Grafana.
#
# Usage: ./send_pa_postgres.sh
#
# This script is distributed as part of the Planefence package and is dependent
# on that package for its execution.
#
# Copyright 2026 Ramon F. Kolb (kx1t), and contributors - licensed under the terms and conditions
# of GPLv3. The terms and conditions of this license are included with the Github
# distribution of this package, and are also available here:
# https://github.com/sdr-enthusiasts/docker-planefence
#

source /scripts/pf-common
source "/usr/share/planefence/plane-alert.conf"

declare -a INDEX=() STALE=() link=()

DEBUG="${DEBUG:-false}"

# -----------------------------------------------------------------------------------
#      FUNCTIONS
# -----------------------------------------------------------------------------------

generate_postgres() {
  # Insert one Plane-Alert detection record into Postgres

  local idx="$1" k
  declare -a keys=()
  for k in "${!pa_records[@]}"; do
    if [[ $k == "$idx:"* ]]; then keys+=("$k"); fi
  done

  # Build a JSON blob of every field on this record as a safety net for anything
  # not promoted to its own column (schema changes shouldn't need a script change).
  local raw_json
  raw_json="$(for i in "${keys[@]}"; do
                printf '{"%s":"%s"}\n' "${i#*:}" "$(json_encode "${pa_records[$i]}")"
              done | jq -sc add)"

  local detected_at="${pa_records["$idx":time:time_at_mindist]:-${pa_records["$idx":time:firstseen]}}"

  local sql
  sql="$(cat <<'SQL'
INSERT INTO pa_detections (
  detected_at, station, icao, tail, callsign, owner, aircraft_type, category,
  tag1, tag2, tag3, lat, lon, distance_value, distance_unit, altitude_value, altitude_unit,
  groundspeed_value, groundspeed_unit, squawk, route, raw
) VALUES (
  to_timestamp(NULLIF(:'detected_at','')::bigint),
  NULLIF(:'station',''),
  :'icao',
  NULLIF(:'tail',''),
  NULLIF(:'callsign',''),
  NULLIF(:'owner',''),
  NULLIF(:'aircraft_type',''),
  NULLIF(:'category',''),
  NULLIF(:'tag1',''),
  NULLIF(:'tag2',''),
  NULLIF(:'tag3',''),
  NULLIF(:'lat','')::double precision,
  NULLIF(:'lon','')::double precision,
  NULLIF(:'distance_value','')::double precision,
  NULLIF(:'distance_unit',''),
  NULLIF(:'altitude_value','')::double precision,
  NULLIF(:'altitude_unit',''),
  NULLIF(:'groundspeed_value','')::double precision,
  NULLIF(:'groundspeed_unit',''),
  NULLIF(:'squawk',''),
  NULLIF(:'route',''),
  NULLIF(:'raw','')::jsonb
)
ON CONFLICT (icao, detected_at) DO NOTHING;
SQL
)"

  # Every value is passed as a psql client-side variable (-v) and referenced in the
  # SQL as :'name', which psql quotes/escapes as a SQL literal - no manual string
  # interpolation into the query, so there's no SQL-injection surface here.
  local -a psql_args=()
  # If PA_POSTGRES_URL is set, pass it as the connection target; otherwise psql
  # falls back to the PG* environment variables exported below.
  [[ -n "$PA_POSTGRES_URL" ]] && psql_args+=("$PA_POSTGRES_URL")
  psql_args+=(
    -X -q -v ON_ERROR_STOP=1
    -v detected_at="$detected_at"
    -v station="$(hostname)"
    -v icao="${pa_records["$idx":icao]}"
    -v tail="${pa_records["$idx":tail]}"
    -v callsign="${pa_records["$idx":callsign]}"
    -v owner="${pa_records["$idx":owner]}"
    -v aircraft_type="${pa_records["$idx":type]}"
    -v category="${pa_records["$idx":db:category]}"
    -v tag1="${pa_records["$idx":db:tag1]}"
    -v tag2="${pa_records["$idx":db:tag2]}"
    -v tag3="${pa_records["$idx":db:tag3]}"
    -v lat="${pa_records["$idx":lat]}"
    -v lon="${pa_records["$idx":lon]}"
    -v distance_value="${pa_records["$idx":distance:value]}"
    -v distance_unit="${pa_records["$idx":distance:unit]}"
    -v altitude_value="${pa_records["$idx":altitude:value]}"
    -v altitude_unit="${pa_records["$idx":altitude:unit]}"
    -v groundspeed_value="${pa_records["$idx":groundspeed:value]}"
    -v groundspeed_unit="${pa_records["$idx":groundspeed:unit]}"
    -v squawk="${pa_records["$idx":squawk:value]}"
    -v route="${pa_records["$idx":route]}"
    -v raw="$raw_json"
  )

  log_print DEBUG "Attempting to insert Plane-Alert record index $idx into Postgres"

  # psql's -c/--command mode does not perform :'variable' interpolation - only
  # scripts read via -f or stdin do - so the SQL is piped in rather than passed
  # via -c.
  local outputmsg
  if outputmsg="$(psql "${psql_args[@]}" <<<"$sql" 2>&1)"; then
    log_print DEBUG "Postgres insert successful: ${outputmsg//$'\n'/ }"
    return 0
  else
    log_print DEBUG "Postgres insert FAILED: ${outputmsg//$'\n'/ }"
    return 1
  fi
}

if [[ -z "$PA_POSTGRES_URL" && -z "$PA_POSTGRES_HOST" ]]; then
  log_print DEBUG "Postgres logging is disabled - exiting"
  exit 0
fi

# PA_POSTGRES_URL, if set, takes precedence and is passed to psql directly as a
# connection URI. Otherwise, use the split PA_POSTGRES_HOST/PORT/USER/PASSWORD/DB/
# SSLMODE variables (e.g. for Kubernetes deployments where username/password come
# from separate Secret keys and can't be composed into one URI at the config layer)
# via the standard PG* libpq environment variables, which psql reads automatically.
if [[ -z "$PA_POSTGRES_URL" ]]; then
  export PGHOST="$PA_POSTGRES_HOST"
  export PGPORT="${PA_POSTGRES_PORT:-5432}"
  export PGUSER="$PA_POSTGRES_USER"
  export PGPASSWORD="$PA_POSTGRES_PASSWORD"
  export PGDATABASE="$PA_POSTGRES_DB"
  export PGSSLMODE="${PA_POSTGRES_SSLMODE:-require}"
fi

log_print DEBUG "Hello. Starting Postgres logging of Plane-Alert detections"

TODAY="${TODAY:-$(date +%y%m%d)}"
RECORDSDIR="${RECORDSDIR:-/run/planefence}"
RECORDSFILE="${RECORDSFILE:-$RECORDSDIR/planefence-records-${TODAY}.gz}"

READ_RECORDS

build_index_and_stale INDEX STALE postgres pa

if (( ${#INDEX[@]} )); then
  log_print DEBUG "Records ready for Postgres logging: ${INDEX[*]}"
else
  log_print DEBUG "No records ready for Postgres logging."
fi
if (( ${#STALE[@]} )); then
  log_print INFO "Stale records (no Postgres logging will be attempted): ${STALE[*]}"
else
  log_print DEBUG "No stale records for Postgres logging."
fi
if (( ${#INDEX[@]} == 0 && ${#STALE[@]} == 0 )); then
  log_print DEBUG "No records eligible for Postgres logging."
  exit 0
fi

for idx in "${STALE[@]}"; do
  link[idx]="stale"
  log_print DEBUG "Record index $idx (${pa_records["$idx":icao]}/${pa_records["$idx":tail]}) marked as stale"
done

for idx in "${INDEX[@]}"; do
  if generate_postgres "$idx"; then
    link[idx]=true
    log_print INFO "Postgres insert successful for index $idx (${pa_records["$idx":icao]}/${pa_records["$idx":tail]})"
  else
    link[idx]=false
    log_print ERR "Postgres insert FAILED for index $idx (${pa_records["$idx":icao]}/${pa_records["$idx":tail]})"
  fi
done

log_print DEBUG "Updating records after Postgres logging"

LOCK_RECORDS
READ_RECORDS ignore-lock

if [[ ${#link[@]} -gt 0 ]]; then pa_records[HASNOTIFS]=true; fi

for idx in "${!link[@]}"; do
  pa_records["$idx":postgres:notified]="${link[idx]}"
done

log_print DEBUG "Saving records..."
WRITE_RECORDS ignore-lock
log_print INFO "Postgres logging run completed."
