export default {
  title: "Assistenza · Native Screen",
  desc: "Aiuto per Native Screen su macOS e Windows: contatti, segnalazione di bug e risposte alle domande frequenti.",
  back: "Torna alla home",
  h1: "Assistenza",
  lede: "Hai bisogno di aiuto con Native Screen, hai trovato un bug o hai un'idea? Scrivici. Ogni messaggio viene letto da chi sviluppa l'app.",

  contactH: "Contattaci",
  email: "Email",
  emailNote: "Per domande, problemi e tutto ciò che deve restare privato.",
  issues: "GitHub Issues",
  issuesNote: "Per segnalare bug e proporre funzioni. Anche altre persone possono seguirli e contribuire.",
  tipsP: "Per aiutarci a risolvere un problema più in fretta, indica:",
  tips: [
    "la versione di Native Screen (in Informazioni su Native Screen) e da dove l'hai installata (Mac App Store, Microsoft Store o questo sito);",
    "la tua versione di macOS o Windows e il modello del computer;",
    "cosa hai fatto, cosa ti aspettavi e cosa è successo, se possibile con uno screenshot o una breve registrazione.",
  ],

  faqH: "Domande frequenti",
  faq: [
    ["La registrazione è nera o l'app non vede lo schermo.", "Native Screen ha bisogno del permesso di registrare lo schermo. Su macOS apri Impostazioni di Sistema &gt; Privacy e sicurezza &gt; Registrazione schermo e audio di sistema (Registrazione schermo su macOS 14), attiva Native Screen, poi chiudi e riapri l'app. Su Windows non serve alcun permesso. Se una finestra resta nera, l'app che la mostra potrebbe bloccare la cattura dello schermo."],
    ["La fotocamera o il microfono non funzionano.", "Su macOS consenti Native Screen in Impostazioni di Sistema &gt; Privacy e sicurezza &gt; Fotocamera o Microfono. Su Windows controlla Impostazioni &gt; Privacy e sicurezza &gt; Fotocamera o Microfono. Poi scegli il dispositivo nella barra di registrazione prima di iniziare."],
    ["Dove vengono salvate le registrazioni?", "Ogni registrazione viene salvata come progetto nella cartella dei progetti. Nelle impostazioni puoi vedere dove si trova e cambiarla. Nella versione Mac App Store la posizione predefinita è Filmati &gt; Native Screen Projects. Video e immagini esportati vanno nella cartella che scegli durante l'esportazione."],
    ["Come aggiorno l'app?", "Mac App Store e Microsoft Store la aggiornano per te. Se l'hai scaricata da questo sito, l'app controlla da sola gli aggiornamenti, e su macOS puoi anche scegliere Native Screen &gt; Check for Updates."],
    ["Di cosa ha bisogno l'app?", "macOS 14 o successivo su Apple silicon o Intel, oppure Windows 10 o 11 (x64)."],
    ["È davvero gratuita?", "Sì. Native Screen è gratuita e open source con licenza MIT. Nessun account, nessun abbonamento, nessuna filigrana."],
    ["Come la disinstallo?", "Su macOS trascina Native Screen da Applicazioni al Cestino. Su Windows apri Impostazioni &gt; App e disinstallala. Progetti ed esportazioni restano sul computer finché non li elimini."],
  ],

  moreH: "Altro",
  moreP: "Leggi l'<a href=\"{privacy}\">Informativa sulla privacy</a> per sapere come vengono trattati i tuoi dati (non lasciano mai il tuo computer). Codice sorgente e note di rilascio sono su <a href=\"{repo}\">GitHub</a>.",

  footerLink: "Assistenza",
};
