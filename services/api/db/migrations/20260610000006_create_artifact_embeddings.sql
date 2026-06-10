-- migrate:up
CREATE TABLE public.artifact_embeddings (
    artifact_id UUID PRIMARY KEY REFERENCES artifacts(id) ON DELETE CASCADE,
    embedding vector(1536) NOT NULL,
    model TEXT NOT NULL DEFAULT 'text-embedding-3-small',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- HNSW index for approximate nearest neighbor search
CREATE INDEX idx_embeddings_hnsw ON artifact_embeddings
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- migrate:down
DROP TABLE public.artifact_embeddings;
