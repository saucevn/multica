-- Audit + rename existing workspace slugs against the newly-added reserved
-- entry `hira` (post-rebrand brand name from multica → hira).
--
-- Same playbook as MUL-961/MUL-972: scan for any workspace currently using
-- the slug, rename to `<slug>-N` where N is the lowest free integer, then
-- assert the post-condition.
--
-- Keep this slug list aligned with:
--   - server/internal/handler/workspace_reserved_slugs.go
--   - packages/core/paths/reserved-slugs.ts

DO $$
DECLARE
  r RECORD;
  n INT;
BEGIN
  FOR r IN
    SELECT id, slug FROM workspace WHERE slug = 'hira'
  LOOP
    n := 1;
    WHILE EXISTS (SELECT 1 FROM workspace WHERE slug = r.slug || '-' || n) LOOP
      n := n + 1;
    END LOOP;
    UPDATE workspace SET slug = r.slug || '-' || n WHERE id = r.id;
    RAISE NOTICE 'Renamed workspace % slug from % to %', r.id, r.slug, r.slug || '-' || n;
  END LOOP;
END $$;

DO $$
DECLARE
  conflict_count INT;
BEGIN
  SELECT COUNT(*) INTO conflict_count FROM workspace WHERE slug = 'hira';
  IF conflict_count > 0 THEN
    RAISE EXCEPTION 'After rename pass, % workspace(s) still on reserved slug `hira`. Investigate.', conflict_count;
  END IF;
END $$;
