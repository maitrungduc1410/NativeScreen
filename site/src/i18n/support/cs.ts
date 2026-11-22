export default {
  title: "Podpora · Native Screen",
  desc: "Pomoc s Native Screen pro macOS a Windows: kontakt, hlášení chyb a odpovědi na časté otázky.",
  back: "Zpět na úvod",
  h1: "Podpora",
  lede: "Potřebujete pomoc s Native Screen, našli jste chybu nebo máte nápad? Ozvěte se. Každou zprávu čtou lidé, kteří aplikaci vyvíjejí.",

  contactH: "Kontakt",
  email: "E-mail",
  emailNote: "Pro dotazy, problémy a vše, co má zůstat soukromé.",
  issues: "GitHub Issues",
  issuesNote: "Pro hlášení chyb a návrhy funkcí. Ostatní je mohou sledovat a doplňovat.",
  tipsP: "Abychom problém vyřešili rychleji, uveďte prosím:",
  tips: [
    "verzi Native Screen (v okně O aplikaci Native Screen) a odkud jste ji nainstalovali (Mac App Store, Microsoft Store nebo tento web);",
    "verzi macOS nebo Windows a model počítače;",
    "co jste udělali, co jste čekali a co se stalo, pokud možno se snímkem obrazovky nebo krátkým záznamem.",
  ],

  faqH: "Časté otázky",
  faq: [
    ["Záznam je černý nebo aplikace nevidí obrazovku.", "Native Screen potřebuje povolení k nahrávání obrazovky. V macOS otevřete Nastavení systému &gt; Soukromí a zabezpečení &gt; Záznam obrazovky a systémového zvuku (v macOS 14 Záznam obrazovky), zapněte Native Screen a pak aplikaci ukončete a znovu otevřete. Ve Windows žádné povolení potřeba není. Pokud je některé okno stále černé, jeho aplikace možná blokuje snímání obrazovky."],
    ["Nefunguje kamera nebo mikrofon.", "V macOS povolte Native Screen v Nastavení systému &gt; Soukromí a zabezpečení &gt; Kamera nebo Mikrofon. Ve Windows zkontrolujte Nastavení &gt; Ochrana osobních údajů a zabezpečení &gt; Fotoaparát nebo Mikrofon. Pak před začátkem vyberte zařízení v liště nahrávání."],
    ["Kam se ukládají moje záznamy?", "Každý záznam se uloží jako projekt do složky projektů. V nastavení uvidíte, kde je, a můžete ji změnit. Verze z Mac App Store vás při prvním nahrávání požádá o výběr této složky. Exportovaná videa a obrázky se uloží do složky, kterou zvolíte při exportu."],
    ["Jak aplikaci aktualizuji?", "Mac App Store a Microsoft Store ji aktualizují za vás. Pokud jste ji stáhli z tohoto webu, aplikace sama hledá aktualizace a v macOS můžete také zvolit Native Screen &gt; Check for Updates."],
    ["Co aplikace potřebuje?", "macOS 14 nebo novější na Apple silicon nebo Intel, případně Windows 10 nebo 11 (x64)."],
    ["Je opravdu zdarma?", "Ano. Native Screen je zdarma a open source pod licencí MIT. Žádný účet, žádné předplatné, žádný vodoznak."],
    ["Jak ji odinstaluji?", "V macOS přetáhněte Native Screen ze složky Aplikace do Koše. Ve Windows otevřete Nastavení &gt; Aplikace a odinstalujte ji. Projekty a exporty zůstanou v počítači, dokud je nesmažete."],
  ],

  moreH: "Další informace",
  moreP: "V <a href=\"{privacy}\">Zásadách ochrany soukromí</a> se dočtete, jak se s vašimi daty zachází (nikdy neopustí váš počítač). Zdrojový kód a poznámky k vydáním najdete na <a href=\"{repo}\">GitHubu</a>.",

  footerLink: "Podpora",
};
