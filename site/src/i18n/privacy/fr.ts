export default {
  title: "Politique de confidentialité · Native Screen",
  desc: "Ce que Native Screen fait de vos enregistrements et de vos données : tout reste sur votre ordinateur, sans compte, sans statistiques et sans envoi.",
  back: "Retour à l’accueil",
  updated: "Dernière mise à jour : {date}",
  h1: "Politique de confidentialité",
  note: "Cette traduction est fournie à titre indicatif. En cas de différence avec la <a href=\"/privacy/\">version anglaise</a>, la version anglaise prévaut.",
  lede: "Native Screen enregistre et monte sur votre ordinateur. Il n’y a ni compte, ni serveur à nous, ni statistiques, ni publicité. L’app n’envoie jamais vos enregistrements.",
  scope: "Cette politique s’applique aux apps Native Screen pour macOS et Windows (y compris la version du Microsoft Store) et à ce site web. L’app est gratuite et open source : tout ce qui suit peut être vérifié dans le <a href=\"{repo}\">code source</a>.",

  stayH: "Ce qui reste sur votre ordinateur",
  stayP: "Tout ce que vous créez avec Native Screen est stocké sur votre ordinateur et n’est jamais envoyé nulle part par l’app :",
  stayList: [
    "les enregistrements d’écran, de fenêtre et de zone, la vidéo de la caméra, le son du micro et du système ;",
    "les positions de la souris, les clics et les touches enregistrés avec une prise, utilisés pour les zooms automatiques, le curseur fluide et l’affichage des raccourcis clavier, ainsi que le nom de la fenêtre ou de l’app enregistrée ;",
    "les dessins faits à l’écran pendant l’enregistrement, les notes de l’intervenant et les profils d’enregistrement ;",
    "les projets, modifications, préréglages, sous-titres et transcriptions ;",
    "les vidéos, GIF, images et fichiers de sous-titres exportés ;",
    "vos réglages.",
  ],
  onDevice: "Les sous-titres, les transcriptions, la détection des données sensibles (e-mails, clés, visages), le suivi du visage et la suppression de l’arrière-plan de la caméra fonctionnent tous sur votre ordinateur. Sur macOS, ils utilisent les frameworks intégrés d’Apple, et la reconnaissance vocale est réglée pour fonctionner uniquement sur l’appareil : aucun son n’est donc envoyé à Apple. Sur Windows, les sous-titres utilisent un modèle Whisper et la suppression de l’arrière-plan un modèle MODNet. Chacun est téléchargé une fois, puis fonctionne en local.",
  keys: "Les touches ne sont enregistrées que pendant un enregistrement. Elles sont sauvegardées dans ce projet et nulle part ailleurs, et vous pouvez les supprimer en supprimant le projet.",

  permH: "Autorisations demandées par l’app",
  permP: "Chaque autorisation sert uniquement à la fonction indiquée en regard.",
  permCols: ["Autorisation", "Pourquoi"],
  perms: [
    ["Enregistrement de l’écran", "Pour enregistrer un écran, une fenêtre ou une zone que vous choisissez."],
    ["Micro", "Pour enregistrer votre voix et vos voix off, quand vous activez le micro."],
    ["Caméra", "Pour enregistrer votre caméra, quand vous l’activez."],
    ["Accessibilité (macOS)", "Pour lister et sélectionner les fenêtres, et pour suivre les clics et les touches pendant un enregistrement."],
    ["Reconnaissance vocale (macOS)", "Pour créer des sous-titres avec la reconnaissance d’Apple sur l’appareil."],
    ["Saisie clavier et souris (Windows)", "Pendant un enregistrement uniquement : les clics déclenchent les zooms automatiques et les effets de clic, les touches deviennent l’affichage des raccourcis."],
    ["Confiance totale (Windows)", "Native Screen est une app de bureau. Elle a besoin d’un accès complet pour utiliser la capture d’écran, la capture du son système, l’encodage vidéo matériel et le GPU de Windows, que les apps empaquetées ne peuvent pas atteindre autrement."],
    ["Internet", "Uniquement pour les téléchargements et les vérifications de mises à jour décrits ci-dessous."],
  ],

  leaveH: "Ce qui quitte votre ordinateur",
  leaveP: "L’app ne se connecte à Internet que dans ces cas. Aucun d’eux n’inclut vos enregistrements, vos projets ni ce que vous avez tapé.",
  leaveCols: ["Quand", "Où", "Ce qui est envoyé"],
  leave: [
    ["La première fois que vous utilisez les sous-titres ou la suppression de l’arrière-plan de la caméra sur Windows", "Hugging Face (huggingface.co)", "Une requête de téléchargement du fichier du modèle. Hugging Face voit votre adresse IP, comme pour tout téléchargement. L’app macOS ne télécharge aucun modèle."],
    ["Recherche et téléchargement des mises à jour (macOS, et Windows hors Microsoft Store)", "GitHub", "Une requête pour la dernière version et, s’il y en a une, le fichier de mise à jour. GitHub voit votre adresse IP et les en-têtes de requête habituels. Rien sur vous ni sur vos enregistrements n’y figure. Vous pouvez désactiver la vérification automatique dans les Réglages."],
    ["Version du Microsoft Store", "Microsoft", "Le Store installe et met à jour l’app, qui n’a pas de système de mise à jour propre. Microsoft peut collecter des données de diagnostic selon sa propre <a href=\"https://privacy.microsoft.com/privacystatement\">déclaration de confidentialité</a>."],
  ],

  agentsH: "Agents IA",
  agentsP: "Si vous activez <strong>Réglages &gt; Agents IA</strong> (désactivé par défaut), des agents IA comme Claude, Codex ou Cursor peuvent piloter Native Screen par une connexion locale que seuls les programmes exécutés sous votre compte utilisateur sur cet ordinateur peuvent ouvrir. Un agent peut faire ce que vous faites dans l’app : lancer un enregistrement (la barre d’enregistrement et son compte à rebours sont toujours affichés), ouvrir et modifier des projets, lire les informations et les images des projets, exporter des vidéos et des images dans des fichiers, et donner à l’app un fichier vidéo ou image de votre ordinateur à importer. L’app n’envoie rien sur Internet pour cela, mais l’agent peut envoyer ce qu’il lit à son fournisseur d’IA selon les conditions de ce fournisseur. Désactivez le réglage pour couper tout accès des agents.",

  notH: "Ce que nous ne faisons pas",
  notList: [
    "Ni compte ni connexion.",
    "Ni statistiques, ni suivi d’utilisation, ni publicité.",
    "Aucun rapport de plantage envoyé par l’app.",
    "Ni vente ni partage de données personnelles. Nous n’en avons aucune à partager.",
  ],

  webH: "Ce site web",
  webP: "nativescreen.app est un site statique hébergé sur GitHub Pages. Il n’a pas de statistiques et ne dépose aucun cookie. Les polices sont chargées depuis Google Fonts : GitHub et Google reçoivent donc votre adresse IP et des informations sur votre navigateur pour servir la page. Vos choix de thème et de langue sont conservés dans le stockage local de votre navigateur et ne quittent jamais votre appareil.",

  kidsH: "Enfants",
  kidsP: "Native Screen ne collecte aucune information personnelle, auprès de personne, y compris les enfants de moins de 13 ans.",

  choiceH: "Vos choix",
  choiceP: "Vos données sont sur votre ordinateur, vous en gardez donc le contrôle. Supprimez un projet pour effacer ses enregistrements et ses données de saisie. La désinstallation supprime l’app. Les projets, exports et modèles téléchargés restent sur votre ordinateur jusqu’à ce que vous les supprimiez.",

  changesH: "Modifications",
  changesP: "Si cette politique change, la nouvelle version sera publiée sur cette page avec une nouvelle date. L’historique de chaque modification est public dans le <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">dépôt</a>.",

  contactH: "Contact",
  contactP: "Questions sur la confidentialité : écrivez à <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a> ou ouvrez une issue sur <a href=\"{repo}/issues\">GitHub</a>.",
};
