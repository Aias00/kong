-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

return {
  postgres = {
    up = [[
      DO $$
      BEGIN
        ALTER TABLE IF EXISTS ONLY mtls_auth_credentials ADD tags TEXT[];
      EXCEPTION WHEN DUPLICATE_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
      DO $$
      BEGIN
        CREATE INDEX IF NOT EXISTS mtls_auth_credentials_tags_idx ON mtls_auth_credentials USING GIN(tags);
      EXCEPTION WHEN UNDEFINED_COLUMN THEN
        -- Do nothing, accept existing state
      END$$;
      DROP TRIGGER IF EXISTS mtls_auth_credentials_sync_tags_trigger ON mtls_auth_credentials;
      DO $$
      BEGIN
        CREATE TRIGGER mtls_auth_credentials_sync_tags_trigger
        AFTER INSERT OR UPDATE OF tags OR DELETE ON mtls_auth_credentials
        FOR EACH ROW
        EXECUTE PROCEDURE sync_tags();
      EXCEPTION WHEN UNDEFINED_COLUMN OR UNDEFINED_TABLE THEN
        -- Do nothing, accept existing state
      END$$;
    ]],
  },
}
