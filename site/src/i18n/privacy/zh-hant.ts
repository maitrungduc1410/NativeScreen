export default {
  title: "隱私權政策 · Native Screen",
  desc: "Native Screen 如何處理你的錄影內容和資料：一切都留在你的電腦上，不需帳號，沒有分析統計，不會上傳。",
  back: "回到首頁",
  updated: "最後更新：{date}",
  h1: "隱私權政策",
  note: "本譯文僅供參考。如與<a href=\"/privacy/\">英文版本</a>有出入，以英文版本為準。",
  lede: "Native Screen 在你的電腦上錄影和編輯。沒有帳號，沒有我們的伺服器，沒有分析統計，也沒有廣告。App 從不上傳你的錄影內容。",
  scope: "本政策適用於 macOS 和 Windows 版的 Native Screen App（包括 Microsoft Store 版本）以及本網站。此 App 免費且開源，因此以下所有內容都可以在<a href=\"{repo}\">原始碼</a>中查證。",

  stayH: "留在你電腦上的內容",
  stayP: "你用 Native Screen 製作的一切都儲存在你的電腦上，App 絕不會將其傳送到任何地方：",
  stayList: [
    "螢幕、視窗和區域錄影，相機影片，麥克風和系統音訊；",
    "隨每次錄影記錄的滑鼠位置、點按和按鍵（用於自動縮放、平滑游標和快速鍵顯示），以及你錄製的視窗或 App 名稱；",
    "錄影時在螢幕上繪製的內容、講者備忘稿和錄製設定檔；",
    "專案、編輯、預設組、字幕和逐字稿；",
    "輸出的影片、GIF、影像和字幕檔案；",
    "你的設定。",
  ],
  onDevice: "字幕、逐字稿、敏感資料偵測（電子郵件、金鑰、人臉）、臉部追蹤和相機背景移除都在你的電腦上執行。在 macOS 上，這些功能使用 Apple 的內建框架，且語音辨識設定為僅在裝置上執行，因此不會傳送任何音訊給 Apple。在 Windows 上，字幕使用 Whisper 模型，背景移除使用 MODNet 模型。每個模型只下載一次，之後在本機執行。",
  keys: "只有在錄影進行中才會記錄按鍵。按鍵只儲存在該專案中，不會存放在其他地方；刪除專案即可刪除這些按鍵。",

  permH: "App 要求的權限",
  permP: "每項權限只用於旁邊列出的功能。",
  permCols: ["權限", "原因"],
  perms: [
    ["螢幕錄影", "錄製你選擇的顯示器、視窗或區域。"],
    ["麥克風", "在你開啟麥克風時，錄製你的聲音和旁白。"],
    ["相機", "在你開啟相機時，錄製相機畫面。"],
    ["輔助使用（macOS）", "列出並選擇視窗，以及在錄影期間追蹤點按和按鍵。"],
    ["語音辨識（macOS）", "使用 Apple 的裝置端辨識器產生字幕。"],
    ["鍵盤和滑鼠輸入（Windows）", "僅在錄影期間：點按用於自動縮放和點按效果，按鍵顯示為快速鍵。"],
    ["完全信任（Windows）", "Native Screen 是桌面 App。它需要完整存取權限才能使用 Windows 螢幕擷取、系統音訊擷取、硬體影片編碼和 GPU，封裝的 App 無法以其他方式使用這些功能。"],
    ["網際網路", "僅用於下方列出的下載和更新檢查。"],
  ],

  leaveH: "離開你電腦的內容",
  leaveP: "App 只在以下情況連線網際網路。這些情況都不包含你的錄影內容、專案或你輸入的任何內容。",
  leaveCols: ["時機", "目的地", "傳送的內容"],
  leave: [
    ["在 Windows 上首次使用字幕或相機背景移除時", "Hugging Face（huggingface.co）", "一個下載模型檔案的要求。與任何下載一樣，Hugging Face 能看到你的 IP 位址。macOS App 不下載任何模型。"],
    ["檢查和下載更新（macOS，以及 Microsoft Store 以外的 Windows 版本）", "GitHub", "一個取得最新版本資訊的要求，有新版本時還會下載更新檔案。GitHub 能看到你的 IP 位址和標準的要求標頭。其中不包含任何關於你或你錄影內容的資訊。你可以在設定中關閉自動檢查。"],
    ["Microsoft Store 版本", "Microsoft", "由 Store 安裝和更新 App，App 本身沒有更新程式。Microsoft 可能會依據其<a href=\"https://privacy.microsoft.com/privacystatement\">隱私權聲明</a>收集診斷資料。"],
  ],

  agentsH: "AI 代理程式",
  agentsP: "如果你開啟<strong>設定 &gt; AI 代理程式</strong>（預設為關閉），Claude、Codex 或 Cursor 等 AI 代理程式可以透過本機連線控制 Native Screen，只有在這台電腦上以你的使用者帳號執行的程式才能開啟這個連線。代理程式可以做你在 App 中能做的事：開始錄影（錄製列及其倒數一律會顯示）、開啟和編輯專案、讀取專案資訊和畫面、將影片和影像輸出為檔案，以及把你電腦上的影片或影像檔案交給 App 匯入。App 不會為此透過網際網路傳送任何內容，但代理程式可能會依照其 AI 服務提供者的條款，將它讀取的內容傳送給該提供者。關閉此設定即可阻止代理程式的所有存取。",

  notH: "我們不做的事",
  notList: [
    "沒有帳號，不需登入。",
    "沒有分析統計、使用追蹤或廣告。",
    "App 不傳送當機報告。",
    "不出售或分享個人資料。我們沒有任何個人資料可分享。",
  ],

  webH: "本網站",
  webP: "nativescreen.app 是託管在 GitHub Pages 上的靜態網站。它沒有分析統計，也不設定 Cookie。字型從 Google Fonts 載入，因此在提供頁面的過程中，GitHub 和 Google 會收到你的 IP 位址和瀏覽器資訊。你的主題和語言選擇保存在瀏覽器的本機儲存空間中，絕不會離開你的裝置。",

  kidsH: "兒童",
  kidsP: "Native Screen 不蒐集任何人的個人資訊，包括未滿 13 歲的兒童。",

  choiceH: "你的選擇",
  choiceP: "你的資料在你的電腦上，因此由你掌控。刪除專案即可移除其錄影內容和輸入資料。解除安裝會移除 App。專案、輸出的檔案和下載的模型會保留在你的電腦上，直到你刪除它們。",

  changesH: "變更",
  changesP: "如果本政策有所變更，新版本將在本頁面發布並註明新的日期。每次變更的歷史紀錄都公開在<a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">程式碼儲存庫</a>中。",

  contactH: "聯絡方式",
  contactP: "隱私相關問題：寄送電子郵件至 <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a>，或在 <a href=\"{repo}/issues\">GitHub</a> 上提出 issue。",
};
