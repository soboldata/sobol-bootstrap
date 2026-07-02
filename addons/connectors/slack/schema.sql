-- Slack connector schema for sobol_mirror DB
-- Idempotent: safe to re-run. CREATE IF NOT EXISTS everywhere.
--
-- Owned by sobol_writer; agent_view.* GRANT SELECT to sobol_agent_readonly.
-- Run by setup-connector-slack.sh inside the postgres-mirror CT as the
-- postgres superuser, then ownership is transferred to sobol_writer.

-- ----- Raw tables (the mirror) ----------------------------------------------

CREATE SCHEMA IF NOT EXISTS slack AUTHORIZATION sobol_writer;

CREATE TABLE IF NOT EXISTS slack.channels (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  is_archived     BOOLEAN DEFAULT FALSE,
  is_private      BOOLEAN DEFAULT FALSE,
  is_im           BOOLEAN DEFAULT FALSE,
  is_mpim         BOOLEAN DEFAULT FALSE,
  num_members     INTEGER,
  purpose         TEXT,
  topic           TEXT,
  created_unix    BIGINT,
  synced_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS slack.users (
  id              TEXT PRIMARY KEY,
  name            TEXT,
  real_name       TEXT,
  display_name    TEXT,
  email           TEXT,
  is_bot          BOOLEAN DEFAULT FALSE,
  is_admin        BOOLEAN DEFAULT FALSE,
  is_deleted      BOOLEAN DEFAULT FALSE,
  tz              TEXT,
  synced_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS slack.messages (
  ts              TEXT NOT NULL,                  -- Slack's microsecond ts (PK)
  channel_id      TEXT NOT NULL REFERENCES slack.channels(id),
  user_id         TEXT REFERENCES slack.users(id),
  text            TEXT,
  thread_ts       TEXT,                           -- if part of a thread
  reply_count     INTEGER DEFAULT 0,              -- if this msg is a thread parent
  reactions       JSONB,                          -- [{emoji:'thumbsup', count:3, users:[...]}, ...]
  files           JSONB,                          -- file attachments metadata
  message_type    TEXT,                           -- 'message', 'channel_join', etc.
  subtype         TEXT,                           -- 'bot_message', 'channel_topic', etc.
  edited_ts       TEXT,                           -- if edited
  synced_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (ts, channel_id)
);

CREATE INDEX IF NOT EXISTS idx_slack_msg_channel_ts ON slack.messages(channel_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_slack_msg_thread ON slack.messages(thread_ts) WHERE thread_ts IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_slack_msg_user ON slack.messages(user_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_slack_msg_text_search ON slack.messages USING gin(to_tsvector('english', coalesce(text, '')));

CREATE TABLE IF NOT EXISTS slack.threads (
  parent_ts            TEXT NOT NULL,
  channel_id           TEXT NOT NULL REFERENCES slack.channels(id),
  last_reply_ts        TEXT,
  reply_count          INTEGER NOT NULL DEFAULT 0,
  participant_count    INTEGER NOT NULL DEFAULT 0,
  synced_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (parent_ts, channel_id)
);

CREATE TABLE IF NOT EXISTS slack.reactions (
  message_ts      TEXT NOT NULL,
  channel_id      TEXT NOT NULL,
  emoji           TEXT NOT NULL,
  user_id         TEXT NOT NULL,
  synced_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (message_ts, channel_id, emoji, user_id)
);

CREATE INDEX IF NOT EXISTS idx_slack_react_message ON slack.reactions(message_ts, channel_id);

-- ----- agent_view layer (the agent-facing surface) --------------------------

-- recent_24h — flat list with channel + user names joined
CREATE OR REPLACE VIEW agent_view.slack_recent_24h AS
SELECT
  c.name AS channel,
  COALESCE(u.real_name, u.name, m.user_id) AS user_real_name,
  m.text,
  m.ts,
  m.thread_ts,
  COALESCE((
    SELECT SUM((r->>'count')::INTEGER)
    FROM jsonb_array_elements(m.reactions) r
  ), 0) AS reaction_count
FROM slack.messages m
JOIN slack.channels c ON c.id = m.channel_id
LEFT JOIN slack.users u ON u.id = m.user_id
WHERE m.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '24 hours')
  AND NOT c.is_im
  AND NOT c.is_mpim
  AND m.subtype IS NULL  -- exclude joins/topic-changes/etc.
ORDER BY m.ts DESC;

-- recent_7d — same shape for weekly digests
CREATE OR REPLACE VIEW agent_view.slack_recent_7d AS
SELECT
  c.name AS channel,
  COALESCE(u.real_name, u.name, m.user_id) AS user_real_name,
  m.text,
  m.ts,
  m.thread_ts,
  COALESCE((SELECT SUM((r->>'count')::INTEGER) FROM jsonb_array_elements(m.reactions) r), 0) AS reaction_count
FROM slack.messages m
JOIN slack.channels c ON c.id = m.channel_id
LEFT JOIN slack.users u ON u.id = m.user_id
WHERE m.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '7 days')
  AND NOT c.is_im
  AND NOT c.is_mpim
  AND m.subtype IS NULL
ORDER BY m.ts DESC;

-- channel_activity_24h — message counts per channel
CREATE OR REPLACE VIEW agent_view.slack_channel_activity_24h AS
SELECT
  c.name AS channel,
  COUNT(*) AS message_count,
  COUNT(DISTINCT m.user_id) AS active_user_count,
  (SELECT COALESCE(u.real_name, u.name) FROM slack.users u
     WHERE u.id = (
       SELECT user_id FROM slack.messages m2
       WHERE m2.channel_id = c.id
         AND m2.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '24 hours')
         AND m2.subtype IS NULL
       GROUP BY user_id ORDER BY COUNT(*) DESC LIMIT 1
     )
  ) AS top_user
FROM slack.messages m
JOIN slack.channels c ON c.id = m.channel_id
WHERE m.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '24 hours')
  AND NOT c.is_im AND NOT c.is_mpim
  AND m.subtype IS NULL
