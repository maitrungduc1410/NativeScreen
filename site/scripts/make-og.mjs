// Renders the 1200x630 social preview for every language into public/assets. Run with `npm run og` after changing
// a headline (`npm run og -- ko ar` renders only those). Needs macOS (sips) and Chrome; set CHROME to use another path.
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const assets = resolve(import.meta.dirname, "../public/assets");
const url = (name) => pathToFileURL(join(assets, name)).href;
const fonts = {
  ja: '"Hiragino Mincho ProN", "Yu Mincho", serif',
  "zh-hans": '"Songti SC", "SimSun", serif',
  "zh-hant": '"Songti TC", "PMingLiU", serif',
  ko: '"AppleMyungjo", "Batang", serif',
  ar: '"Geeza Pro", "Noto Naskh Arabic", serif',
};
const langs = { "zh-hans": "zh-Hans", "zh-hant": "zh-Hant", "pt-br": "pt-BR" };
const all = ["en", "vi", "zh-hans", "zh-hant", "ja", "ko", "de", "fr", "es", "it", "pt-br", "ru", "cs", "tr", "ar"];
const only = process.argv.slice(2);

const work = mkdtempSync(join(tmpdir(), "ns-og-"));
for (const slug of only.length ? only : all) {
  const { default: t } = await import(`../src/i18n/${slug}.ts`);
  const cjk = slug in fonts;
  // The picture stays on the right; only the text runs right to left.
  const rtl = slug === "ar" ? ' dir="rtl"' : "";
  const html = `<!doctype html><html lang="${langs[slug] ?? slug}"><head><meta charset="utf-8">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,400;1,6..72,400&family=Inter:wght@500;600&display=swap">
<style>
*{box-sizing:border-box;margin:0}html,body{width:1200px;height:630px;overflow:hidden;background:#f5f3ee;color:#171614}
.brand{position:absolute;left:56px;top:56px;display:flex;align-items:center;gap:14px;font:600 26px Inter,sans-serif}
.brand img{width:46px;height:46px}
h1{position:absolute;left:56px;top:150px;width:470px;font:400 82px/1.06 ${cjk ? fonts[slug] : "Newsreader,serif"};letter-spacing:${cjk ? "0" : "-.018em"}}
h1 span,h1 em{display:block;${cjk ? "white-space:nowrap" : "text-wrap:balance"}}h1 em{font-style:${cjk ? "normal" : "italic"}}
p{position:absolute;left:58px;bottom:58px;width:440px;font:500 25px/1.32 Inter,sans-serif;color:#4a4741}
.shot{position:absolute;left:556px;top:56px;width:980px;border-radius:14px;box-shadow:0 0 0 1px rgba(23,22,20,.16)}
</style></head><body>
<div class="brand"><img src="${url("icon.png")}" alt=""><span>Native Screen</span></div>
<h1${rtl}><span>${t.h1a}</span><em>${t.h1b}</em></h1>
<p${rtl}>${t.ogSub}</p>
<img class="shot" src="${url("shots/editor-dark.jpg")}" alt="">
<script>document.fonts.ready.then(()=>{const h=document.querySelector("h1"),p=document.querySelector("p");let s=82;
while(s>40&&(h.scrollWidth>470||h.offsetHeight>290)){s-=2;h.style.fontSize=s+"px"}
let q=25;while(q>18&&p.offsetHeight>100){q-=1;p.style.fontSize=q+"px"}})</script>
</body></html>`;
  const page = join(work, `${slug}.html`);
  const png = join(work, `${slug}.png`);
  writeFileSync(page, html);
  execFileSync(chrome, ["--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1", "--window-size=1200,630",
    "--virtual-time-budget=6000", "--allow-file-access-from-files", `--user-data-dir=${join(work, "chrome")}`, `--screenshot=${png}`, pathToFileURL(page).href], { stdio: "ignore" });
  const out = join(assets, slug === "en" ? "og.jpg" : `og-${slug}.jpg`);
  execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "86", png, "--out", out], { stdio: "ignore" });
  console.log(out);
}
rmSync(work, { recursive: true, force: true });
