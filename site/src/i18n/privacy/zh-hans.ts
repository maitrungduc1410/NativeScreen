export default {
  title: "隐私政策 · Native Screen",
  desc: "Native Screen 如何处理你的录制内容和数据：一切都留在你的电脑上，无需账户，没有分析统计，不会上传。",
  back: "返回首页",
  updated: "最后更新：{date}",
  h1: "隐私政策",
  note: "本译文仅供参考。如与<a href=\"/privacy/\">英文版本</a>有出入，以英文版本为准。",
  lede: "Native Screen 在你的电脑上录制和编辑。没有账户，没有我们的服务器，没有分析统计，也没有广告。应用从不上传你的录制内容。",
  scope: "本政策适用于 macOS 和 Windows 版 Native Screen 应用（包括 Microsoft Store 和 Mac App Store 版本）以及本网站。该应用免费且开源，因此以下所有内容都可以在<a href=\"{repo}\">源代码</a>中核实。",

  stayH: "留在你电脑上的内容",
  stayP: "你用 Native Screen 制作的一切都存储在你的电脑上，应用绝不会将其发送到任何地方：",
  stayList: [
    "屏幕、窗口和区域录制，摄像头视频，麦克风和系统音频；",
    "随每次录制记录的鼠标位置、点按和按键（用于自动缩放、平滑光标和快捷键显示），以及你录制的窗口或应用的名称；",
    "录制时在屏幕上绘制的内容、演讲者备注和录制配置文件；",
    "项目、编辑、预设、字幕和文字稿；",
    "导出的视频、GIF、图像和字幕文件；",
    "你的设置。",
  ],
  onDevice: "字幕、文字稿、敏感数据检测（电子邮件、密钥、人脸）、面部追踪和摄像头背景移除都在你的电脑上运行。在 macOS 上，这些功能使用 Apple 的内置框架，并且语音识别被设置为仅在设备上运行，因此不会向 Apple 发送任何音频。在 Windows 上，字幕使用 Whisper 模型，背景移除使用 MODNet 模型。每个模型只下载一次，之后在本机运行。",
  keys: "只有在录制进行时才会记录按键。按键只保存在该项目中，不会存放在其他地方；删除项目即可删除这些按键。",

  permH: "应用请求的权限",
  permP: "每项权限只用于其旁边列出的功能。",
  permCols: ["权限", "原因"],
  perms: [
    ["屏幕录制", "录制你选择的显示器、窗口或区域。"],
    ["麦克风", "在你打开麦克风时，录制你的声音和旁白。"],
    ["摄像头", "在你打开摄像头时，录制摄像头画面。"],
    ["辅助功能（macOS，直接下载版）", "列出并选择窗口，以及在录制期间跟随点按和按键。"],
    ["输入监控（Mac App Store 版本）", "仅在录制期间：按键会显示为快捷键浮层。此版本请求该权限，而不是辅助功能。"],
    ["语音识别（macOS）", "使用 Apple 的设备端识别器生成字幕。"],
    ["键盘和鼠标输入（Windows）", "仅在录制期间：点按用于自动缩放和点按效果，按键显示为快捷键。"],
    ["完全信任（Windows）", "Native Screen 是一款桌面应用。它需要完全访问权限才能使用 Windows 屏幕捕获、系统音频捕获、硬件视频编码和 GPU，打包应用无法以其他方式使用这些功能。"],
    ["互联网", "仅用于下文列出的下载和更新检查。"],
  ],

  leaveH: "离开你电脑的内容",
  leaveP: "应用只在以下情况下连接互联网。这些情况都不包含你的录制内容、项目或你输入的任何内容。",
  leaveCols: ["时间", "目的地", "发送的内容"],
  leave: [
    ["在 Windows 上首次使用字幕或摄像头背景移除时", "Hugging Face（huggingface.co）", "一个下载模型文件的请求。与任何下载一样，Hugging Face 能看到你的 IP 地址。macOS 应用不下载任何模型。"],
    ["检查和下载更新（Mac App Store 之外的 macOS，以及 Microsoft Store 之外的 Windows 版本）", "GitHub", "一个获取最新版本信息的请求，有新版本时还会下载更新文件。GitHub 能看到你的 IP 地址和标准的请求标头。其中不包含任何关于你或你录制内容的信息。你可以在设置中关闭自动检查。"],
    ["Microsoft Store 版本", "Microsoft", "由 Store 安装和更新应用，应用本身没有更新程序。Microsoft 可能会依据其<a href=\"https://privacy.microsoft.com/privacystatement\">隐私声明</a>收集诊断数据。"],
    ["Mac App Store 版本", "Apple", "由 App Store 安装和更新应用，应用本身没有更新程序，也不会连接互联网。Apple 可能会依据其<a href=\"https://www.apple.com/legal/privacy/\">隐私政策</a>收集诊断数据。"],
  ],

  agentsH: "AI 代理",
  agentsP: "如果你打开<strong>设置 &gt; AI 代理</strong>（默认关闭），Claude、Codex 或 Cursor 等 AI 代理可以通过本地连接控制 Native Screen，只有在这台电脑上以你的用户账户运行的程序才能打开这个连接。代理可以做你在应用中能做的事：开始录制（录制栏及其倒计时始终会显示）、打开和编辑项目、读取项目信息和画面、将视频和图像导出为文件，以及把你电脑上的视频或图像文件交给应用导入。应用不会为此通过互联网发送任何内容，但代理可能会按照其 AI 服务提供商的条款，把它读取的内容发送给该提供商。关闭此设置即可阻止代理的所有访问。Mac App Store 版本不包含此功能。",

  notH: "我们不做的事",
  notList: [
    "没有账户，无需登录。",
    "没有分析统计、使用跟踪或广告。",
    "应用不发送崩溃报告。",
    "不出售或分享个人数据。我们没有任何个人数据可分享。",
  ],

  webH: "本网站",
  webP: "nativescreen.app 是托管在 GitHub Pages 上的静态网站。它没有分析统计，也不设置 Cookie。字体从 Google Fonts 加载，因此在提供页面的过程中，GitHub 和 Google 会收到你的 IP 地址和浏览器信息。你的主题和语言选择保存在浏览器的本地存储中，绝不会离开你的设备。",

  kidsH: "儿童",
  kidsP: "Native Screen 不收集任何人的个人信息，包括 13 岁以下的儿童。",

  choiceH: "你的选择",
  choiceP: "你的数据在你的电脑上，因此由你掌控。删除项目即可移除其录制内容和输入数据。卸载会移除应用。项目、导出的文件和下载的模型会保留在你的电脑上，直到你删除它们。",

  changesH: "变更",
  changesP: "如果本政策发生变更，新版本将在本页面发布并注明新的日期。每次变更的历史记录都公开在<a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">代码仓库</a>中。",

  contactH: "联系方式",
  contactP: "隐私相关问题：发送电子邮件至 <a href=\"mailto:hello@nativescreen.app\">hello@nativescreen.app</a>，或在 <a href=\"{repo}/issues\">GitHub</a> 上提交 issue。",
};