GROUP BY c.id, c.name
HAVING COUNT(*) > 0
ORDER BY COUNT(*) DESC;

-- threads_with_questions — OP has '?', no reply within 24h
CREATE OR REPLACE VIEW agent_view.slack_threads_with_questions AS
SELECT
  c.name AS channel,
  COALESCE(u.real_name, u.name, m.user_id) AS op_user,
  m.text AS op_text,
  m.ts AS op_ts,
  ROUND(EXTRACT(EPOCH FROM (NOW() - to_timestamp(m.ts::NUMERIC))) / 3600, 1) AS age_hours
FROM slack.messages m
JOIN slack.channels c ON c.id = m.channel_id
LEFT JOIN slack.users u ON u.id = m.user_id
WHERE m.text LIKE '%?%'
  AND m.thread_ts IS NULL  -- top-level message (not a reply)
  AND m.subtype IS NULL
  AND NOT c.is_im AND NOT c.is_mpim
  AND m.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '7 days')
  -- No replies AND not the parent of a thread
  AND NOT EXISTS (
    SELECT 1 FROM slack.messages r
    WHERE r.thread_ts = m.ts AND r.channel_id = m.channel_id
  )
ORDER BY m.ts DESC;

-- threads_with_decisions — keywords suggest a decision being made/asked
CREATE OR REPLACE VIEW agent_view.slack_threads_with_decisions AS
SELECT
  c.name AS channel,
  COALESCE(u.real_name, u.name, m.user_id) AS user_real_name,
  m.text,
  m.ts,
  m.thread_ts
FROM slack.messages m
JOIN slack.channels c ON c.id = m.channel_id
LEFT JOIN slack.users u ON u.id = m.user_id
WHERE m.subtype IS NULL
  AND NOT c.is_im AND NOT c.is_mpim
  AND m.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '7 days')
  AND (
    m.text ~* '\m(decide|decision|should we|let''?s go with|approve|approved|let''?s do|going with)\M'
  )
ORDER BY m.ts DESC;

-- action_items — pattern: @user can you / please / could you / would you
CREATE OR REPLACE VIEW agent_view.slack_action_items AS
SELECT
  c.name AS channel,
  m.text AS action_text,
  m.ts,
  -- best-effort assignee extraction
  (regexp_match(m.text, '<@(U[A-Z0-9]+)>'))[1] AS assignee_user_id,
  COALESCE(
    (SELECT real_name FROM slack.users WHERE id = (regexp_match(m.text, '<@(U[A-Z0-9]+)>'))[1]),
    (regexp_match(m.text, '<@(U[A-Z0-9]+)>'))[1]
  ) AS assignee_user
