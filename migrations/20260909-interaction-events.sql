-- Additive migration. Run once against the existing database; never reinitialize its data.
CREATE TABLE IF NOT EXISTS interactionevents (
  id BIGSERIAL PRIMARY KEY,
  received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  userid INTEGER NOT NULL REFERENCES users(id),
  tabid UUID NOT NULL,
  seq BIGINT NOT NULL CHECK (seq >= 0),
  event_type TEXT NOT NULL,
  target TEXT NOT NULL,
  action TEXT NOT NULL,
  country CHAR(3),
  emotion TEXT,
  enabled BOOLEAN,
  layer TEXT,
  step SMALLINT,
  count INTEGER,
  selected_count INTEGER,
  has_text BOOLEAN,
  characters INTEGER,
  duration_ms INTEGER,
  survey_consent BOOLEAN NOT NULL,
  UNIQUE (tabid, seq)
);
CREATE INDEX IF NOT EXISTS interactionevents_received_at ON interactionevents(received_at);
-- Batch ingestion resolves the anonymous registration ID once, including on long-running kiosks.
CREATE INDEX IF NOT EXISTS interaction_users_userid ON users(userid);
-- Client click time is distinct from batched receipt time. Old clients/records remain null.
ALTER TABLE interactionevents ADD COLUMN IF NOT EXISTS occurred_at TIMESTAMPTZ;
