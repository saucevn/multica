// @vitest-environment node
import { describe, expect, it } from "vitest";
import { RESOURCES } from "./index";

/**
 * Value-level guard for the `vi` bundle: every interpolation placeholder in a
 * Vietnamese string must exist in its English counterpart, and vice-versa.
 *
 * parity.test.ts compares key NAMES only, so neither failure mode below is
 * visible to it — and both were live in this fork:
 *
 *  - vi drops a placeholder EN has (`"Remove argument {{index}}"` →
 *    `"Xóa tham số"`), silently losing the value from an aria-label.
 *  - vi keeps a placeholder EN has since dropped (`"{{name}} sẽ được kích
 *    hoạt…"` against `"Will start from this comment."`), so i18next has nothing
 *    to interpolate and a literal `{{name}}` reaches the screen.
 *
 * The second is the one an upstream sync manufactures: upstream rewords an
 * English string and removes an interpolation, the key name never changes, so
 * nothing flags that the fork-owned `vi` value still refers to a variable
 * nobody passes any more.
 */

type Json = Record<string, unknown>;

function flatten(obj: unknown, prefix = ""): Array<[string, string]> {
  if (typeof obj === "string") return [[prefix, obj]];
  if (obj === null || typeof obj !== "object") return [];
  return Object.entries(obj as Json).flatMap(([k, v]) =>
    flatten(v, prefix ? `${prefix}.${k}` : k),
  );
}

/** Placeholder names in a string: `{{count}}`, `{{- raw}}`, `{{v, number}}`. */
function placeholders(value: string): string[] {
  return [...value.matchAll(/\{\{\s*-?\s*([a-zA-Z0-9_]+)[^}]*\}\}/g)]
    .flatMap((m) => (m[1] ? [m[1]] : []))
    .sort();
}

const en = RESOURCES.en as unknown as Record<string, Json>;
const vi = RESOURCES.vi as unknown as Record<string, Json>;

describe("vi placeholder parity", () => {
  for (const ns of Object.keys(en)) {
    it(`${ns}: vi interpolations match en`, () => {
      const enStrings = new Map(flatten(en[ns] ?? {}));
      const offenders: string[] = [];

      for (const [key, viValue] of flatten(vi[ns] ?? {})) {
        // Vietnamese has no grammatical number, so vi collapses EN's
        // `_one`/`_other` pair into a single `_other`; fall back to the `_one`
        // source when that is the only English form carrying this key.
        const enValue =
          enStrings.get(key) ?? enStrings.get(key.replace(/_other$/, "_one"));
        if (enValue === undefined) continue;

        const expected = placeholders(enValue).join(",");
        const actual = placeholders(viValue).join(",");
        if (expected !== actual) {
          offenders.push(`${key}: en {${expected}} vs vi {${actual}}`);
        }
      }

      expect(offenders).toEqual([]);
    });
  }
});