FROM slack.messages m
JOIN slack.channels c ON c.id = m.channel_id
WHERE m.text ~* '<@U[A-Z0-9]+>.{1,50}(can you|please|could you|would you|need you)'
  AND m.subtype IS NULL
  AND NOT c.is_im AND NOT c.is_mpim
  AND m.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '7 days')
ORDER BY m.ts DESC;

-- high_reaction_messages_24h — messages with notable engagement
CREATE OR REPLACE VIEW agent_view.slack_high_reaction_messages_24h AS
SELECT
  c.name AS channel,
  COALESCE(u.real_name, u.name) AS user_real_name,
  m.text,
  m.ts,
  COALESCE((SELECT SUM((r->>'count')::INTEGER) FROM jsonb_array_elements(m.reactions) r), 0) AS reaction_count
FROM slack.messages m
JOIN slack.channels c ON c.id = m.channel_id
LEFT JOIN slack.users u ON u.id = m.user_id
WHERE m.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '24 hours')
  AND NOT c.is_im AND NOT c.is_mpim
  AND m.subtype IS NULL
  AND COALESCE((SELECT SUM((r->>'count')::INTEGER) FROM jsonb_array_elements(m.reactions) r), 0) >= 3
ORDER BY reaction_count DESC;

-- quiet_users_7d — used to post regularly, didn't this week
CREATE OR REPLACE VIEW agent_view.slack_quiet_users_7d AS
WITH user_weekly AS (
  SELECT
    m.user_id,
    DATE_TRUNC('week', to_timestamp(m.ts::NUMERIC)) AS week,
    COUNT(*) AS msg_count
  FROM slack.messages m
  JOIN slack.channels c ON c.id = m.channel_id
  WHERE m.subtype IS NULL
    AND NOT c.is_im AND NOT c.is_mpim
    AND m.user_id IS NOT NULL
    AND m.ts::NUMERIC >= EXTRACT(EPOCH FROM NOW() - INTERVAL '5 weeks')
  GROUP BY m.user_id, week
)
SELECT
  COALESCE(u.real_name, u.name) AS user_real_name,
  uw.user_id,
  AVG(prior.msg_count)::INTEGER AS avg_prior_weeks,
  COALESCE(this_week.msg_count, 0) AS this_week
FROM (SELECT DISTINCT user_id FROM user_weekly) uw
JOIN slack.users u ON u.id = uw.user_id
LEFT JOIN user_weekly this_week
  ON this_week.user_id = uw.user_id
  AND this_week.week = DATE_TRUNC('week', NOW())
LEFT JOIN user_weekly prior
  ON prior.user_id = uw.user_id
  AND prior.week BETWEEN DATE_TRUNC('week', NOW() - INTERVAL '4 weeks')
                    AND DATE_TRUNC('week', NOW() - INTERVAL '1 week')
WHERE NOT u.is_bot AND NOT u.is_deleted
GROUP BY u.real_name, u.name, uw.user_id, this_week.msg_count
HAVING AVG(prior.msg_count) > 5
   AND COALESCE(this_week.msg_count, 0) < 2;

-- ----- Permissions ----------------------------------------------------------

GRANT USAGE ON SCHEMA slack TO sobol_writer;  -- writer can manage raw
GRANT ALL ON ALL TABLES IN SCHEMA slack TO sobol_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA slack GRANT ALL ON TABLES TO sobol_writer;

-- readonly does NOT get direct access to slack.*. Only via agent_view.*.
GRANT SELECT ON
  agent_view.slack_recent_24h,
  agent_view.slack_recent_7d,
  agent_view.slack_channel_activity_24h,
  agent_view.slack_threads_with_questions,
  agent_view.slack_threads_with_decisions,
  agent_view.slack_action_items,
  agent_view.slack_high_reaction_messages_24h,
  agent_view.slack_quiet_users_7d
TO sobol_agent_readonly;
