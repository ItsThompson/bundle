-- migrate:up
CREATE TABLE public.artifacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('screenshot', 'note', 'link')),
    storage_path TEXT NOT NULL,
    content_text TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    attempts INT NOT NULL DEFAULT 0,
    max_attempts INT NOT NULL DEFAULT 3,
    scheduled_after TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_artifacts_user_created ON artifacts(user_id, created_at DESC);
CREATE INDEX idx_artifacts_status ON artifacts(status) WHERE status IN ('pending', 'processing');
CREATE INDEX idx_artifacts_updated ON artifacts(updated_at);

-- migrate:down
DROP TABLE public.artifacts;
