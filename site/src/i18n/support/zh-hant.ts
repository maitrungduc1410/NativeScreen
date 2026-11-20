export default {
  title: "支援 · Native Screen",
  desc: "Native Screen（macOS 與 Windows）的說明：聯絡方式、問題回報與常見問題解答。",
  back: "返回首頁",
  h1: "支援",
  lede: "使用 Native Screen 時需要協助、發現 bug 或有新點子？歡迎與我們聯絡。每則訊息都會由開發這款 App 的人親自閱讀。",

  contactH: "聯絡我們",
  email: "電子郵件",
  emailNote: "適合提問、回報問題以及任何私密內容。",
  issues: "GitHub Issues",
  issuesNote: "適合回報 bug 和提出功能建議，其他人也能追蹤與補充。",
  tipsP: "為了更快解決問題，請附上：",
  tips: [
    "Native Screen 的版本（在「關於 Native Screen」中查看）以及安裝來源（Mac App Store、Microsoft Store 或官網）；",
    "你的 macOS 或 Windows 版本以及電腦型號；",
    "你做了什麼、預期的結果與實際發生的情況，可以的話請附上截圖或一段簡短錄影。",
  ],

  faqH: "常見問題",
  faq: [
    ["錄影畫面是黑的，或 App 看不到我的螢幕。", "Native Screen 需要螢幕錄影權限。在 macOS 上，打開「系統設定 &gt; 隱私權與安全性 &gt; 螢幕與系統錄音」（macOS 14 為「螢幕錄影」），開啟 Native Screen，然後結束並重新打開 App。Windows 不需要授權。如果某個視窗仍錄成黑色，可能是該 App 阻擋了螢幕擷取。"],
    ["相機或麥克風無法使用。", "在 macOS 上，到「系統設定 &gt; 隱私權與安全性 &gt; 相機」或「麥克風」允許 Native Screen。在 Windows 上，檢查「設定 &gt; 隱私權與安全性 &gt; 相機」或「麥克風」。然後在開始錄影前，於錄影列選擇裝置。"],
    ["錄影檔存在哪裡？", "每次錄影都會以專案的形式存在專案資料夾中。在「設定」中可以看到位置並變更。Mac App Store 版本預設為「影片 &gt; Native Screen Projects」。匯出的影片與圖片會存到你匯出時選擇的資料夾。"],
    ["如何更新 App？", "Mac App Store 與 Microsoft Store 會自動幫你更新。如果是從官網下載，App 會自行檢查更新，在 macOS 上也可以選擇 Native Screen &gt; Check for Updates。"],
    ["執行需要什麼配備？", "macOS 14 或更新版本（Apple 晶片或 Intel），或 Windows 10、11（x64）。"],
    ["真的免費嗎？", "是的。Native Screen 以 MIT 授權免費開源。不需要帳號，沒有訂閱，也沒有浮水印。"],
    ["如何解除安裝？", "在 macOS 上，把 Native Screen 從「應用程式」拖到垃圾桶。在 Windows 上，打開「設定 &gt; 應用程式」解除安裝。你的專案與匯出檔會留在電腦上，直到你刪除為止。"],
  ],

  moreH: "更多",
  moreP: "閱讀<a href=\"{privacy}\">隱私權政策</a>了解你的資料如何處理（資料永遠不會離開你的電腦）。原始碼與版本說明都在 <a href=\"{repo}\">GitHub</a> 上。",

  footerLink: "支援",
};
