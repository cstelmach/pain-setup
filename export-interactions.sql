-- psql runs inside the Linux database container. CSV and summary share one read-only snapshot.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL TIME ZONE 'UTC';
COPY (
  SELECT id, received_at, userid, tabid, seq, event_type, target, action,
    country, emotion, enabled, layer, step, count, selected_count,
    has_text, characters, duration_ms, survey_consent, occurred_at
  FROM interactionevents ORDER BY id
) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);
-- Keep the aggregate output separate from the streamed CSV, without a server-side file.
\o /dev/stderr
SELECT json_build_object(
  'exported_at', CURRENT_TIMESTAMP,
  'events', count(*), 'users', count(DISTINCT userid), 'tabs', count(DISTINCT tabid),
  'first_received_at', min(received_at), 'last_received_at', max(received_at),
  'survey_events', count(*) FILTER (WHERE event_type = 'survey'),
  'country_events', count(*) FILTER (WHERE event_type = 'country'),
  'emotion_events', count(*) FILTER (WHERE event_type = 'emotion')
) FROM interactionevents;
\o
COMMIT;
