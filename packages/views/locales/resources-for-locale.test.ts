import { describe, expect, it } from "vitest";
import { DEFAULT_LOCALE, SUPPORTED_LOCALES } from "@multica/core/i18n";
import { RESOURCES } from "./index";
import { resourcesForLocale } from "./resources-for-locale";

/**
 * `createI18n` sets `fallbackLng: "en"`, but i18next can only fall back to a
 * language whose bundle is actually loaded. Shipping only the active locale
 * makes that fallback dead weight: any key the locale is missing renders as the
 * raw key string ("common.log_out") instead of the English text.
 *
 * That is not hypothetical for this fork — `vi` trails `en` by whatever an
 * upstream merge just added, so every sync would otherwise leak raw keys into
 * the Vietnamese UI until the translation catches up.
 */
describe("resourcesForLocale", () => {
  it("ships the fallback bundle alongside a non-default locale", () => {
    const resources = resourcesForLocale("vi");
    expect(Object.keys(resources).sort()).toEqual(["en", "vi"]);
    expect(resources.vi).toBe(RESOURCES.vi);
    expect(resources.en).toBe(RESOURCES.en);
  });

  it("ships a single bundle for the default locale", () => {
    expect(Object.keys(resourcesForLocale(DEFAULT_LOCALE))).toEqual([
      DEFAULT_LOCALE,
    ]);
  });

  it("gives every supported locale a reachable fallback", () => {
    for (const locale of SUPPORTED_LOCALES) {
      const resources = resourcesForLocale(locale);
      expect(resources[locale]).toBeDefined();
      expect(resources[DEFAULT_LOCALE]).toBeDefined();
    }
  });

  it("carries the namespace a lagging locale would otherwise render raw", () => {
    // onboarding.common.log_out is a real case: upstream's questionnaire rewrite
    // added it to `en`, and a locale that has not caught up rendered the key.
    const resources = resourcesForLocale("vi");
    expect(resources.en?.onboarding).toBeDefined();
  });
});
