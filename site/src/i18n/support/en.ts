// The support page. `{email}`, `{repo}` and `{privacy}` are filled in by the page. Strings may hold simple HTML.
export default {
  title: "Support · Native Screen",
  desc: "Get help with Native Screen for macOS and Windows: contact, bug reports and answers to common questions.",
  back: "Back to home",
  h1: "Support",
  lede: "Need help with Native Screen, found a bug or have an idea? Get in touch. Every message is read by the people who make the app.",

  contactH: "Contact us",
  email: "Email",
  emailNote: "For questions, problems and anything private.",
  issues: "GitHub Issues",
  issuesNote: "For bug reports and feature requests. Others can follow and add to them.",
  tipsP: "To help us fix a problem faster, please include:",
  tips: [
    "the Native Screen version (shown in About Native Screen) and where you installed it from (Mac App Store, Microsoft Store or the website);",
    "your macOS or Windows version and your computer model;",
    "what you did, what you expected and what happened, with a screenshot or a short recording if you can.",
  ],

  faqH: "Common questions",
  faq: [
    ["My recording is black, or the app can't see my screen.", "Native Screen needs permission to record the screen. On macOS, open System Settings &gt; Privacy &amp; Security &gt; Screen &amp; System Audio Recording (Screen Recording on macOS 14), turn Native Screen on, then quit and reopen the app. On Windows no permission is needed. If a window still records black, the app showing it may block screen capture."],
    ["My camera or microphone doesn't work.", "On macOS, allow Native Screen in System Settings &gt; Privacy &amp; Security &gt; Camera or Microphone. On Windows, check Settings &gt; Privacy &amp; security &gt; Camera or Microphone. Then pick the device in the recording bar before you start."],
    ["Where are my recordings saved?", "Each recording is saved as a project in your projects folder. Settings shows where it is and lets you change it. In the Mac App Store version the default is Movies &gt; Native Screen Projects. Exported videos and images go to the folder you choose when you export."],
    ["How do I update the app?", "The Mac App Store and Microsoft Store update the app for you. If you downloaded it from this website, the app checks for updates itself, and on macOS you can also choose Native Screen &gt; Check for Updates."],
    ["What does the app need to run?", "macOS 14 or later on Apple silicon or Intel, or Windows 10 or 11 (x64)."],
    ["Is it really free?", "Yes. Native Screen is free and open source under the MIT License. There is no account, no subscription and no watermark."],
    ["How do I uninstall it?", "On macOS, drag Native Screen from Applications to the Trash. On Windows, open Settings &gt; Apps and uninstall it. Your projects and exports stay on your computer until you delete them."],
  ],

  moreH: "More",
  moreP: "Read the <a href=\"{privacy}\">Privacy Policy</a> to see how your data is handled (it never leaves your computer). The source code and release notes are on <a href=\"{repo}\">GitHub</a>.",

  footerLink: "Support",
};
