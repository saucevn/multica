-- The rename in 059.up writes `hira-N` slugs. We don't record the prior slug,
-- so a generic rollback isn't possible. In practice no prod workspaces hold
-- `hira` at audit time (newly-coined brand), so this down is a no-op.
SELECT 1;
