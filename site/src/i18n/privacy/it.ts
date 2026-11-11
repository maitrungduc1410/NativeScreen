export default {
  title: "Informativa sulla privacy · Native Screen",
  desc: "Cosa fa Native Screen con le tue registrazioni e i tuoi dati: tutto resta sul tuo computer, senza account, senza statistiche e senza upload.",
  back: "Torna alla home",
  updated: "Ultimo aggiornamento: {date}",
  h1: "Informativa sulla privacy",
  note: "Questa traduzione è fornita solo a scopo informativo. In caso di differenze con la <a href=\"/privacy/\">versione inglese</a>, prevale la versione inglese.",
  lede: "Native Screen registra e monta sul tuo computer. Non ci sono account, server nostri, statistiche né pubblicità. L'app non carica mai le tue registrazioni.",
  scope: "Questa informativa riguarda le app Native Screen per macOS e Windows (compresa la versione del Microsoft Store) e questo sito web. L'app è gratuita e open source, quindi tutto ciò che segue si può verificare nel <a href=\"{repo}\">codice sorgente</a>.",

  stayH: "Cosa resta sul tuo computer",
  stayP: "Tutto ciò che crei con Native Screen viene salvato sul tuo computer e l'app non lo invia mai da nessuna parte:",
  stayList: [
    "registrazioni di schermo, finestra e area, video della fotocamera, audio del microfono e del sistema;",
    "le posizioni del mouse, i clic e i tasti premuti registrati con ogni ripresa, usati per gli zoom automatici, il cursore fluido e la visualizzazione delle scorciatoie da tastiera, e il nome della finestra o dell'app registrata;",
    "i disegni fatti sullo schermo durante la registrazione, le note del relatore e i profili di registrazione;",
    "progetti, modifiche, preset, sottotitoli e trascrizioni;",
    "video, GIF, immagini e file di sottotitoli esportati;",
    "le tue impostazioni.",
  ],
  onDevice: "Sottotitoli, trascrizioni, rilevamento dei dati sensibili (email, chiavi, volti), tracciamento del viso e rimozione dello sfondo della fotocamera funzionano tutti sul tuo computer. Su macOS usano i framework integrati di Apple, e il riconoscimento vocale è impostato per funzionare solo sul dispositivo, quindi nessun audio viene inviato ad Apple. Su Windows, i sottotitoli usano un modello Whisper e la rimozione dello sfondo un modello MODNet. Ciascuno viene scaricato una volta e poi funziona in locale.",
  keys: "I tasti premuti vengono registrati solo mentre è in corso una registrazione. Sono salvati in quel progetto e in nessun altro posto, e puoi eliminarli eliminando il progetto.",

  permH: "Autorizzazioni richieste dall'app",
  permP: "Ogni autorizzazione è usata solo per la funzione indicata accanto.",
  permCols: ["Autorizzazione", "Perché"],
  perms: [
    ["Registrazione dello schermo", "Per registrare uno schermo, una finestra o un'area che scegli."],
    ["Microfono", "Per registrare la tua voce e le voci fuori campo, quando attivi il microfono."],
    ["Fotocamera", "Per registrare la fotocamera, quando la attivi."],
    ["Accessibilità (macOS)", "Per elencare e selezionare le finestre, e per seguire clic e tasti durante una registrazione."],
    ["Riconoscimento vocale (macOS)", "Per creare sottotitoli con il riconoscimento di Apple sul dispositivo."],
    ["Input da tastiera e mouse (Windows)", "Solo durante una registrazione: i clic guidano gli zoom automatici e gli effetti dei clic, i tasti diventano la visualizzazione delle scorciatoie."],
    ["Attendibilità completa (Windows)", "Native Screen è un'app desktop. Ha bisogno di accesso completo per usare la cattura dello schermo, la cattura dell'audio di sistema, la codifica video hardware e la GPU di Windows, che le app pacchettizzate non possono raggiungere in altro modo."],
    ["Internet", "Solo per i download e i controlli degli aggiornamenti elencati qui sotto."],
  ],

  leaveH: "Cosa lascia il tuo computer",
  leaveP: "L'app si collega a internet solo in questi casi. Nessuno di essi include le tue registrazioni, i tuoi progetti o ciò che hai digitato.",
  leaveCols: ["Quando", "Dove", "Cosa viene inviato"],
  leave: [
    ["La prima volta che usi i sottotitoli o la rimozione dello sfondo della fotocamera su Windows", "Hugging Face (huggingface.co)", "Una richiesta di download del file del modello. Hugging Face vede il tuo indirizzo IP, come per qualsiasi download. L'app per macOS non scarica alcun modello."],
    ["Controllo e download degli aggiornamenti (macOS, e Windows al di fuori del Microsoft Store)", "GitHub", "Una richiesta dell'ultima versione e, se presente, del file di aggiornamento. GitHub vede il tuo indirizzo IP e le normali intestazioni della richiesta. Non è incluso nulla su di te o sulle tue registrazioni. Puoi disattivare il controllo automatico nelle Impostazioni."],
    ["Versione del Microsoft Store", "Microsoft", "Lo Store installa e aggiorna l'app, che non ha un sistema di aggiornamento proprio. Microsoft può raccogliere dati di diagnostica secondo la propria <a href=\"https://privacy.microsoft.com/privacystatement\">informativa sulla privacy</a>."],
  ],

  agentsH: "Agenti IA",
  agentsP: "Se attivi <strong>Impostazioni &gt; Agenti IA</strong> (disattivato per impostazione predefinita), agenti IA come Claude, Codex o Cursor possono controllare Native Screen tramite una connessione locale che solo i programmi in esecuzione con il tuo account utente su questo computer possono aprire. Un agente può fare ciò che fai tu nell'app: avviare una registrazione (la barra di registrazione e il suo conto alla rovescia sono sempre visibili), aprire e modificare progetti, leggere i dati e i fotogrammi dei progetti, esportare video e immagini su file e passare all'app un file video o immagine dal tuo computer da importare. Per questo l'app non invia nulla su internet, ma l'agente può inviare ciò che legge al proprio fornitore di IA secondo i termini di quel fornitore. Disattiva l'impostazione per bloccare ogni accesso degli agenti.",

  notH: "Cosa non facciamo",
  notList: [
    "Nessun account e nessun accesso.",
    "Nessuna statistica, tracciamento dell'uso o pubblicità.",
    "Nessun rapporto sugli arresti anomali inviato dall'app.",
    "Nessuna vendita o condivisione di dati personali. Non ne abbiamo da condividere.",
  ],

  webH: "Questo sito web",
  webP: "nativescreen.app è un sito statico ospitato su GitHub Pages. Non ha statistiche e non imposta cookie. I caratteri vengono caricati da Google Fonts, quindi GitHub e Google ricevono il tuo indirizzo IP e i dati del browser per servire la pagina. Le tue scelte di tema e lingua sono conservate nella memoria locale del browser e non lasciano mai il tuo dispositivo.",

  kidsH: "Minori",
  kidsP: "Native Screen non raccoglie informazioni personali da nessuno, compresi i minori di 13 anni.",

  choiceH: "Le tue scelte",
  choiceP: "I tuoi dati sono sul tuo computer, quindi li controlli tu. Elimina un progetto per rimuovere le sue registrazioni e i suoi dati di input. La disinstallazione rimuove l'app. Progetti, esportazioni e modelli scaricati restano sul tuo computer finché non li elimini.",

  changesH: "Modifiche",
  changesP: "Se questa informativa cambia, la nuova versione sarà pubblicata su questa pagina con una nuova data. La cronologia di ogni modifica è pubblica nel <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">repository</a>.",

  contactH: "Contatti",
  contactP: "Domande sulla privacy: scrivi a <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a> o apri una issue su <a href=\"{repo}/issues\">GitHub</a>.",
};
