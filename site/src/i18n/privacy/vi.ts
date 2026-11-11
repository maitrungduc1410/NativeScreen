export default {
  title: "Chính sách quyền riêng tư · Native Screen",
  desc: "Native Screen làm gì với bản ghi và dữ liệu của bạn: mọi thứ ở lại trên máy bạn, không tài khoản, không analytics, không tải lên.",
  back: "Về trang chủ",
  updated: "Cập nhật lần cuối: {date}",
  h1: "Chính sách quyền riêng tư",
  note: "Bản dịch này chỉ để tham khảo. Nếu có khác biệt với <a href=\"/privacy/\">bản tiếng Anh</a>, bản tiếng Anh được áp dụng.",
  lede: "Native Screen quay và dựng video ngay trên máy của bạn. Không có tài khoản, không có máy chủ nào của chúng tôi, không analytics và không quảng cáo. Ứng dụng không bao giờ tải bản ghi của bạn lên.",
  scope: "Chính sách này áp dụng cho ứng dụng Native Screen trên macOS và Windows (kể cả bản trên Microsoft Store) và cho trang web này. Ứng dụng miễn phí và mã nguồn mở, nên mọi điều dưới đây đều có thể kiểm tra trong <a href=\"{repo}\">mã nguồn</a>.",

  stayH: "Những gì ở lại trên máy bạn",
  stayP: "Mọi thứ bạn tạo bằng Native Screen đều được lưu trên máy bạn và ứng dụng không bao giờ gửi đi đâu:",
  stayList: [
    "bản ghi màn hình, cửa sổ và vùng chọn, video camera, âm thanh micro và âm thanh hệ thống;",
    "vị trí chuột, cú nhấp và phím bấm được ghi cùng mỗi lần quay, dùng cho zoom tự động, con trỏ mượt và hiển thị phím tắt, cùng tên cửa sổ hoặc ứng dụng bạn đã quay;",
    "nét vẽ trên màn hình trong lúc quay, ghi chú cho người nói và hồ sơ quay;",
    "dự án, chỉnh sửa, preset, phụ đề và bản chép lời;",
    "video, GIF, hình ảnh và tệp phụ đề đã xuất;",
    "cài đặt của bạn.",
  ],
  onDevice: "Phụ đề, bản chép lời, phát hiện dữ liệu nhạy cảm (email, khóa, khuôn mặt), theo dõi khuôn mặt và tách nền camera đều chạy trên máy bạn. Trên macOS, các tính năng này dùng framework có sẵn của Apple, và nhận dạng giọng nói được đặt chỉ chạy trên thiết bị, nên không có âm thanh nào được gửi tới Apple. Trên Windows, phụ đề dùng mô hình Whisper và tách nền dùng mô hình MODNet. Mỗi mô hình được tải về một lần rồi chạy cục bộ.",
  keys: "Phím bấm chỉ được ghi khi đang quay. Chúng được lưu trong chính dự án đó và không ở nơi nào khác, và bạn có thể xóa chúng bằng cách xóa dự án.",

  permH: "Các quyền ứng dụng yêu cầu",
  permP: "Mỗi quyền chỉ được dùng cho đúng tính năng ghi bên cạnh.",
  permCols: ["Quyền", "Lý do"],
  perms: [
    ["Ghi màn hình", "Để quay một màn hình, một cửa sổ hoặc một vùng bạn chọn."],
    ["Micro", "Để thu giọng nói và lời thuyết minh, khi bạn bật micro."],
    ["Camera", "Để quay camera, khi bạn bật nó."],
    ["Trợ năng (macOS)", "Để liệt kê và chọn cửa sổ, và để theo dõi cú nhấp và phím bấm trong lúc quay."],
    ["Nhận dạng giọng nói (macOS)", "Để tạo phụ đề bằng bộ nhận dạng trên thiết bị của Apple."],
    ["Nhập liệu bàn phím và chuột (Windows)", "Chỉ trong lúc quay: cú nhấp tạo zoom tự động và hiệu ứng nhấp, phím bấm hiển thị thành phím tắt."],
    ["Toàn quyền (Windows)", "Native Screen là ứng dụng desktop. Nó cần toàn quyền để dùng tính năng ghi màn hình, thu âm thanh hệ thống, mã hóa video bằng phần cứng và GPU của Windows, những thứ mà ứng dụng đóng gói không thể truy cập theo cách khác."],
    ["Internet", "Chỉ cho các lượt tải xuống và kiểm tra cập nhật liệt kê bên dưới."],
  ],

  leaveH: "Những gì rời khỏi máy bạn",
  leaveP: "Ứng dụng chỉ kết nối internet trong các trường hợp sau. Không trường hợp nào gửi kèm bản ghi, dự án hay bất cứ điều gì bạn đã gõ.",
  leaveCols: ["Khi nào", "Đến đâu", "Gửi những gì"],
  leave: [
    ["Lần đầu bạn dùng phụ đề hoặc tách nền camera trên Windows", "Hugging Face (huggingface.co)", "Một yêu cầu tải tệp mô hình. Hugging Face thấy địa chỉ IP của bạn, như với mọi lượt tải xuống. Ứng dụng macOS không tải mô hình nào."],
    ["Kiểm tra và tải bản cập nhật (macOS, và Windows ngoài Microsoft Store)", "GitHub", "Một yêu cầu lấy bản phát hành mới nhất và, khi có, tệp cập nhật. GitHub thấy địa chỉ IP của bạn và các header thông thường của yêu cầu. Không có thông tin nào về bạn hay bản ghi của bạn. Bạn có thể tắt tự động kiểm tra trong Cài đặt."],
    ["Bản trên Microsoft Store", "Microsoft", "Store cài đặt và cập nhật ứng dụng, ứng dụng không có trình cập nhật riêng. Microsoft có thể thu thập dữ liệu chẩn đoán theo <a href=\"https://privacy.microsoft.com/privacystatement\">tuyên bố quyền riêng tư</a> của họ."],
  ],

  agentsH: "AI agent",
  agentsP: "Nếu bạn bật <strong>Cài đặt &gt; AI Agent</strong> (mặc định tắt), các AI agent như Claude, Codex hoặc Cursor có thể điều khiển Native Screen qua một kết nối cục bộ mà chỉ chương trình chạy dưới tài khoản người dùng của bạn trên máy này mới mở được. Agent có thể làm những gì bạn làm được trong ứng dụng: bắt đầu quay (thanh ghi hình và đếm ngược luôn hiện), mở và sửa dự án, đọc thông tin dự án và khung hình, xuất video và hình ảnh ra tệp, và đưa cho ứng dụng một tệp video hoặc hình ảnh trên máy bạn để nhập vào. Ứng dụng không gửi gì qua internet cho việc này, nhưng agent có thể gửi những gì nó đọc được tới nhà cung cấp AI của nó theo điều khoản của nhà cung cấp đó. Tắt cài đặt này để chặn mọi quyền truy cập của agent.",

  notH: "Những điều chúng tôi không làm",
  notList: [
    "Không tài khoản, không đăng nhập.",
    "Không analytics, không theo dõi sử dụng, không quảng cáo.",
    "Ứng dụng không gửi báo cáo lỗi.",
    "Không bán hay chia sẻ dữ liệu cá nhân. Chúng tôi không có dữ liệu nào để chia sẻ.",
  ],

  webH: "Trang web này",
  webP: "nativescreen.app là trang tĩnh được lưu trữ trên GitHub Pages. Trang không có analytics và không đặt cookie. Phông chữ được tải từ Google Fonts, nên GitHub và Google nhận được địa chỉ IP và thông tin trình duyệt của bạn trong quá trình phục vụ trang. Lựa chọn giao diện và ngôn ngữ của bạn được giữ trong bộ nhớ cục bộ của trình duyệt và không bao giờ rời khỏi thiết bị.",

  kidsH: "Trẻ em",
  kidsP: "Native Screen không thu thập thông tin cá nhân của bất kỳ ai, kể cả trẻ em dưới 13 tuổi.",

  choiceH: "Lựa chọn của bạn",
  choiceP: "Dữ liệu của bạn nằm trên máy bạn, nên bạn toàn quyền kiểm soát. Xóa một dự án để xóa bản ghi và dữ liệu nhập liệu của nó. Gỡ cài đặt sẽ xóa ứng dụng. Dự án, tệp đã xuất và mô hình đã tải vẫn ở trên máy bạn cho tới khi bạn xóa chúng.",

  changesH: "Thay đổi",
  changesP: "Nếu chính sách này thay đổi, phiên bản mới sẽ được đăng trên trang này với ngày mới. Lịch sử mọi thay đổi được công khai trong <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">kho mã</a>.",

  contactH: "Liên hệ",
  contactP: "Câu hỏi về quyền riêng tư: gửi email tới <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a> hoặc mở issue trên <a href=\"{repo}/issues\">GitHub</a>.",
};
