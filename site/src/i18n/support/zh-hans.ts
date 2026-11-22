export default {
  title: "支持 · Native Screen",
  desc: "Native Screen（macOS 和 Windows）的帮助：联系方式、问题反馈和常见问题解答。",
  back: "返回首页",
  h1: "支持",
  lede: "使用 Native Screen 时需要帮助、发现了 bug 或有新想法？欢迎联系我们。每条消息都会由开发这款应用的人亲自阅读。",

  contactH: "联系我们",
  email: "电子邮件",
  emailNote: "适合提问、反馈问题以及任何私密内容。",
  issues: "GitHub Issues",
  issuesNote: "适合报告 bug 和提出功能建议，其他人也可以关注和补充。",
  tipsP: "为了更快解决问题，请附上：",
  tips: [
    "Native Screen 的版本（在“关于 Native Screen”中查看）以及安装来源（Mac App Store、Microsoft Store 或官网）；",
    "你的 macOS 或 Windows 版本以及电脑型号；",
    "你做了什么、预期结果和实际发生的情况，如果可以，请附上截图或一段简短录屏。",
  ],

  faqH: "常见问题",
  faq: [
    ["录制画面是黑的，或者应用看不到我的屏幕。", "Native Screen 需要屏幕录制权限。在 macOS 上，打开“系统设置 &gt; 隐私与安全性 &gt; 录屏与系统录音”（macOS 14 上为“屏幕录制”），打开 Native Screen，然后退出并重新打开应用。Windows 不需要授权。如果某个窗口仍然录成黑色，可能是该应用阻止了屏幕捕获。"],
    ["摄像头或麦克风无法使用。", "在 macOS 上，到“系统设置 &gt; 隐私与安全性 &gt; 摄像头”或“麦克风”中允许 Native Screen。在 Windows 上，检查“设置 &gt; 隐私和安全性 &gt; 摄像头”或“麦克风”。然后在开始录制前，在录制栏中选择对应设备。"],
    ["录制内容保存在哪里？", "每次录制都会作为一个项目保存在项目文件夹中。在“设置”里可以看到它的位置并进行更改。Mac App Store 版本会在你第一次录制时请你选择这个文件夹。导出的视频和图片会保存到你导出时选择的文件夹。"],
    ["如何更新应用？", "Mac App Store 和 Microsoft Store 会自动为你更新。如果是从官网下载的，应用会自行检查更新，在 macOS 上也可以选择 Native Screen &gt; Check for Updates。"],
    ["运行需要什么配置？", "macOS 14 或更高版本（Apple 芯片或 Intel），或 Windows 10、11（x64）。"],
    ["真的免费吗？", "是的。Native Screen 基于 MIT 许可证免费开源。无需账号，没有订阅，也没有水印。"],
    ["如何卸载？", "在 macOS 上，把 Native Screen 从“应用程序”拖到废纸篓。在 Windows 上，打开“设置 &gt; 应用”进行卸载。你的项目和导出文件会保留在电脑上，直到你删除它们。"],
  ],

  moreH: "更多",
  moreP: "阅读<a href=\"{privacy}\">隐私政策</a>了解你的数据如何处理（数据永远不会离开你的电脑）。源代码和更新说明发布在 <a href=\"{repo}\">GitHub</a> 上。",

  footerLink: "支持",
};
