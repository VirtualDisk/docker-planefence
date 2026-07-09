# Log Plane-Alert detections to Postgres and query them with Grafana

This lets you keep a permanent, queryable history of every Plane-Alert detection
(instead of just one-shot notifications) so you can build Grafana panels for
detections-over-time and filter/group by tag, registration, owner, etc.

This document assumes you already have a Postgres database and a Grafana instance
running somewhere reachable from the Planefence container. Setting those up is
outside the scope of this document.

## Table of Contents
- [Log Plane-Alert detections to Postgres and query them with Grafana](#log-plane-alert-detections-to-postgres-and-query-them-with-grafana)
  - [Table of Contents](#table-of-contents)
  - [1. Create the table](#1-create-the-table)
  - [2. Configure Planefence](#2-configure-planefence)
  - [3. Backfill existing detections](#3-backfill-existing-detections)
  - [4. Add Postgres as a Grafana data source](#4-add-postgres-as-a-grafana-data-source)
  - [5. Example Grafana queries](#5-example-grafana-queries)
    - [Detections over time](#detections-over-time)
    - [Filter/group by tag](#filtergroup-by-tag)
- [Summary of License Terms](#summary-of-license-terms)

## 1. Create the table

Run the schema once against your database:

```bash
psql "postgres://user:password@myhost:5432/mydb" \
  -f rootfs/usr/share/planefence/postgres/schema.sql
```

This creates a single table, `pa_detections`, with one row per Plane-Alert
detection (ICAO, tail, callsign, owner, aircraft type, category/tags, lat/lon,
distance, altitude, groundspeed, squawk, route, plus a `raw` `jsonb` column with
every field Planefence tracked for that record, as a safety net for anything not
promoted to its own column).

## 2. Configure Planefence

In your `planefence.config` file, set `PA_POSTGRES_URL` to a standard Postgres
connection URI:

```bash
PA_POSTGRES_URL="postgres://user:password@myhost:5432/mydb?sslmode=disable"
```

If your username/password come from separate secret keys and can't be composed
into one URI (e.g. a Kubernetes `Secret` with `username`/`password` keys wired in
via `secretKeyRef`), set these instead and leave `PA_POSTGRES_URL` empty:

```bash
PA_POSTGRES_HOST="myhost"
PA_POSTGRES_PORT="5432"
PA_POSTGRES_USER="user"
PA_POSTGRES_PASSWORD="password"
PA_POSTGRES_DB="mydb"
PA_POSTGRES_SSLMODE="require"
```

Leave both forms empty (the default) to disable Postgres logging. Once set, every new
Plane-Alert detection is inserted into `pa_detections` on the next Planefence
cycle (default every 60 seconds), the same way existing notifications (Discord,
MQTT, etc.) are sent.

## 3. Backfill existing detections

`send_pa_postgres.sh` only logs new detections going forward. To load
everything Planefence already has on disk (all `planefence-records-*.gz`
files under `RECORDSDIR`, default `/usr/share/planefence/persist/records`),
run the one-time backfill script inside the container after step 2 is
configured:

```bash
docker exec -it <container> /usr/share/planefence/postgres/backfill.sh
```

It walks every record file and inserts every Plane-Alert record found,
regardless of notification state. Inserts are deduplicated on
`(icao, detected_at)`, so it's safe to re-run (e.g. after adding more
history) without creating duplicate rows.

## 4. Add Postgres as a Grafana data source

In Grafana: **Connections → Data sources → Add data source → PostgreSQL**, then
point it at the same host/port/database/credentials as `PA_POSTGRES_URL`.

## 5. Example Grafana queries

### Detections over time

A time series panel using this as a raw SQL query:

```sql
SELECT
  date_trunc('hour', detected_at) AS time,
  count(*) AS detections
FROM pa_detections
WHERE detected_at BETWEEN $__timeFrom() AND $__timeTo()
GROUP BY 1
ORDER BY 1
```

### Filter/group by tag

Add a Grafana dashboard variable named `tag`, with query:

```sql
SELECT DISTINCT tag1 FROM pa_detections WHERE tag1 IS NOT NULL ORDER BY 1
```

Then filter a panel's query by it:

```sql
SELECT detected_at AS time, icao, tail, callsign, owner, category, tag1, tag2, tag3
FROM pa_detections
WHERE detected_at BETWEEN $__timeFrom() AND $__timeTo()
  AND ('$tag' = 'All' OR '$tag' IN (tag1, tag2, tag3))
ORDER BY detected_at DESC
```

You can filter/group the same way on `icao`, `tail`, `owner`, `category`, or any
other column, or reach into the `raw` `jsonb` column for fields that don't have
their own column, e.g. `raw->>'link:map'`.

# Summary of License Terms

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
