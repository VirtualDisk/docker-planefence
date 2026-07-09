-- Schema for logging Plane-Alert detections to Postgres for querying with Grafana.
-- Run this once against the database referenced by PA_POSTGRES_URL in plane-alert.conf:
--   psql "$PA_POSTGRES_URL" -f schema.sql

CREATE TABLE IF NOT EXISTS pa_detections (
    id                 bigserial PRIMARY KEY,
    inserted_at        timestamptz NOT NULL DEFAULT now(),
    detected_at        timestamptz NOT NULL,
    station            text,
    icao               text NOT NULL,
    tail               text,
    callsign           text,
    owner              text,
    aircraft_type      text,
    category           text,
    tag1               text,
    tag2               text,
    tag3               text,
    lat                double precision,
    lon                double precision,
    distance_value     double precision,
    distance_unit      text,
    altitude_value     double precision,
    altitude_unit      text,
    groundspeed_value  double precision,
    groundspeed_unit   text,
    squawk             text,
    route              text,
    raw                jsonb
);

CREATE INDEX IF NOT EXISTS pa_detections_detected_at_idx ON pa_detections (detected_at);
CREATE INDEX IF NOT EXISTS pa_detections_icao_idx        ON pa_detections (icao);
CREATE INDEX IF NOT EXISTS pa_detections_tail_idx        ON pa_detections (tail);
CREATE INDEX IF NOT EXISTS pa_detections_tag1_idx        ON pa_detections (tag1);

-- Lets backfill.sh (and repeated live inserts) use ON CONFLICT DO NOTHING to
-- stay idempotent instead of duplicating rows on re-run.
CREATE UNIQUE INDEX IF NOT EXISTS pa_detections_icao_detected_at_uidx ON pa_detections (icao, detected_at);
