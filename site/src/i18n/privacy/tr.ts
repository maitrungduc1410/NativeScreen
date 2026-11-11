export default {
  title: "Gizlilik Politikası · Native Screen",
  desc: "Native Screen kayıtlarınızla ve verilerinizle ne yapar: her şey bilgisayarınızda kalır; hesap yok, analiz yok, yükleme yok.",
  back: "Ana sayfaya dön",
  updated: "Son güncelleme: {date}",
  h1: "Gizlilik Politikası",
  note: "Bu çeviri yalnızca bilgi amaçlıdır. <a href=\"/privacy/\">İngilizce sürümden</a> farklı olması durumunda İngilizce sürüm geçerlidir.",
  lede: "Native Screen bilgisayarınızda kaydeder ve düzenler. Hesap yok, bize ait bir sunucu yok, analiz yok ve reklam yok. Uygulama kayıtlarınızı asla yüklemez.",
  scope: "Bu politika, macOS ve Windows için Native Screen uygulamalarını (Microsoft Store sürümü dahil) ve bu web sitesini kapsar. Uygulama ücretsiz ve açık kaynaktır; aşağıdaki her şey <a href=\"{repo}\">kaynak kodda</a> doğrulanabilir.",

  stayH: "Bilgisayarınızda kalanlar",
  stayP: "Native Screen ile oluşturduğunuz her şey bilgisayarınızda saklanır ve uygulama tarafından hiçbir yere gönderilmez:",
  stayList: [
    "ekran, pencere ve alan kayıtları, kamera videosu, mikrofon ve sistem sesi;",
    "bir çekimle birlikte kaydedilen ve otomatik yakınlaştırmalar, akıcı imleç ile klavye kısayolu gösterimi için kullanılan fare konumları, tıklamalar ve tuş basışları ile kaydettiğiniz pencerenin veya uygulamanın adı;",
    "kayıt sırasında ekrana yapılan çizimler, konuşmacı notları ve kayıt profilleri;",
    "projeler, düzenlemeler, ön ayarlar, altyazılar ve metin dökümleri;",
    "dışa aktarılan videolar, GIF'ler, resimler ve altyazı dosyaları;",
    "ayarlarınız.",
  ],
  onDevice: "Altyazılar, metin dökümleri, hassas veri algılama (e-postalar, anahtarlar, yüzler), yüz takibi ve kamera arka planını kaldırma işlemlerinin tümü bilgisayarınızda çalışır. macOS'ta bunlar Apple'ın yerleşik çerçevelerini kullanır ve konuşma tanıma yalnızca cihazda çalışacak şekilde ayarlıdır; bu nedenle Apple'a hiçbir ses gönderilmez. Windows'ta altyazılar bir Whisper modeli, arka plan kaldırma ise bir MODNet modeli kullanır. Her biri bir kez indirilir, ardından yerel olarak çalışır.",
  keys: "Tuş basışları yalnızca kayıt sürerken kaydedilir. Yalnızca o projenin içinde saklanır, başka hiçbir yerde tutulmaz; projeyi silerek bunları da silebilirsiniz.",

  permH: "Uygulamanın istediği izinler",
  permP: "Her izin yalnızca yanında belirtilen özellik için kullanılır.",
  permCols: ["İzin", "Neden"],
  perms: [
    ["Ekran kaydı", "Seçtiğiniz bir ekranı, pencereyi veya alanı kaydetmek için."],
    ["Mikrofon", "Mikrofonu açtığınızda sesinizi ve seslendirmelerinizi kaydetmek için."],
    ["Kamera", "Kamerayı açtığınızda kameranızı kaydetmek için."],
    ["Erişilebilirlik (macOS)", "Pencereleri listelemek ve seçmek, ayrıca kayıt sırasında tıklamaları ve tuş basışlarını izlemek için."],
    ["Konuşma tanıma (macOS)", "Apple'ın cihaz üzerindeki tanıma özelliğiyle altyazı oluşturmak için."],
    ["Klavye ve fare girişi (Windows)", "Yalnızca kayıt sırasında: tıklamalar otomatik yakınlaştırmaları ve tıklama efektlerini yönlendirir, tuş basışları kısayol gösterimine dönüşür."],
    ["Tam güven (Windows)", "Native Screen bir masaüstü uygulamasıdır. Windows ekran yakalama, sistem sesi yakalama, donanım video kodlama ve GPU özelliklerini kullanmak için tam erişime ihtiyaç duyar; paketlenmiş uygulamalar bunlara başka türlü erişemez."],
    ["İnternet", "Yalnızca aşağıda listelenen indirmeler ve güncelleme denetimleri için."],
  ],

  leaveH: "Bilgisayarınızdan çıkanlar",
  leaveP: "Uygulama yalnızca bu durumlarda internete bağlanır. Bunların hiçbiri kayıtlarınızı, projelerinizi veya yazdığınız herhangi bir şeyi içermez.",
  leaveCols: ["Ne zaman", "Nereye", "Ne gönderilir"],
  leave: [
    ["Windows'ta altyazıları veya kamera arka planını kaldırmayı ilk kez kullandığınızda", "Hugging Face (huggingface.co)", "Model dosyasını indirmek için bir istek. Her indirmede olduğu gibi Hugging Face IP adresinizi görür. macOS uygulaması hiçbir model indirmez."],
    ["Güncellemeleri denetleme ve indirme (macOS ve Microsoft Store dışındaki Windows)", "GitHub", "En son sürüm için bir istek ve varsa güncelleme dosyası. GitHub IP adresinizi ve standart istek başlıklarını görür. Siz veya kayıtlarınız hakkında hiçbir bilgi içermez. Otomatik denetimleri Ayarlar'dan kapatabilirsiniz."],
    ["Microsoft Store sürümü", "Microsoft", "Uygulamayı Store yükler ve günceller; uygulamanın kendi güncelleyicisi yoktur. Microsoft kendi <a href=\"https://privacy.microsoft.com/privacystatement\">gizlilik bildirimi</a> kapsamında tanılama verileri toplayabilir."],
  ],

  agentsH: "YZ ajanları",
  agentsP: "<strong>Ayarlar &gt; YZ ajanları</strong> seçeneğini açarsanız (varsayılan olarak kapalıdır), Claude, Codex veya Cursor gibi YZ ajanları Native Screen'i yalnızca bu bilgisayarda sizin kullanıcı hesabınızla çalışan programların açabildiği yerel bir bağlantı üzerinden kontrol edebilir. Bir ajan uygulamada sizin yapabildiklerinizi yapabilir: kayıt başlatmak (kayıt çubuğu ve geri sayımı her zaman gösterilir), projeleri açıp düzenlemek, proje bilgilerini ve karelerini okumak, videoları ve resimleri dosyalara dışa aktarmak ve bilgisayarınızdaki bir video veya resim dosyasını içe aktarılması için uygulamaya vermek. Uygulama bunun için internet üzerinden hiçbir şey göndermez, ancak ajan okuduklarını kendi YZ sağlayıcısına o sağlayıcının koşulları altında gönderebilir. Ajanların tüm erişimini durdurmak için ayarı kapatın.",

  notH: "Yapmadıklarımız",
  notList: [
    "Hesap veya oturum açma yok.",
    "Analiz, kullanım takibi veya reklam yok.",
    "Uygulama çökme raporu göndermez.",
    "Kişisel verileri satmayız veya paylaşmayız. Paylaşacak hiçbir verimiz yok.",
  ],

  webH: "Bu web sitesi",
  webP: "nativescreen.app, GitHub Pages üzerinde barındırılan statik bir sitedir. Analiz kullanmaz ve çerez bırakmaz. Yazı tipleri Google Fonts'tan yüklenir; bu nedenle sayfa sunulurken GitHub ve Google IP adresinizi ve tarayıcı bilgilerinizi alır. Tema ve dil seçimleriniz tarayıcınızın yerel depolamasında tutulur ve cihazınızdan asla çıkmaz.",

  kidsH: "Çocuklar",
  kidsP: "Native Screen, 13 yaşından küçük çocuklar dahil hiç kimseden kişisel bilgi toplamaz.",

  choiceH: "Seçimleriniz",
  choiceP: "Verileriniz bilgisayarınızdadır, bu yüzden kontrol sizdedir. Bir projeyi silerek kayıtlarını ve giriş verilerini kaldırabilirsiniz. Kaldırma işlemi uygulamayı kaldırır. Projeler, dışa aktarılan dosyalar ve indirilen modeller siz silene kadar bilgisayarınızda kalır.",

  changesH: "Değişiklikler",
  changesP: "Bu politika değişirse yeni sürüm yeni bir tarihle bu sayfada yayımlanır. Her değişikliğin geçmişi <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">depoda</a> herkese açıktır.",

  contactH: "İletişim",
  contactP: "Gizlilikle ilgili sorular için <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a> adresine e-posta gönderin veya <a href=\"{repo}/issues\">GitHub</a> üzerinde bir issue açın.",
};
