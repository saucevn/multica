import {
  DEFAULT_LOCALE,
  type LocaleResources,
  type SupportedLocale,
} from "@multica/core/i18n";
import { RESOURCES } from "./index";

/**
 * The resource bundles to hand `I18nProvider` for a given active locale.
 *
 * Always includes {@link DEFAULT_LOCALE} next to the active one. `createI18n`
 * declares `fallbackLng: "en"`, but i18next resolves a fallback only from a
 * bundle it actually holds — passing `{ [locale]: RESOURCES[locale] }` alone
 * leaves that fallback unreachable, and every key the locale is missing renders
 * as its raw key ("common.log_out") instead of the English text.
 *
 * This fork feels that immediately: `vi` is fork-owned, so an upstream merge
 * adds English keys without touching it, and the Vietnamese UI leaks raw keys
 * on every sync until translation catches up. Degrading to English instead is
 * worth one extra bundle in the payload.
 *
 * Web and desktop both call this — keep the fallback policy in one place.
 */
export function resourcesForLocale(
  locale: SupportedLocale,
): Record<string, LocaleResources> {
  if (locale === DEFAULT_LOCALE) return { [locale]: RESOURCES[locale] };
  return {
    [locale]: RESOURCES[locale],
    [DEFAULT_LOCALE]: RESOURCES[DEFAULT_LOCALE],
  };
}
