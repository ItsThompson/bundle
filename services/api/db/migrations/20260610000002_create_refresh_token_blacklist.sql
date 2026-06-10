-- migrate:up
CREATE TABLE auth.refresh_token_blacklist (
    jti UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_refresh_blacklist_user ON auth.refresh_token_blacklist(user_id);
CREATE INDEX idx_refresh_blacklist_expires ON auth.refresh_token_blacklist(expires_at);

-- migrate:down
DROP TABLE auth.refresh_token_blacklist;
