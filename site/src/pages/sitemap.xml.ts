import { locales, urlOf } from "../i18n";

const lastmod = new Date().toISOString().slice(0, 10);
const alternates = [
  ...locales.map((l) => `<xhtml:link rel="alternate" hreflang="${l.lang}" href="${urlOf(l.slug)}"/>`),
  `<xhtml:link rel="alternate" hreflang="x-default" href="${urlOf("en")}"/>`,
].join("");

export function GET() {
  const urls = locales.map((l) => `<url><loc>${urlOf(l.slug)}</loc><lastmod>${lastmod}</lastmod>${alternates}</url>`).join("");
  const xml = `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">${urls}</urlset>`;
  return new Response(xml, { headers: { "Content-Type": "application/xml" } });
}
