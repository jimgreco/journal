-- Photos attached to entries. Like entry content, the image bytes are
-- encrypted by the server (AES-256-GCM, bound to the user and photo id) before
-- they reach this table. Photos are immutable: an edit that drops a photo, or
-- deleting the entry, deletes the row.

CREATE TABLE IF NOT EXISTS journal_photos (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES journal_users(id) ON DELETE CASCADE,
  entry_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  key_id smallint NOT NULL,
  nonce bytea NOT NULL,
  ciphertext bytea NOT NULL
);
CREATE INDEX IF NOT EXISTS journal_photos_user_entry_idx ON journal_photos(user_id, entry_id);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'journal_runtime') THEN
    GRANT SELECT, INSERT, DELETE ON journal_photos TO journal_runtime;
  END IF;
END $$;
