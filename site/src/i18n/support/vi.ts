export default {
  title: "Hỗ trợ · Native Screen",
  desc: "Hỗ trợ cho Native Screen trên macOS và Windows: liên hệ, báo lỗi và giải đáp các câu hỏi thường gặp.",
  back: "Về trang chủ",
  h1: "Hỗ trợ",
  lede: "Cần giúp đỡ với Native Screen, gặp lỗi hay có ý tưởng mới? Hãy liên hệ với chúng tôi. Mọi tin nhắn đều được chính những người làm ra ứng dụng đọc.",

  contactH: "Liên hệ",
  email: "Email",
  emailNote: "Cho câu hỏi, sự cố và những gì cần giữ riêng tư.",
  issues: "GitHub Issues",
  issuesNote: "Để báo lỗi và đề xuất tính năng. Người khác cũng có thể theo dõi và góp ý.",
  tipsP: "Để chúng tôi sửa lỗi nhanh hơn, bạn hãy gửi kèm:",
  tips: [
    "phiên bản Native Screen (xem trong About Native Screen) và nơi bạn cài (Mac App Store, Microsoft Store hay trang web);",
    "phiên bản macOS hoặc Windows và dòng máy của bạn;",
    "bạn đã làm gì, mong đợi điều gì và chuyện gì đã xảy ra, kèm ảnh chụp màn hình hoặc một đoạn quay ngắn nếu được.",
  ],

  faqH: "Câu hỏi thường gặp",
  faq: [
    ["Video quay bị đen, hoặc ứng dụng không thấy màn hình.", "Native Screen cần quyền ghi màn hình. Trên macOS, mở System Settings &gt; Privacy &amp; Security &gt; Screen &amp; System Audio Recording (trên macOS 14 là Screen Recording), bật Native Screen, rồi thoát và mở lại ứng dụng. Trên Windows không cần cấp quyền. Nếu một cửa sổ vẫn bị đen, có thể ứng dụng đó đang chặn quay màn hình."],
    ["Camera hoặc micro không hoạt động.", "Trên macOS, cho phép Native Screen trong System Settings &gt; Privacy &amp; Security &gt; Camera hoặc Microphone. Trên Windows, kiểm tra Settings &gt; Privacy &amp; security &gt; Camera hoặc Microphone. Sau đó chọn thiết bị trên thanh quay trước khi bắt đầu."],
    ["Bản ghi được lưu ở đâu?", "Mỗi lần quay được lưu thành một dự án trong thư mục dự án. Phần Settings cho biết thư mục đó ở đâu và cho phép đổi. Với bản Mac App Store, mặc định là Movies &gt; Native Screen Projects. Video và ảnh xuất ra được lưu vào thư mục bạn chọn khi xuất."],
    ["Cập nhật ứng dụng thế nào?", "Mac App Store và Microsoft Store tự cập nhật cho bạn. Nếu bạn tải từ trang web này, ứng dụng tự kiểm tra bản mới, và trên macOS bạn cũng có thể chọn Native Screen &gt; Check for Updates."],
    ["Cần máy như thế nào để chạy?", "macOS 14 trở lên trên Apple silicon hoặc Intel, hoặc Windows 10 hay 11 (x64)."],
    ["Có thật sự miễn phí không?", "Có. Native Screen miễn phí và mã nguồn mở theo giấy phép MIT. Không tài khoản, không thuê bao, không watermark."],
    ["Gỡ cài đặt thế nào?", "Trên macOS, kéo Native Screen từ Applications vào Thùng rác. Trên Windows, mở Settings &gt; Apps rồi gỡ cài đặt. Dự án và file đã xuất vẫn ở trên máy cho tới khi bạn xóa."],
  ],

  moreH: "Thêm",
  moreP: "Đọc <a href=\"{privacy}\">Chính sách quyền riêng tư</a> để biết dữ liệu của bạn được xử lý thế nào (nó không bao giờ rời khỏi máy bạn). Mã nguồn và ghi chú phát hành có trên <a href=\"{repo}\">GitHub</a>.",

  footerLink: "Hỗ trợ",
};
