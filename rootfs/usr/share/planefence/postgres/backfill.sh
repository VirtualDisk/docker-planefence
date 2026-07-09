#!/command/with-contenv bash
#shellcheck shell=bash
#shellcheck disable=SC1091,SC2154,SC2034
# backfill.sh
# One-time script to load every existing Plane-Alert record file into Postgres.
# Unlike send_pa_postgres.sh (which only logs new detections as they happen and
# tracks a per-record "notified" flag), this walks every planefence-records-*.gz
# file in RECORDSDIR and inserts every Plane-Alert record found, regardless of
# its notification state. It never writes back to the record files.
#
# Usage: run once, manually, inside the container:
#   docker exec -it <container> /usr/share/planefence/postgres/backfill.sh
#
# Safe to re-run: inserts are deduplicated on (icao, detected_at) via
# ON CONFLICT DO NOTHING, same as send_pa_postgres.sh.
#
# Copyright 2026 Ramon F. Kolb (kx1t), and contributors - licensed under the terms and conditions
# of GPLv3. The terms and conditions of this license are included with the Github
# distribution of this package, and are also available here:
# https://github.com/sdr-enthusiasts/docker-planefence
#

source /scripts/pf-common
source "/usr/share/planefence/plane-alert.conf"

if [[ -z "$PA_POSTGRES_URL" && -z "$PA_POSTGRES_HOST" ]]; then
  echo "PA_POSTGRES_URL / PA_POSTGRES_HOST are not set in planefence.config - nothing to backfill to." >&2
  exit 1
fi

if [[ -z "$PA_POSTGRES_URL" ]]; then
  export PGHOST="$PA_POSTGRES_HOST"
  export PGPORT="${PA_POSTGRES_PORT:-5432}"
  export PGUSER="$PA_POSTGRES_USER"
  export PGPASSWORD="$PA_POSTGRES_PASSWORD"
  export PGDATABASE="$PA_POSTGRES_DB"
  export PGSSLMODE="${PA_POSTGRES_SSLMODE:-require}"
fi

RECORDSDIR="${RECORDSDIR:-/usr/share/planefence/persist/records}"

insert_record() {
  # Insert one Plane-Alert detection record into Postgres. Mirrors
  # send_pa_postgres.sh's generate_postgres(), minus the notified-flag bookkeeping.
  local idx="$1" k
  declare -a keys=()
  for k in "${!pa_records[@]}"; do
    if [[ $k == "$idx:"* ]]; then keys+=("$k"); fi
  done

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

  local -a psql_args=()
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

  # psql's -c/--command mode does not perform :'variable' interpolation - only
  # scripts read via -f or stdin do - so the SQL is piped in rather than passed
  # via -c.
  psql "${psql_args[@]}" <<<"$sql"
}

# Make sure the unique index the ON CONFLICT clause above relies on exists,
# in case this is run against a database created before it was added to schema.sql.
{ [[ -n "$PA_POSTGRES_URL" ]] && psql -X -q -v ON_ERROR_STOP=1 "$PA_POSTGRES_URL" \
    -c "CREATE UNIQUE INDEX IF NOT EXISTS pa_detections_icao_detected_at_uidx ON pa_detections (icao, detected_at);"; } || \
  psql -X -q -v ON_ERROR_STOP=1 \
    -c "CREATE UNIQUE INDEX IF NOT EXISTS pa_detections_icao_detected_at_uidx ON pa_detections (icao, detected_at);"

shopt -s nullglob
files=("$RECORDSDIR"/planefence-records-*.gz)
shopt -u nullglob

if (( ${#files[@]} == 0 )); then
  echo "No record files found in $RECORDSDIR - nothing to backfill." >&2
  exit 0
fi

total=0
inserted=0
failed=0

for f in "${files[@]}"; do
  echo "Processing $f..."
  unset pa_records records heatmap last_idx_for_icao lastseen_for_icao pa_last_idx_for_icao
  declare -gA pa_records=()
  # shellcheck disable=SC1090
  source <(gzip -cd "$f" || true)

  maxidx="${pa_records[maxindex]:--1}"
  for (( idx=0; idx<=maxidx; idx++ )); do
    [[ -n "${pa_records["$idx":icao]+set}" ]] || continue
    total=$((total + 1))
    if insert_record "$idx"; then
      inserted=$((inserted + 1))
    else
      failed=$((failed + 1))
      echo "  FAILED to insert record $idx (${pa_records["$idx":icao]}/${pa_records["$idx":tail]})" >&2
    fi
  done
done

echo "Backfill complete: $total record(s) found, $inserted inserted (or already present), $failed failed."
(( failed == 0 ))
