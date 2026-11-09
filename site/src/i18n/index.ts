import en from "./en";
import vi from "./vi";
import zhHans from "./zh-hans";
import ja from "./ja";
import de from "./de";
import fr from "./fr";
import es from "./es";
import ptBr from "./pt-br";

export type Dict = typeof en;

export const SITE = "https://nativescreen.app";

export const locales = [
  { slug: "en", lang: "en", og: "en_US", name: "English", dict: en },
  { slug: "vi", lang: "vi", og: "vi_VN", name: "Tiếng Việt", dict: vi },
  { slug: "zh-hans", lang: "zh-Hans", og: "zh_CN", name: "简体中文", dict: zhHans },
  { slug: "ja", lang: "ja", og: "ja_JP", name: "日本語", dict: ja },
  { slug: "de", lang: "de", og: "de_DE", name: "Deutsch", dict: de },
  { slug: "fr", lang: "fr", og: "fr_FR", name: "Français", dict: fr },
  { slug: "es", lang: "es", og: "es_ES", name: "Español", dict: es },
  { slug: "pt-br", lang: "pt-BR", og: "pt_BR", name: "Português (Brasil)", dict: ptBr },
] as const;

export type Locale = (typeof locales)[number];

export const pathOf = (slug: string) => (slug === "en" ? "/" : `/${slug}/`);
export const urlOf = (slug: string) => SITE + pathOf(slug);
export const ogImageOf = (slug: string) => `${SITE}/assets/og${slug === "en" ? "" : `-${slug}`}.jpg`;

// French puts a non-breaking space before these marks, so they never start a line.
const frenchSpacing = (text: string) =>
  text.replace(/ ([:;?!»])/g, " $1").replace(/« /g, "« ");

// The build fails on a missing string or a dash the site does not use, so a bad translation cannot ship.
export function dictOf(locale: Locale): Dict {
  const entries = Object.keys(en).map((key) => {
    const value = (locale.dict as Record<string, string>)[key];
    if (!value) throw new Error(`Missing "${key}" in ${locale.slug}`);
    if (/[\u2014\u2013\u2026]/.test(value)) throw new Error(`Em dash, en dash or ellipsis in ${locale.slug}.${key}`);
    return [key, locale.slug === "fr" ? frenchSpacing(value) : value];
  });
  return Object.fromEntries(entries) as Dict;
}
