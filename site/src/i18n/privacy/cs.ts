export default {
  title: "Zásady ochrany soukromí · Native Screen",
  desc: "Co Native Screen dělá s vašimi záznamy a daty: vše zůstává na vašem počítači, bez účtu, bez analytiky a bez nahrávání na servery.",
  back: "Zpět na úvod",
  updated: "Naposledy aktualizováno: {date}",
  h1: "Zásady ochrany soukromí",
  note: "Tento překlad slouží jen pro informaci. Pokud se liší od <a href=\"/privacy/\">anglické verze</a>, platí anglická verze.",
  lede: "Native Screen nahrává a upravuje na vašem počítači. Nemá žádný účet, žádný náš server, žádnou analytiku ani reklamy. Aplikace vaše záznamy nikdy nenahrává na internet.",
  scope: "Tyto zásady se vztahují na aplikace Native Screen pro macOS a Windows (včetně verze z Microsoft Store) a na tento web. Aplikace je zdarma a s otevřeným kódem, takže vše níže lze ověřit ve <a href=\"{repo}\">zdrojovém kódu</a>.",

  stayH: "Co zůstává na vašem počítači",
  stayP: "Vše, co v Native Screen vytvoříte, se ukládá na vašem počítači a aplikace to nikam neposílá:",
  stayList: [
    "záznamy obrazovky, okna a oblasti, video z kamery, zvuk z mikrofonu a systému;",
    "polohy myši, kliknutí a stisky kláves zaznamenané se záběrem, používané pro automatická přiblížení, plynulý kurzor a zobrazení klávesových zkratek, a název nahraného okna nebo aplikace;",
    "kresby na obrazovce vytvořené během nahrávání, poznámky řečníka a profily nahrávání;",
    "projekty, úpravy, předvolby, titulky a přepisy;",
    "exportovaná videa, GIFy, obrázky a soubory titulků;",
    "vaše nastavení.",
  ],
  onDevice: "Titulky, přepisy, hledání citlivých údajů (e-maily, klíče, obličeje), sledování obličeje a odstranění pozadí kamery běží na vašem počítači. V macOS používají vestavěné frameworky Applu a rozpoznávání řeči je nastavené tak, aby běželo jen na zařízení, takže se do Applu neposílá žádný zvuk. Ve Windows používají titulky model Whisper a odstranění pozadí model MODNet. Každý se stáhne jednou a pak běží místně.",
  keys: "Stisky kláves se zaznamenávají jen během nahrávání. Ukládají se do daného projektu a nikam jinam a smažete je smazáním projektu.",

  permH: "Oprávnění, o která aplikace žádá",
  permP: "Každé oprávnění se používá jen pro funkci uvedenou vedle něj.",
  permCols: ["Oprávnění", "Proč"],
  perms: [
    ["Nahrávání obrazovky", "K nahrávání displeje, okna nebo oblasti, kterou si vyberete."],
    ["Mikrofon", "K nahrávání vašeho hlasu a komentářů, když mikrofon zapnete."],
    ["Kamera", "K nahrávání kamery, když ji zapnete."],
    ["Zpřístupnění (macOS)", "K zobrazení a výběru oken a ke sledování kliknutí a stisků kláves během nahrávání."],
    ["Rozpoznávání řeči (macOS)", "K vytváření titulků rozpoznáváním řeči od Applu na zařízení."],
    ["Vstup z klávesnice a myši (Windows)", "Jen během nahrávání: kliknutí řídí automatická přiblížení a efekty kliknutí, stisky kláves se zobrazují jako zkratky."],
    ["Plná důvěra (Windows)", "Native Screen je desktopová aplikace. Potřebuje plný přístup, aby mohla používat snímání obrazovky, snímání systémového zvuku, hardwarové kódování videa a GPU ve Windows, ke kterým se zabalené aplikace jinak nedostanou."],
    ["Internet", "Jen pro stahování a kontroly aktualizací uvedené níže."],
  ],

  leaveH: "Co opouští váš počítač",
  leaveP: "Aplikace se připojuje k internetu jen v těchto případech. Žádný z nich nezahrnuje vaše záznamy, projekty ani nic, co jste napsali.",
  leaveCols: ["Kdy", "Kam", "Co se posílá"],
  leave: [
    ["Při prvním použití titulků nebo odstranění pozadí kamery ve Windows", "Hugging Face (huggingface.co)", "Požadavek na stažení souboru modelu. Hugging Face vidí vaši IP adresu jako u každého stahování. Aplikace pro macOS žádné modely nestahuje."],
    ["Kontrola a stahování aktualizací (macOS a Windows mimo Microsoft Store)", "GitHub", "Požadavek na nejnovější verzi a, pokud existuje, soubor aktualizace. GitHub vidí vaši IP adresu a běžné hlavičky požadavku. Nic o vás ani o vašich záznamech se neposílá. Automatické kontroly můžete vypnout v Nastavení."],
    ["Verze z Microsoft Store", "Microsoft", "Store aplikaci instaluje a aktualizuje, aplikace nemá vlastní aktualizační mechanismus. Microsoft může shromažďovat diagnostická data podle svého <a href=\"https://privacy.microsoft.com/privacystatement\">prohlášení o zásadách ochrany osobních údajů</a>."],
  ],

  agentsH: "AI agenti",
  agentsP: "Pokud zapnete <strong>Nastavení &gt; AI agenti</strong> (ve výchozím stavu vypnuto), AI agenti jako Claude, Codex nebo Cursor mohou ovládat Native Screen přes místní spojení, které mohou otevřít jen programy běžící pod vaším uživatelským účtem na tomto počítači. Agent může dělat to, co vy v aplikaci: spustit nahrávání (panel nahrávání a jeho odpočet se vždy zobrazí), otevírat a upravovat projekty, číst údaje a snímky projektů, exportovat videa a obrázky do souborů a předat aplikaci k importu video nebo obrázek z vašeho počítače. Aplikace kvůli tomu nic neposílá na internet, ale agent může to, co přečte, poslat svému poskytovateli AI podle jeho podmínek. Vypnutím nastavení zastavíte veškerý přístup agentů.",

  notH: "Co neděláme",
  notList: [
    "Žádný účet ani přihlašování.",
    "Žádná analytika, sledování používání ani reklamy.",
    "Aplikace neposílá hlášení o pádech.",
    "Žádný prodej ani sdílení osobních údajů. Žádné, které bychom mohli sdílet, nemáme.",
  ],

  webH: "Tento web",
  webP: "nativescreen.app je statický web hostovaný na GitHub Pages. Nemá žádnou analytiku a neukládá cookies. Písma se načítají z Google Fonts, takže GitHub a Google při doručení stránky dostanou vaši IP adresu a údaje o prohlížeči. Volba motivu a jazyka se ukládá do místního úložiště prohlížeče a nikdy neopustí vaše zařízení.",

  kidsH: "Děti",
  kidsP: "Native Screen neshromažďuje osobní údaje od nikoho, včetně dětí mladších 13 let.",

  choiceH: "Vaše volby",
  choiceP: "Vaše data jsou na vašem počítači, takže je máte pod kontrolou. Smazáním projektu odstraníte jeho záznamy a vstupní data. Odinstalováním odstraníte aplikaci. Projekty, exporty a stažené modely zůstanou na počítači, dokud je nesmažete.",

  changesH: "Změny",
  changesP: "Pokud se tyto zásady změní, nová verze bude zveřejněna na této stránce s novým datem. Historie všech změn je veřejná v <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">repozitáři</a>.",

  contactH: "Kontakt",
  contactP: "Dotazy k ochraně soukromí: napište na <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a> nebo založte issue na <a href=\"{repo}/issues\">GitHubu</a>.",
};
