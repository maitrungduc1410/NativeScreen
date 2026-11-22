export default {
  title: "Assistance · Native Screen",
  desc: "Aide pour Native Screen sur macOS et Windows : contact, signalement de bugs et réponses aux questions fréquentes.",
  back: "Retour à l'accueil",
  h1: "Assistance",
  lede: "Besoin d'aide avec Native Screen, un bug ou une idée ? Écrivez-nous. Chaque message est lu par les personnes qui développent l'app.",

  contactH: "Nous contacter",
  email: "E-mail",
  emailNote: "Pour les questions, les problèmes et tout ce qui doit rester privé.",
  issues: "GitHub Issues",
  issuesNote: "Pour signaler un bug ou proposer une fonctionnalité. D'autres personnes peuvent suivre et compléter.",
  tipsP: "Pour nous aider à résoudre un problème plus vite, indiquez :",
  tips: [
    "la version de Native Screen (visible dans À propos de Native Screen) et sa provenance (Mac App Store, Microsoft Store ou ce site) ;",
    "votre version de macOS ou de Windows et le modèle de votre ordinateur ;",
    "ce que vous avez fait, ce que vous attendiez et ce qui s'est passé, avec une capture d'écran ou un court enregistrement si possible.",
  ],

  faqH: "Questions fréquentes",
  faq: [
    ["Mon enregistrement est noir, ou l'app ne voit pas mon écran.", "Native Screen a besoin de l'autorisation d'enregistrer l'écran. Sur macOS, ouvrez Réglages Système &gt; Confidentialité et sécurité &gt; Enregistrement de l'écran et de l'audio système (Enregistrement de l'écran sur macOS 14), activez Native Screen, puis quittez et rouvrez l'app. Sur Windows, aucune autorisation n'est nécessaire. Si une fenêtre reste noire, l'app concernée bloque peut-être la capture d'écran."],
    ["Ma caméra ou mon micro ne fonctionne pas.", "Sur macOS, autorisez Native Screen dans Réglages Système &gt; Confidentialité et sécurité &gt; Caméra ou Micro. Sur Windows, vérifiez Paramètres &gt; Confidentialité et sécurité &gt; Caméra ou Microphone. Choisissez ensuite l'appareil dans la barre d'enregistrement avant de commencer."],
    ["Où sont enregistrées mes vidéos ?", "Chaque enregistrement est sauvegardé comme un projet dans votre dossier de projets. Les réglages indiquent où il se trouve et permettent de le changer. La version Mac App Store vous demande de choisir ce dossier lors du premier enregistrement. Les vidéos et images exportées vont dans le dossier choisi lors de l'export."],
    ["Comment mettre l'app à jour ?", "Le Mac App Store et le Microsoft Store mettent l'app à jour pour vous. Si vous l'avez téléchargée sur ce site, l'app recherche elle-même les mises à jour, et sur macOS vous pouvez aussi choisir Native Screen &gt; Check for Updates."],
    ["De quoi l'app a-t-elle besoin ?", "macOS 14 ou ultérieur sur Apple silicon ou Intel, ou Windows 10 ou 11 (x64)."],
    ["Est-elle vraiment gratuite ?", "Oui. Native Screen est gratuite et open source sous licence MIT. Pas de compte, pas d'abonnement, pas de filigrane."],
    ["Comment la désinstaller ?", "Sur macOS, faites glisser Native Screen du dossier Applications vers la corbeille. Sur Windows, ouvrez Paramètres &gt; Applications et désinstallez-la. Vos projets et exports restent sur votre ordinateur jusqu'à ce que vous les supprimiez."],
  ],

  moreH: "En savoir plus",
  moreP: "Lisez la <a href=\"{privacy}\">politique de confidentialité</a> pour savoir comment vos données sont traitées (elles ne quittent jamais votre ordinateur). Le code source et les notes de version sont sur <a href=\"{repo}\">GitHub</a>.",

  footerLink: "Assistance",
};
