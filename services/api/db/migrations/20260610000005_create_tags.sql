-- migrate:up
CREATE TABLE public.artifact_tags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_id UUID NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (artifact_id, name)
);

CREATE INDEX idx_tags_artifact ON artifact_tags(artifact_id);
CREATE INDEX idx_tags_name ON artifact_tags(name);

-- Full-text search index on artifact content
ALTER TABLE artifacts ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', COALESCE(content_text, ''))
    ) STORED;

CREATE INDEX idx_artifacts_fts ON artifacts USING gin(search_vector);

-- migrate:down
ALTER TABLE artifacts DROP COLUMN search_vector;
DROP TABLE public.artifact_tags;
