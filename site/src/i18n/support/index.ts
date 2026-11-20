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

export type Support = typeof en;

const all: Record<string, Support> = {
  en, vi, "zh-hans": zhHans, "zh-hant": zhHant, ja, ko, de, fr, es, it, "pt-br": ptBr, ru, cs, tr, ar,
};

export const SUPPORT_EMAIL = "hello@nativescreen.app";

export const supportPathOf = (slug: string) => (slug === "en" ? "/support/" : `/${slug}/support/`);

const frenchSpacing = (text: string) => text.replace(/ ([:;?!»])/g, " $1").replace(/« /g, "« ");

// Same rules as the other pages: a missing or reshaped entry, or a dash the site does not use, fails the build.
export function supportOf(locale: Locale): Support {
  const dict = all[locale.slug];
  if (!dict) throw new Error(`No support page for ${locale.slug}`);
  const check = (key: string, value: unknown, model: unknown): unknown => {
    if (Array.isArray(model)) {
      if (!Array.isArray(value) || value.length !== model.length) throw new Error(`"${key}" in ${locale.slug} support has the wrong shape`);
      return value.map((v, i) => check(`${key}[${i}]`, v, model[i]));
    }
    if (typeof value !== "string" || !value) throw new Error(`Missing "${key}" in ${locale.slug} support`);
    if (/[—–…]/.test(value)) throw new Error(`Em dash, en dash or ellipsis in ${locale.slug} support ${key}`);
    return locale.slug === "fr" ? frenchSpacing(value) : value;
  };
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(en)) {
    out[key] = check(key, (dict as Record<string, unknown>)[key], (en as Record<string, unknown>)[key]);
  }
  return out as Support;
}
