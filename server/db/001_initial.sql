-- Apply only to the dedicated `journal` database, as journal_migrator.
-- Entry content (text, mood, tags) is never stored in plaintext: the server
-- encrypts it with AES-256-GCM before it reaches this database, using a key
-- that lives only in the app's runtime environment. Database dumps and
-- backups therefore hold ciphertext only.

CREATE TABLE IF NOT EXISTS journal_users (
  id uuid PRIMARY KEY,
  email text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Sign-in identities (Apple, Google). Several can belong to one user: a new
-- identity joins the user with the same verified email.
CREATE TABLE IF NOT EXISTS journal_identities (
  provider text NOT NULL CHECK (provider IN ('apple', 'google', 'dev')),
  subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 255),
  user_id uuid NOT NULL REFERENCES journal_users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, subject)
);
CREATE INDEX IF NOT EXISTS journal_identities_user_idx ON journal_identities(user_id);

CREATE TABLE IF NOT EXISTS journal_sessions (
  token_hash text PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid NOT NULL REFERENCES journal_users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS journal_sessions_user_idx ON journal_sessions(user_id);

-- Every write takes a fresh revision, so clients sync with ?after=<revision>.
CREATE SEQUENCE IF NOT EXISTS journal_entry_revision;

CREATE TABLE IF NOT EXISTS journal_entries (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES journal_users(id) ON DELETE CASCADE,
  entry_date date NOT NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  source text NOT NULL CHECK (source IN ('text', 'voice')),
  private boolean NOT NULL DEFAULT false,
  key_id smallint,
  nonce bytea,
  ciphertext bytea,
  deleted_at timestamptz,
  revision bigint NOT NULL,
  -- A deleted entry keeps only a tombstone for sync: its content is wiped.
  CHECK (
    (deleted_at IS NULL AND key_id IS NOT NULL AND nonce IS NOT NULL AND ciphertext IS NOT NULL)
    OR (deleted_at IS NOT NULL AND key_id IS NULL AND nonce IS NULL AND ciphertext IS NULL)
  )
);
CREATE INDEX IF NOT EXISTS journal_entries_user_revision_idx ON journal_entries(user_id, revision);
CREATE INDEX IF NOT EXISTS journal_entries_user_date_idx ON journal_entries(user_id, entry_date);

-- Least-privilege runtime access: DML on the app tables and the
-- revision sequence only. The migration ledger stays closed to runtime.
-- Skipped where the role does not exist (tests, local development).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'journal_runtime') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON journal_users, journal_identities, journal_sessions, journal_entries TO journal_runtime;
    GRANT USAGE ON SEQUENCE journal_entry_revision TO journal_runtime;
  END IF;
END $$;
