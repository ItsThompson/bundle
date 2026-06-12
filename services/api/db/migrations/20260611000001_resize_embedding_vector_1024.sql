-- migrate:up
-- Change embedding dimension from 1536 (OpenAI text-embedding-3-small)
-- to 1024 (NVIDIA nv-embedqa-e5-v5).
-- Existing embeddings are incompatible and must be regenerated.

-- Drop the HNSW index (cannot ALTER with index present)
DROP INDEX IF EXISTS idx_embeddings_hnsw;

-- Truncate existing embeddings (incompatible dimensions)
TRUNCATE TABLE artifact_embeddings;

-- Change vector dimension
ALTER TABLE artifact_embeddings
    ALTER COLUMN embedding TYPE vector(1024);

-- Update default model name
ALTER TABLE artifact_embeddings
    ALTER COLUMN model SET DEFAULT 'nvidia/nv-embedqa-e5-v5';

-- Recreate HNSW index for new dimension
CREATE INDEX idx_embeddings_hnsw ON artifact_embeddings
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Reset all completed artifacts to pending so they get re-embedded
UPDATE artifacts
SET status = 'pending', updated_at = now()
WHERE status = 'completed';

-- migrate:down
DROP INDEX IF EXISTS idx_embeddings_hnsw;

TRUNCATE TABLE artifact_embeddings;

ALTER TABLE artifact_embeddings
    ALTER COLUMN embedding TYPE vector(1536);

ALTER TABLE artifact_embeddings
    ALTER COLUMN model SET DEFAULT 'text-embedding-3-small';

CREATE INDEX idx_embeddings_hnsw ON artifact_embeddings
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
