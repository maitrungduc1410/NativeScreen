export default {
  title: "Datenschutzerklärung · Native Screen",
  desc: "Was Native Screen mit deinen Aufnahmen und Daten macht: Alles bleibt auf deinem Computer, ohne Konto, ohne Analyse und ohne Uploads.",
  back: "Zur Startseite",
  updated: "Zuletzt aktualisiert: {date}",
  h1: "Datenschutzerklärung",
  note: "Diese Übersetzung dient nur der Information. Weicht sie von der <a href=\"/privacy/\">englischen Fassung</a> ab, gilt die englische Fassung.",
  lede: "Native Screen nimmt auf deinem Computer auf und bearbeitet dort. Es gibt kein Konto, keinen Server von uns, keine Analyse und keine Werbung. Die App lädt deine Aufnahmen niemals hoch.",
  scope: "Diese Erklärung gilt für die Native-Screen-Apps für macOS und Windows (einschließlich der Version aus dem Microsoft Store) und für diese Website. Die App ist kostenlos und Open Source, daher lässt sich alles Folgende im <a href=\"{repo}\">Quellcode</a> überprüfen.",

  stayH: "Was auf deinem Computer bleibt",
  stayP: "Alles, was du mit Native Screen erstellst, wird auf deinem Computer gespeichert und von der App nirgendwohin gesendet:",
  stayList: [
    "Aufnahmen von Bildschirm, Fenster und Bereich, Kameravideo, Mikrofon- und Systemton;",
    "die mit einer Aufnahme erfassten Mauspositionen, Klicks und Tastendrücke, die für automatische Zooms, den geglätteten Cursor und die Anzeige von Tastenkürzeln genutzt werden, sowie der Name des aufgenommenen Fensters oder der App;",
    "Zeichnungen, die während der Aufnahme auf dem Bildschirm entstehen, Sprechernotizen und Aufnahmeprofile;",
    "Projekte, Bearbeitungen, Voreinstellungen, Untertitel und Transkripte;",
    "exportierte Videos, GIFs, Bilder und Untertiteldateien;",
    "deine Einstellungen.",
  ],
  onDevice: "Untertitel, Transkripte, die Erkennung sensibler Daten (E-Mail-Adressen, Schlüssel, Gesichter), Gesichtsverfolgung und das Entfernen des Kamerahintergrunds laufen alle auf deinem Computer. Unter macOS nutzen sie die integrierten Frameworks von Apple, und die Spracherkennung ist so eingestellt, dass sie nur auf dem Gerät läuft. Es wird also kein Ton an Apple gesendet. Unter Windows nutzen Untertitel ein Whisper-Modell und das Entfernen des Hintergrunds ein MODNet-Modell. Jedes wird einmal heruntergeladen und läuft danach lokal.",
  keys: "Tastendrücke werden nur während einer laufenden Aufnahme erfasst. Sie werden nur in diesem Projekt gespeichert und nirgendwo sonst, und du kannst sie löschen, indem du das Projekt löschst.",

  permH: "Berechtigungen, die die App anfragt",
  permP: "Jede Berechtigung wird nur für die daneben genannte Funktion verwendet.",
  permCols: ["Berechtigung", "Wofür"],
  perms: [
    ["Bildschirmaufnahme", "Um einen Bildschirm, ein Fenster oder einen von dir gewählten Bereich aufzunehmen."],
    ["Mikrofon", "Um deine Stimme und Voiceovers aufzunehmen, wenn du das Mikrofon einschaltest."],
    ["Kamera", "Um deine Kamera aufzunehmen, wenn du sie einschaltest."],
    ["Bedienungshilfen (macOS)", "Um Fenster aufzulisten und auszuwählen und um während einer Aufnahme Klicks und Tastendrücke zu verfolgen."],
    ["Spracherkennung (macOS)", "Um Untertitel mit der Spracherkennung von Apple auf dem Gerät zu erstellen."],
    ["Tastatur- und Mauseingabe (Windows)", "Nur während einer Aufnahme: Klicks steuern automatische Zooms und Klickeffekte, Tastendrücke werden als Tastenkürzel angezeigt."],
    ["Volle Vertrauensstellung (Windows)", "Native Screen ist eine Desktop-App. Sie braucht vollen Zugriff, um die Bildschirmaufnahme, die Aufnahme des Systemtons, die Hardware-Videokodierung und die GPU von Windows zu nutzen, die paketierte Apps sonst nicht erreichen."],
    ["Internet", "Nur für die unten aufgeführten Downloads und Update-Prüfungen."],
  ],

  leaveH: "Was deinen Computer verlässt",
  leaveP: "Die App verbindet sich nur in diesen Fällen mit dem Internet. Keiner davon enthält deine Aufnahmen, deine Projekte oder etwas, das du getippt hast.",
  leaveCols: ["Wann", "Wohin", "Was gesendet wird"],
  leave: [
    ["Wenn du unter Windows zum ersten Mal Untertitel oder das Entfernen des Kamerahintergrunds nutzt", "Hugging Face (huggingface.co)", "Eine Anfrage zum Herunterladen der Modelldatei. Hugging Face sieht deine IP-Adresse, wie bei jedem Download. Die macOS-App lädt keine Modelle herunter."],
    ["Nach Updates suchen und sie herunterladen (macOS und Windows außerhalb des Microsoft Store)", "GitHub", "Eine Anfrage nach der neuesten Version und, falls es eine gibt, der Update-Datei. GitHub sieht deine IP-Adresse und die üblichen Anfrage-Header. Nichts über dich oder deine Aufnahmen ist enthalten. Die automatische Prüfung lässt sich in den Einstellungen ausschalten."],
    ["Version aus dem Microsoft Store", "Microsoft", "Der Store installiert und aktualisiert die App, die keinen eigenen Updater hat. Microsoft kann nach seiner eigenen <a href=\"https://privacy.microsoft.com/privacystatement\">Datenschutzerklärung</a> Diagnosedaten erheben."],
  ],

  agentsH: "KI-Agenten",
  agentsP: "Wenn du <strong>Einstellungen &gt; KI-Agenten</strong> einschaltest (standardmäßig aus), können KI-Agenten wie Claude, Codex oder Cursor Native Screen über eine lokale Verbindung steuern, die nur Programme öffnen können, die auf diesem Computer unter deinem Benutzerkonto laufen. Ein Agent kann tun, was du in der App tun kannst: eine Aufnahme starten (die Aufnahmeleiste und ihr Countdown werden immer angezeigt), Projekte öffnen und bearbeiten, Projektdaten und Einzelbilder lesen, Videos und Bilder als Dateien exportieren und der App eine Video- oder Bilddatei von deinem Computer zum Importieren übergeben. Die App sendet dafür nichts über das Internet, aber der Agent kann, was er liest, nach den Bedingungen seines KI-Anbieters an diesen senden. Schalte die Einstellung aus, um jeden Zugriff durch Agenten zu beenden.",

  notH: "Was wir nicht tun",
  notList: [
    "Kein Konto und keine Anmeldung.",
    "Keine Analyse, keine Nutzungsverfolgung und keine Werbung.",
    "Die App sendet keine Absturzberichte.",
    "Kein Verkauf und keine Weitergabe personenbezogener Daten. Wir haben keine, die wir weitergeben könnten.",
  ],

  webH: "Diese Website",
  webP: "nativescreen.app ist eine statische Website, die auf GitHub Pages gehostet wird. Sie nutzt keine Analyse und setzt keine Cookies. Schriften werden von Google Fonts geladen, daher erhalten GitHub und Google beim Ausliefern der Seite deine IP-Adresse und Angaben zu deinem Browser. Deine Wahl von Erscheinungsbild und Sprache wird im lokalen Speicher deines Browsers abgelegt und verlässt dein Gerät nie.",

  kidsH: "Kinder",
  kidsP: "Native Screen erhebt von niemandem personenbezogene Daten, auch nicht von Kindern unter 13 Jahren.",

  choiceH: "Deine Möglichkeiten",
  choiceP: "Deine Daten liegen auf deinem Computer, also behältst du die Kontrolle. Lösche ein Projekt, um seine Aufnahmen und Eingabedaten zu entfernen. Beim Deinstallieren wird die App entfernt. Projekte, Exporte und heruntergeladene Modelle bleiben auf deinem Computer, bis du sie löschst.",

  changesH: "Änderungen",
  changesP: "Ändert sich diese Erklärung, wird die neue Fassung mit neuem Datum auf dieser Seite veröffentlicht. Der Verlauf aller Änderungen ist im <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">Repository</a> öffentlich.",

  contactH: "Kontakt",
  contactP: "Fragen zum Datenschutz: schreib eine E-Mail an <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a> oder eröffne ein Issue auf <a href=\"{repo}/issues\">GitHub</a>.",
};
