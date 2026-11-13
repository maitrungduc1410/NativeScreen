// The privacy policy. English is the binding text; every translation follows it sentence by sentence.
// `{repo}` becomes the repository URL. Strings may hold simple HTML (links, <strong>).
export default {
  title: "Privacy Policy · Native Screen",
  desc: "What Native Screen does with your recordings and data: everything stays on your computer, with no account, no analytics and no uploads.",
  back: "Back to home",
  updated: "Last updated {date}",
  h1: "Privacy Policy",
  note: "",
  lede: "Native Screen records and edits on your computer. There is no account, no server of ours, no analytics and no ads. The app never uploads your recordings.",
  scope: "This policy covers the Native Screen apps for macOS and Windows (including the Microsoft Store and Mac App Store versions) and this website. The app is free and open source, so everything below can be checked in the <a href=\"{repo}\">source code</a>.",

  stayH: "What stays on your computer",
  stayP: "Everything you make with Native Screen is stored on your computer and is never sent anywhere by the app:",
  stayList: [
    "screen, window and area recordings, camera video, microphone and system audio;",
    "the mouse positions, clicks and key presses recorded with a take, used for automatic zooms, the smooth cursor and keyboard shortcut overlays, and the name of the window or app you recorded;",
    "drawings made on the screen while recording, speaker notes and recording profiles;",
    "projects, edits, presets, captions and transcripts;",
    "exported videos, GIFs, images and caption files;",
    "your settings.",
  ],
  onDevice: "Captions, transcripts, sensitive data detection (emails, keys, faces), face tracking and camera background removal all run on your computer. On macOS they use Apple's built-in frameworks, and speech recognition is set to run on the device only, so no audio is sent to Apple. On Windows, captions use a Whisper model and background removal uses a MODNet model. Each is downloaded once and then runs locally.",
  keys: "Key presses are only recorded while a recording is running. They are saved inside that project and nowhere else, and you can delete them by deleting the project.",

  permH: "Permissions the app asks for",
  permP: "Each permission is used only for the feature named next to it.",
  permCols: ["Permission", "Why"],
  perms: [
    ["Screen recording", "To record a display, a window or an area you choose."],
    ["Microphone", "To record your voice and voiceovers, when you turn the microphone on."],
    ["Camera", "To record your camera, when you turn it on."],
    ["Accessibility (macOS, direct download)", "To list and select windows, and to follow clicks and key presses during a recording."],
    ["Input Monitoring (Mac App Store version)", "During a recording only: key presses become shortcut overlays. This version asks for it instead of Accessibility."],
    ["Speech recognition (macOS)", "To create captions with Apple's on-device recognizer."],
    ["Keyboard and mouse input (Windows)", "During a recording only: clicks drive automatic zooms and click effects, key presses become shortcut overlays."],
    ["Full trust (Windows)", "Native Screen is a desktop app. It needs full access to use Windows screen capture, system audio capture, hardware video encoding and the GPU, which packaged apps cannot reach otherwise."],
    ["Internet", "Only for the downloads and update checks listed below."],
  ],

  leaveH: "What leaves your computer",
  leaveP: "The app connects to the internet only in these cases. None of them include your recordings, your projects or anything you typed.",
  leaveCols: ["When", "Where", "What is sent"],
  leave: [
    ["The first time you use captions or camera background removal on Windows", "Hugging Face (huggingface.co)", "A request to download the model file. Hugging Face sees your IP address, as with any download. The macOS app downloads no models."],
    ["Checking for and downloading updates (macOS outside the Mac App Store, and Windows outside the Microsoft Store)", "GitHub", "A request for the latest release and, when there is one, the update file. GitHub sees your IP address and standard request headers. Nothing about you or your recordings is included. You can turn automatic checks off in Settings."],
    ["Microsoft Store version", "Microsoft", "The Store installs and updates the app, which has no updater of its own. Microsoft may collect diagnostic data under its own <a href=\"https://privacy.microsoft.com/privacystatement\">privacy statement</a>."],
    ["Mac App Store version", "Apple", "The App Store installs and updates the app, which has no updater of its own and makes no internet connections. Apple may collect diagnostic data under its own <a href=\"https://www.apple.com/legal/privacy/\">privacy policy</a>."],
  ],

  agentsH: "AI agents",
  agentsP: "If you turn on <strong>Settings &gt; AI Agents</strong> (off by default), AI agents such as Claude, Codex or Cursor can control Native Screen through a local connection that only programs running under your user account on this computer can open. An agent can do what you can do in the app: start a recording (the recording bar and its countdown are always shown), open and edit projects, read project details and frames, export videos and images to files, and give the app a video or image file from your computer to import. The app sends nothing over the internet for this, but the agent may send what it reads to its AI provider under that provider's terms. Turn the setting off to stop all agent access. The Mac App Store version does not include this feature.",

  notH: "What we do not do",
  notList: [
    "No account or sign in.",
    "No analytics, usage tracking or advertising.",
    "No crash reports sent by the app.",
    "No selling or sharing of personal data. We don't have any to share.",
  ],

  webH: "This website",
  webP: "nativescreen.app is a static site hosted on GitHub Pages. It has no analytics and sets no cookies. Fonts are loaded from Google Fonts, so GitHub and Google receive your IP address and browser details as part of serving the page. Your theme and language choices are kept in your browser's local storage and never leave your device.",

  kidsH: "Children",
  kidsP: "Native Screen collects no personal information from anyone, including children under 13.",

  choiceH: "Your choices",
  choiceP: "Your data is on your computer, so you control it. Delete a project to remove its recordings and input data. Uninstalling removes the app. Projects, exports and downloaded models stay on your computer until you delete them.",

  changesH: "Changes",
  changesP: "If this policy changes, the new version will be published on this page with a new date. The history of every change is public in the <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">repository</a>.",

  contactH: "Contact",
  contactP: "Questions about privacy: email <a href=\"mailto:hello@nativescreen.app\">hello@nativescreen.app</a> or open an issue on <a href=\"{repo}/issues\">GitHub</a>.",
};
