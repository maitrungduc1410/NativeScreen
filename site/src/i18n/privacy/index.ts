import type { Locale } from "../index";
import en from "./en";
import vi from "./vi";
import zhHans from "./zh-hans";
import zhHant from "./zh-hant";
import ja from "./ja";
import ko from "./ko";
import de from "./de";
import fr from "./fr";
import es from "./es";
import it from "./it";
import ptBr from "./pt-br";
import ru from "./ru";
import cs from "./cs";
import tr from "./tr";
import ar from "./ar";

export type Privacy = typeof en;

/** The date shown as "Last updated". Change it with any change to the English text. */
export const POLICY_DATE = new Date("2026-11-11T00:00:00Z");

const all: Record<string, Privacy> = {
  en, vi, "zh-hans": zhHans, "zh-hant": zhHant, ja, ko, de, fr, es, it, "pt-br": ptBr, ru, cs, tr, ar,
};

export const privacyPathOf = (slug: string) => (slug === "en" ? "/privacy/" : `/${slug}/privacy/`);

const frenchSpacing = (text: string) => text.replace(/ ([:;?!»])/g, " $1").replace(/« /g, "« ");

// Same rules as the home page: a missing or reshaped entry, or a dash the site does not use, fails the build.
export function privacyOf(locale: Locale): Privacy {
  const dict = all[locale.slug];
  if (!dict) throw new Error(`No privacy policy for ${locale.slug}`);
  const check = (key: string, value: unknown, model: unknown): unknown => {
    if (Array.isArray(model)) {
      if (!Array.isArray(value) || value.length !== model.length) throw new Error(`"${key}" in ${locale.slug} privacy has the wrong shape`);
      return value.map((v, i) => check(`${key}[${i}]`, v, model[i]));
    }
    if (typeof value !== "string" || (!value && model)) throw new Error(`Missing "${key}" in ${locale.slug} privacy`);
    if (/[—–…]/.test(value)) throw new Error(`Em dash, en dash or ellipsis in ${locale.slug} privacy ${key}`);
    return locale.slug === "fr" ? frenchSpacing(value) : value;
  };
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(en)) {
    const model = (en as Record<string, unknown>)[key];
    const value = (dict as Record<string, unknown>)[key];
    if (key === "note") {
      // Every translation says that the English text is the binding one.
      if (locale.slug !== "en" && !value) throw new Error(`Missing "note" in ${locale.slug} privacy`);
      out[key] = value ?? "";
      continue;
    }
    out[key] = check(key, value, model);
  }
  return out as Privacy;
}
