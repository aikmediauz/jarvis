import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:local_auth/local_auth.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:another_telephony/telephony.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'dart:io';

void main() => runApp(const JarvisApp());

const geminiModels = [
  "gemini-2.5-pro", "gemini-3-pro-preview", "gemini-pro-latest",
  "gemini-flash-latest", "gemini-2.5-flash", "gemini-2.0-flash"
];
const ttsModels = ["gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"];
// Gemini erkak ovozlari (chuqur/erkak tovushli)
const maleVoices = [
  "Charon", "Algenib", "Fenrir", "Orus", "Iapetus", "Schedar", "Rasalgethi", "Sadaltager"
];
const systemPrompt =
    "Sen - JARVIS, foydalanuvchining shaxsiy AI yordamchisi. Qisqa, tabiiy, iliq javob ber. "
    "HAR DOIM O'ZBEK TILIDA (lotin) qisqa va aniq javob ber. Faqat foydalanuvchi ochiq rus/ingliz tilida gapirsa, o'sha tilda. Ishonchsiz bo'lsang o'zbekda javob ber. "
    "Agar foydalanuvchi telefon amalini so'rasa, FAQAT bitta JSON qaytar (boshqa hech qanday matnsiz): "
    "qo'ng'iroq uchun {\"action\":\"call\",\"number\":\"+998...\"} ; "
    "SMS uchun {\"action\":\"sms\",\"number\":\"+998...\",\"message\":\"matn\"} ; "
    "Google qidiruv uchun {\"action\":\"search\",\"query\":\"...\"} ; "
    "YouTube uchun {\"action\":\"youtube\",\"query\":\"...\"} ; "
    "xarita uchun {\"action\":\"maps\",\"query\":\"joy\"} ; "
    "sayt/ilova ochish uchun {\"action\":\"open\",\"url\":\"https://...\"} ; "
    "Telegram xabar uchun {\"action\":\"telegram\",\"message\":\"matn\"} (kim ekanini foydalanuvchi tanlaydi) yoki {\"action\":\"telegram\",\"username\":\"nomi\"} (shu chatni ochadi) ; "
    "budilnik uchun {\"action\":\"alarm\",\"hour\":7,\"minute\":30,\"message\":\"...\"} ; "
    "taymer uchun {\"action\":\"timer\",\"seconds\":300,\"message\":\"...\"} ; "
    "musiqa uchun {\"action\":\"music\",\"query\":\"qo'shiq yoki ijrochi\"} ; "
    "kalendar/eslatma uchun {\"action\":\"calendar\",\"title\":\"...\"} . "
    "Agar amal kerak bo'lmasa, oddiy matn bilan javob ber (JSONsiz).";

enum JState { idle, listening, thinking, speaking }

String jarvisCategory(String b, String dir) {
  if (dir == "in") return "Kirim";
  bool has(List<String> ks) => ks.any((k) => b.contains(k));
  if (has([
    "taksi", "taxi", "yandex go", "yandexgo", "yango", "bolt", "uklon",
    "mytaxi", "my taxi", "fasten", "uber", "indriver", "indrive",
    "benzin", "zapravka", "neft", "metro", "parking", "avtobus"
  ])) {
    return "Transport";
  }
  if (has([
    "uzum", "wildberries", "wb.ru", "aliexpress", "ozon", "olcha",
    "asaxiy", "mediapark", "texnomart", "zoodmall", "alif", "temu"
  ])) {
    return "Marketplace";
  }
  if (has([
    "wolt", "express24", "express 24", "glovo", "bringo", "chopar",
    "kafe", "cafe", "restoran", "kfc", "evos", "oqtepa", "food",
    "maxway", "max way", "bellissimo", "les ailes"
  ])) {
    return "Ovqatlanish";
  }
  if (has([
    "market", "magazin", "supermarket", "korzinka", "makro", "havas",
    "oziq", "bozor"
  ])) {
    return "Oziq-ovqat";
  }
  if (has([
    "uzmobile", "beeline", "ucell", "mobiuz", "humans", "internet",
    "aloqa", "perfectum", "uztelecom"
  ])) {
    return "Aloqa";
  }
  if (has([
    "kommunal", "gaz", "suv", "svet", "hudud", "elektr", "issiqlik"
  ])) {
    return "Kommunal";
  }
  if (has([
    "netflix", "spotify", "youtube", "kinopoisk", "premier", "megogo",
    "steam", "google play", "playmarket", "app store", "appstore"
  ])) {
    return "Ko'ngilochar";
  }
  if (has(["apteka", "dori", "clinic", "shifo", "poliklinika"])) {
    return "Sog'liq";
  }
  if (has(["perevod", "p2p", "otkazma", "transfer", "pul o'tkaz"])) {
    return "O'tkazma";
  }
  return "Xaridlar";
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'JARVIS',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF05070D),
          colorScheme: const ColorScheme.dark(primary: Color(0xFF31C9FF)),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  final _stt = stt.SpeechToText();
  final _tts = FlutterTts();
  final _audio = AudioPlayer();
  late final AnimationController _anim;
  String _key = "";
  String _voice = "Charon";
  String _ttsLang = "ru-RU";
  final _history = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _subs = [];
  final List<Map<String, String>> _chat = [];
  final ScrollController _scroll = ScrollController();
  JState _state = JState.idle;
  bool _handsFree = false;
  bool _sttReady = false;
  bool _cloudVoice = true;
  bool _wakeMode = false;
  bool _lockEnabled = false;
  bool _unlocked = true;
  String _lastWords = "";
  bool _processed = false;
  final _rec = AudioRecorder();
  bool _recording = false;
  String? _recPath;
  final _auth = LocalAuthentication();
  final _textCtl = TextEditingController();
  String _userText = "";
  String _botText = "Salom! Men JARVIS. Sharni bosib TURIB gapiring, qo'yvorsangiz bajaraman. Yoki pastdan yozing.";

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
    _audio.onPlayerComplete.listen((_) => _afterSpeak());
    _initTts();
    _load();
    _loadSubs();
    _loadTxns();
    _initNotif();
  }

  Future<void> _initTts() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      for (final l in ["ru-RU", "en-US", "uz-UZ"]) {
        try {
          if (await _tts.isLanguageAvailable(l) == true) {
            _ttsLang = l;
            break;
          }
        } catch (_) {}
      }
      await _tts.setLanguage(_ttsLang);
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
    } catch (_) {}
    _tts.setCompletionHandler(() => _afterSpeak());
    _tts.setErrorHandler((m) => _afterSpeak());
  }

  Future<void> _tryUnlock() async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: "JARVIS'ni ochish uchun tasdiqlang",
        options: const AuthenticationOptions(
            biometricOnly: false, stickyAuth: true),
      );
      if (ok) {
        setState(() => _unlocked = true);
        if (_key.isEmpty) {
          _settings();
        }
      }
    } catch (e) {
      setState(() => _botText = "Qulf ochilmadi. Qayta urining.");
    }
  }

  bool _hasWake(String t) {
    final l = t.toLowerCase();
    return l.contains("jarvis") ||
        l.contains("javis") ||
        l.contains("jarvi") ||
        l.contains("jervis") ||
        l.contains("djarvis");
  }

  void _afterSpeak() {
    _set(JState.idle);
  }

  // --- Gemini bulut TTS: matnni erkak ovozda audio qilib qaytaradi ---
  Future<Uint8List?> _geminiTts(String text) async {
    if (_key.isEmpty || text.trim().isEmpty) return null;
    for (final m in ttsModels) {
      try {
        final url = Uri.parse(
            "https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent?key=$_key");
        final body = jsonEncode({
          "contents": [
            {"parts": [{"text": text}]}
          ],
          "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {
              "voiceConfig": {
                "prebuiltVoiceConfig": {"voiceName": _voice}
              }
            }
          }
        });
        final r = await http.post(url,
            headers: {"Content-Type": "application/json"}, body: body);
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final part = j["candidates"]?[0]?["content"]?["parts"]?[0];
          final data = part?["inlineData"]?["data"];
          if (data != null) {
            int rate = 24000;
            final mime = (part["inlineData"]["mimeType"] ?? "").toString();
            final mm = RegExp(r"rate=(\d+)").firstMatch(mime);
            if (mm != null) rate = int.parse(mm.group(1)!);
            return _pcmToWav(base64Decode(data), rate);
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Uint8List _pcmToWav(Uint8List pcm, int sampleRate) {
    final int byteRate = sampleRate * 2;
    final int dataLen = pcm.length;
    final b = BytesBuilder();
    void s(String x) => b.add(ascii.encode(x));
    void u32(int v) =>
        b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
    s("RIFF");
    u32(36 + dataLen);
    s("WAVE");
    s("fmt ");
    u32(16);
    u16(1);
    u16(1);
    u32(sampleRate);
    u32(byteRate);
    u16(2);
    u16(16);
    s("data");
    u32(dataLen);
    b.add(pcm);
    return b.toBytes();
  }

  Future<void> _speak(String text) async {
    if (text.trim().isEmpty) {
      _afterSpeak();
      return;
    }
    // 1) Bulut ovozi (erkak, kafolatlangan tovush)
    if (_cloudVoice) {
      try {
        final wav = await _geminiTts(text);
        if (wav != null) {
          await _audio.stop();
          await _audio.play(BytesSource(wav, mimeType: "audio/wav"));
          return; // tugashi onPlayerComplete orqali
        }
      } catch (_) {}
    }
    // 2) Zaxira: telefon TTS
    try {
      await _tts.stop();
      await _tts.setLanguage(_ttsLang);
      await _tts.setVolume(1.0);
      await _tts.speak(text);
    } catch (_) {
      _afterSpeak();
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _key = p.getString("gemini_key") ?? "";
    _voice = p.getString("tts_voice") ?? "Charon";
    _cloudVoice = p.getBool("cloud_voice") ?? true;
    _wakeMode = p.getBool("wake_mode") ?? false;
    _lockEnabled = p.getBool("lock_enabled") ?? false;
    _unlocked = !_lockEnabled;
    if (mounted) setState(() {});
    if (_lockEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryUnlock());
      return;
    }
    if (_key.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _settings());
    }
  }

  // --- Hisob-kitob (pullik ilovalar / obunalar) ---
  Future<void> _loadSubs() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString("subs");
    final list = <Map<String, dynamic>>[];
    if (raw != null) {
      try {
        final d = jsonDecode(raw);
        if (d is List) {
          for (final e in d) {
            list.add(Map<String, dynamic>.from(e));
          }
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _subs = list);
  }

  double _money2(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? "") ?? 0;
  String _money(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  // Obunalarning qisqa xulosasini AI'ga uzatish uchun matn
  String _financeSummary() {
    if (_subs.isEmpty) return "";
    final per = <String, double>{};
    final items = <String>[];
    for (final s in _subs) {
      final name = (s["name"] ?? "Ilova").toString();
      final amt = _money2(s["amount"]);
      final cur = (s["currency"] ?? "UZS").toString();
      final cycle = (s["cycle"] ?? "month").toString();
      final monthly = cycle == "year" ? amt / 12 : amt;
      per[cur] = (per[cur] ?? 0) + monthly;
      items.add("$name ${_money(amt)} $cur/${cycle == "year" ? "yil" : "oy"}");
    }
    final totals =
        per.entries.map((e) => "${_money(e.value)} ${e.key}/oy").join(" + ");
    return "${items.join(", ")}. Jami: $totals";
  }

  // Dinamik system prompt: obuna ma'lumotini AI ko'radi
  String _sysPrompt() {
    final b = StringBuffer(systemPrompt);
    b.write(
        " hisob-kitob/obunalar/xarajat oynasini ochish uchun {\"action\":\"expenses\"} .");
    b.write(
        " moliya/bank karta kirim-chiqim va xarajat statistikasi uchun {\"action\":\"finance\"} .");
    b.write(
        " Agar foydalanuvchi xarajat yoki kirim aytsa, yoki bank hisoboti (vypiska) matnini joylashtirsa, ularni yoz: {\"action\":\"add_txns\",\"items\":[{\"amount\":50000,\"dir\":\"out\",\"cat\":\"Transport\",\"desc\":\"taksi\"}]} . dir faqat in yoki out. Bir nechta amaliyot bo'lsa hammasini items ichiga sol. Bunda boshqa matn yozma, faqat shu JSON. ");
    final fin = _financeSummary();
    if (fin.isNotEmpty) {
      b.write(" FOYDALANUVCHI OBUNALARI (pullik ilovalar): ");
      b.write(fin);
      b.write(
          " Agar foydalanuvchi xarajat, obuna yoki to'lov haqida so'rasa, shu ma'lumotdan hisoblab javob ber.");
    }
    final ff = _financeAiSummary();
    if (ff.isNotEmpty) b.write(" MOLIYA: " + ff);
    return b.toString();
  }

  // --- Moliya: bank SMS hisob-kitob (AI xulosasi uchun) ---
  List<Map<String, dynamic>> _txns = [];

  Future<void> _loadTxns() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString("txns");
    final list = <Map<String, dynamic>>[];
    if (raw != null) {
      try {
        final d = jsonDecode(raw);
        if (d is List) {
          for (final e in d) {
            list.add(Map<String, dynamic>.from(e));
          }
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _txns = list);
  }

  String _financeAiSummary() {
    if (_txns.isEmpty) return "";
    final now = DateTime.now();
    double inc = 0, exp = 0;
    final cats = <String, double>{};
    for (final t in _txns) {
      final d = DateTime.fromMillisecondsSinceEpoch(t["ts"] as int);
      if (d.year != now.year || d.month != now.month) continue;
      final a = (t["amount"] as num).toDouble();
      if (t["dir"] == "in") {
        inc += a;
      } else {
        exp += a;
        cats[t["cat"]] = (cats[t["cat"]] ?? 0) + a;
      }
    }
    final top = cats.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final tops = top.take(3).map((e) => "${e.key} ${_money(e.value)}").join(", ");
    return "Shu oy: kirim ${_money(inc)}, chiqim ${_money(exp)} so'm. Ko'p xarajat: $tops.";
  }

  Future<void> _saveKey(String k) async {
    final p = await SharedPreferences.getInstance();
    await p.setString("gemini_key", k);
    if (mounted) setState(() => _key = k);
  }

  Future<void> _selectVoice(String name) async {
    setState(() {
      _voice = name;
      _cloudVoice = true;
    });
    final p = await SharedPreferences.getInstance();
    await p.setString("tts_voice", name);
    await p.setBool("cloud_voice", true);
    await _speak("Salom, men JARVIS. Ovoz tanlandi.");
  }

  // --- Bildirishnoma (bank/to'lov ilovalari) avtomatik hisob-kitob ---
  StreamSubscription<ServiceNotificationEvent>? _notifSub;

  Future<void> _initNotif() async {
    try {
      final ok = await NotificationListenerService.isPermissionGranted();
      if (!ok) return;
      _notifSub?.cancel();
      _notifSub = NotificationListenerService.notificationsStream.listen((e) {
        if (e.hasRemoved == true) return;
        _handleNotif("${e.title} ${e.content}", e.packageName ?? "notif");
      });
    } catch (_) {}
  }

  Future<void> _handleNotif(String body, String pkg) async {
    final t = _parseFin(body, pkg, DateTime.now().millisecondsSinceEpoch);
    if (t == null) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString("txns");
    final list = <Map<String, dynamic>>[];
    if (raw != null) {
      try {
        final d = jsonDecode(raw);
        if (d is List) {
          for (final x in d) {
            list.add(Map<String, dynamic>.from(x));
          }
        }
      } catch (_) {}
    }
    final key = "${t["amount"]}_${body.hashCode}";
    for (final x in list) {
      if ("${x["amount"]}_${(x["raw"] ?? "").hashCode}" == key) return;
    }
    list.insert(0, t);
    while (list.length > 2000) {
      list.removeLast();
    }
    await p.setString("txns", jsonEncode(list));
  }

  Map<String, dynamic>? _parseFin(String body, String bank, int ts) {
    final b = body.toLowerCase();
    final cur = RegExp(
        r"(\d[\d  ]*(?:[.,]\d{1,2})?)\s*(so['ʻ‘’]?m|s[uў]m|uzs|сўм|сум)",
        caseSensitive: false);
    final ms = cur.allMatches(body).toList();
    if (ms.isEmpty) return null;
    double? amount;
    for (final m in ms) {
      final s0 = m.start;
      final ctx = body.substring(s0 - 28 < 0 ? 0 : s0 - 28, s0).toLowerCase();
      if (ctx.contains("balans") ||
          ctx.contains("dostupno") ||
          ctx.contains("qoldiq") ||
          ctx.contains("ostatok") ||
          ctx.contains("баланс") ||
          ctx.contains("доступно")) {
        continue;
      }
      var g = m.group(1)!.replaceAll(RegExp(r"[  ]"), "");
      if (RegExp(r"^\d+[.,]\d{1,2}$").hasMatch(g)) {
        g = g.replaceAll(",", ".");
      } else {
        g = g.replaceAll(RegExp(r"[.,]"), "");
      }
      final v = double.tryParse(g);
      if (v != null && v >= 1) {
        amount = v;
        break;
      }
    }
    if (amount == null || amount < 1 || amount > 2000000000) return null;
    const inKw = [
      "popoln", "kirim", "tushdi", "zachisl", "prixod", "приход",
      "пополн", "поступ", "kelib", "qaytar"
    ];
    const outKw = [
      "oplata", "pokupka", "spisan", "yechil", "chiqim", "to'lov",
      "снятие", "оплата", "покупка", "списан", "xarid", "perevod", "otpravl"
    ];
    final isIn = inKw.any((k) => b.contains(k));
    final isOut = outKw.any((k) => b.contains(k));
    final dir = isIn && !isOut ? "in" : "out";
    final cat = jarvisCategory(b, dir);
    return {
      "ts": ts,
      "amount": amount,
      "dir": dir,
      "cat": cat,
      "bank": bank,
      "raw": body
    };
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final XFile? x =
          await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final name = x.name.toLowerCase();
      final mime = x.mimeType ??
          (name.endsWith(".png")
              ? "image/png"
              : name.endsWith(".webp")
                  ? "image/webp"
                  : "image/jpeg");
      await _sendImage(bytes, mime);
    } catch (e) {
      setState(() => _botText = "Rasm ochilmadi: $e");
    }
  }

  void _pushI(String role, String text, String img) {
    setState(() => _chat.add({"role": role, "text": text, "img": img}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _sendImage(Uint8List bytes, String mime) async {
    final b64 = base64Encode(bytes);
    final caption = _textCtl.text.trim();
    _textCtl.clear();
    _pushI("user", caption, b64);
    _set(JState.thinking);
    final turn = <String, dynamic>{
      "role": "user",
      "parts": [
        {
          "inlineData": {"mimeType": mime, "data": b64}
        },
        {
          "text": caption.isEmpty
              ? "Bu rasmni o'qib javob ber. Agar bu chek yoki bank hisoboti bo'lsa, undagi barcha xarajat/kirimlarni {\"action\":\"add_txns\",\"items\":[...]} bilan yoz."
              : caption
        }
      ]
    };
    String reply;
    try {
      reply = await _geminiAudio(turn);
    } catch (e) {
      reply = "Kechirasiz, xato: $e";
    }
    _history.add({
      "role": "user",
      "parts": [
        {"text": caption.isEmpty ? "(rasm yubordim)" : caption}
      ]
    });
    _trimHistory();
    await _afterReply(reply);
  }

  void _push(String role, String text) {
    if (text.trim().isEmpty) return;
    setState(() => _chat.add({"role": role, "text": text}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  void _pushA(String role, String text, String audio) {
    setState(() => _chat.add({"role": role, "text": text, "audio": audio}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _playAudio(String path) async {
    try {
      await _tts.stop();
      await _audio.stop();
      await _audio.play(DeviceFileSource(path));
    } catch (e) {
      setState(() => _botText = "Ovoz ijro etilmadi: $e");
    }
  }

  Future<void> _editMessage(int index) async {
    final ctl = TextEditingController(text: _chat[index]["text"] ?? "");
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B2A),
        title: const Text("Xabarni tahrirlash",
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "Matn...",
            hintStyle: TextStyle(color: Colors.white30),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Bekor", style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text("Saqlash",
                style: TextStyle(color: Color(0xFF31C9FF))),
          ),
        ],
      ),
    );
    if (res != null && res.isNotEmpty) {
      setState(() => _chat[index]["text"] = res);
    }
  }

  void _set(JState s) {
    if (mounted) setState(() => _state = s);
  }

  Future<void> _micToggle() async {
    if (_key.isEmpty) {
      _settings();
      return;
    }
    if (_handsFree) {
      _handsFree = false;
      await _stt.stop();
      await _tts.stop();
      await _audio.stop();
      _set(JState.idle);
    } else {
      _handsFree = true;
      await _startListening();
    }
  }

  Future<void> _orbTap() async {
    if (_key.isEmpty) {
      _settings();
      return;
    }
    if (_state != JState.idle) {
      await _stt.stop();
      await _tts.stop();
      await _audio.stop();
      _set(JState.idle);
    } else {
      await _startListening();
    }
  }

  Future<void> _startListening() async {
    if (_stt.isListening) return;
    var mic = await Permission.microphone.status;
    if (!mic.isGranted) {
      mic = await Permission.microphone.request();
    }
    if (!mic.isGranted) {
      setState(() => _botText =
          "Mikrofonga ruxsat bering: Sozlamalar > Ilovalar > JARVIS > Ruxsatlar > Mikrofon. Yoki pastdan yozib buyruq bering.");
      _set(JState.idle);
      return;
    }
    if (!_sttReady) {
      _sttReady = await _stt.initialize(onError: (e) {}, onStatus: (s) {
        if (s == "done" || s == "notListening") {
          if (!_processed && _lastWords.trim().isNotEmpty) {
            _processed = true;
            _handle(_lastWords.trim());
          } else if (_handsFree && _state == JState.listening) {
            Future.delayed(const Duration(milliseconds: 400), _startListening);
          }
        }
      });
    }
    if (!_sttReady) {
      setState(() => _botText = "Mikrofonga ruxsat bering.");
      _set(JState.idle);
      return;
    }
    _set(JState.listening);
    setState(() => _userText = "");
    _processed = false;
    _lastWords = "";
    await _stt.listen(
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 2),
      onResult: (r) {
        _lastWords = r.recognizedWords;
        setState(() => _userText = r.recognizedWords);
        if (r.finalResult && !_processed) {
          _processed = true;
          final t = r.recognizedWords.trim();
          if (t.isNotEmpty) _handle(t);
        }
      },
    );
  }

  String _stripWake(String t) {
    final low = t.toLowerCase();
    for (final w in ["hey jarvis", "hey jarvist", "jarvis", "jarvist", "javis"]) {
      if (low.startsWith(w)) return t.substring(w.length).trim();
    }
    return t;
  }

  Future<void> _handle(String raw) async {
    if (_handsFree && _wakeMode && !_hasWake(raw)) {
      _startListening();
      return;
    }
    _process(_stripWake(raw));
  }

  Future<void> _process(String text) async {
    if (text.isEmpty) return;
    _push("user", text);
    setState(() => _userText = text);
    _set(JState.thinking);
    _history.add({"role": "user", "parts": [{"text": text}]});
    String reply;
    try {
      reply = await _gemini();
    } catch (e) {
      reply = "Kechirasiz, xato: $e";
    }
    await _afterReply(reply);
  }

  void _trimHistory() {
    while (_history.length > 8) {
      _history.removeAt(0);
    }
  }

  Future<void> _afterReply(String reply) async {
    _history.add({"role": "model", "parts": [{"text": reply}]});
    _trimHistory();
    final act = _tryAction(reply);
    if (act != null) {
      await _doAction(act);
    } else {
      setState(() => _botText = reply);
      _push("bot", reply);
      _set(JState.speaking);
      await _speak(reply);
    }
  }

  Future<void> _startRec() async {
    if (_recording || _state == JState.thinking) return;
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _botText = "Mikrofonga ruxsat bering.");
        return;
      }
      await _tts.stop();
      await _audio.stop();
      final dir = await getTemporaryDirectory();
      _recPath = "${dir.path}/cmd.wav";
      await _rec.start(
        const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1),
        path: _recPath!,
      );
      _recording = true;
      setState(() => _userText = "");
      _set(JState.listening);
    } catch (e) {
      _recording = false;
      setState(() => _botText = "Yozib bo'lmadi: $e");
    }
  }

  Future<void> _stopRecAndSend() async {
    if (!_recording) return;
    _recording = false;
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    if (path == null) {
      _set(JState.idle);
      return;
    }
    _set(JState.thinking);
    try {
      final pcm = await File(path).readAsBytes();
      if (pcm.length < 3000) {
        _set(JState.idle);
        setState(() => _botText =
            "Eshitmadim (yozildi: ${pcm.length} bayt). Mikrofonni bosib, biroz uzunroq gapiring.");
        return;
      }
final wav = _pcmToWav(pcm, 16000);
      String savedPath = "";
      try {
        final docs = await getApplicationDocumentsDirectory();
        savedPath =
            "${docs.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav";
        await File(savedPath).writeAsBytes(wav);
      } catch (_) {
        savedPath = "";
      }
      _pushA("user", "🎤 Ovozli xabar", savedPath);
      final b64 = base64Encode(wav);
      final audioTurn = <String, dynamic>{
        "role": "user",
        "parts": [
          {"inlineData": {"mimeType": "audio/wav", "data": b64}},
          {"text": "(ovozli buyruq)"}
        ]
      };
      String reply;
      try {
        reply = await _geminiAudio(audioTurn);
      } catch (e) {
        reply = "Kechirasiz, xato: $e";
      }
      _history.add(audioTurn);
      _trimHistory();
      await _afterReply(reply);
    } catch (e) {
      _set(JState.idle);
      setState(() => _botText = "Xato: $e");
    }
  }

  Future<String> _geminiAudio(Map<String, dynamic> audioTurn) async {
    final contents = List<Map<String, dynamic>>.from(_history)..add(audioTurn);
    Object? lastErr;
    for (final m in geminiModels) {
      final url = Uri.parse(
          "https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent?key=$_key");
      final body = jsonEncode({
        "system_instruction": {"parts": [{"text": _sysPrompt()}]},
        "contents": contents,
        "generationConfig": {"temperature": 0.6, "maxOutputTokens": 1024}
      });
      final r = await http.post(url,
          headers: {"Content-Type": "application/json"}, body: body);
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final parts = j["candidates"]?[0]?["content"]?["parts"];
        if (parts != null) {
          final sb = StringBuffer();
          for (final p in parts) {
            if (p["text"] != null) sb.write(p["text"]);
          }
          return sb.toString().trim();
        }
        return "(bo'sh javob)";
      }
      lastErr = "HTTP ${r.statusCode}";
    }
    throw Exception(lastErr ?? "model topilmadi");
  }

  Map<String, dynamic>? _tryAction(String reply) {
    var s = reply.trim();
    if (s.startsWith("```")) {
      s = s.replaceAll("```json", "").replaceAll("```", "").trim();
    }
    if (!s.startsWith("{")) return null;
    try {
      final m = jsonDecode(s);
      if (m is Map && m["action"] != null) {
        return Map<String, dynamic>.from(m);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _doAction(Map<String, dynamic> a) async {
    final action = (a["action"] ?? "").toString();
    Uri? uri;
    AndroidIntent? intent;
    String say = "Bajarildi.";
    String enc(dynamic v) => Uri.encodeComponent((v ?? "").toString());
    int intOf(dynamic v, int d) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? "") ?? d;
    }
    switch (action) {
      case "expenses":
        _push("bot", "Hisob-kitob oynasini ochyapman.");
        setState(() => _botText = "Hisob-kitob oynasini ochyapman.");
        _set(JState.idle);
        await Navigator.push(context,
            MaterialPageRoute(builder: (_) => const SubscriptionsPage()));
        await _loadSubs();
        return;
      case "finance":
        _push("bot", "Moliya oynasini ochyapman.");
        setState(() => _botText = "Moliya oynasini ochyapman.");
        _set(JState.idle);
        await Navigator.push(context,
            MaterialPageRoute(builder: (_) => const FinancePage()));
        await _loadTxns();
        return;
      case "add_txns":
        {
          final items = a["items"];
          int n = 0;
          if (items is List) {
            final p = await SharedPreferences.getInstance();
            final raw = p.getString("txns");
            final list = <Map<String, dynamic>>[];
            if (raw != null) {
              try {
                final d = jsonDecode(raw);
                if (d is List) {
                  for (final x in d) {
                    list.add(Map<String, dynamic>.from(x));
                  }
                }
              } catch (_) {}
            }
            final now = DateTime.now().millisecondsSinceEpoch;
            for (final it in items) {
              try {
                final m = Map<String, dynamic>.from(it);
                final amt = (m["amount"] is num)
                    ? (m["amount"] as num).toDouble()
                    : double.tryParse(
                            "${m["amount"]}".replaceAll(RegExp(r"[^0-9.]"), "")) ??
                        0;
                if (amt <= 0) continue;
                list.insert(0, {
                  "ts": now,
                  "amount": amt,
                  "dir": (m["dir"] == "in") ? "in" : "out",
                  "cat": (m["cat"] ??
                          (m["dir"] == "in" ? "Kirim" : "Xaridlar"))
                      .toString(),
                  "bank": "AI",
                  "raw": (m["desc"] ?? "").toString(),
                });
                n++;
              } catch (_) {}
            }
            await p.setString("txns", jsonEncode(list));
            await _loadTxns();
          }
          _push("bot", "$n ta amaliyot Moliyaga yozildi.");
          setState(() => _botText = "$n ta amaliyot yozildi.");
          _set(JState.idle);
          return;
        }
      case "call":
        uri = Uri.parse("tel:${a["number"]}");
        say = "${a["number"]} raqamiga qo'ng'iroq ochyapman.";
        break;
      case "sms":
        uri = Uri.parse("sms:${a["number"]}?body=${enc(a["message"])}");
        say = "SMS oynasini ochyapman.";
        break;
      case "search":
        uri = Uri.parse("https://www.google.com/search?q=${enc(a["query"])}");
        say = "Google'da qidiryapman.";
        break;
      case "youtube":
        uri = Uri.parse("https://www.youtube.com/results?search_query=${enc(a["query"])}");
        say = "YouTube'da qidiryapman.";
        break;
      case "maps":
        uri = Uri.parse("https://www.google.com/maps/search/?api=1&query=${enc(a["query"])}");
        say = "Xaritada ochyapman.";
        break;
      case "open":
        uri = Uri.tryParse((a["url"] ?? "").toString());
        say = "Ochyapman.";
        break;
      case "telegram":
        final msg = (a["message"] ?? "").toString();
        final un = (a["username"] ?? "").toString().replaceAll("@", "");
        if (msg.isNotEmpty) {
          intent = AndroidIntent(
            action: "android.intent.action.SEND",
            type: "text/plain",
            arguments: <String, dynamic>{"android.intent.extra.TEXT": msg},
          );
          say = "Xabar tayyor - Telegram va odamni tanlang.";
        } else if (un.isNotEmpty) {
          intent = AndroidIntent(
            action: "android.intent.action.VIEW",
            data: "tg://resolve?domain=$un",
          );
          say = "Telegramda $un chatini ochyapman.";
        } else {
          uri = Uri.parse("https://t.me");
          say = "Telegramni ochyapman.";
        }
        break;
      case "alarm":
        intent = AndroidIntent(
          action: "android.intent.action.SET_ALARM",
          arguments: <String, dynamic>{
            "android.intent.extra.alarm.HOUR": intOf(a["hour"], 8),
            "android.intent.extra.alarm.MINUTES": intOf(a["minute"], 0),
            "android.intent.extra.alarm.MESSAGE": (a["message"] ?? "JARVIS").toString(),
            "android.intent.extra.alarm.SKIP_UI": false,
          },
        );
        say = "Budilnik qo'ydim.";
        break;
      case "timer":
        intent = AndroidIntent(
          action: "android.intent.action.SET_TIMER",
          arguments: <String, dynamic>{
            "android.intent.extra.alarm.LENGTH": intOf(a["seconds"], 60),
            "android.intent.extra.alarm.MESSAGE": (a["message"] ?? "JARVIS").toString(),
            "android.intent.extra.alarm.SKIP_UI": true,
          },
        );
        say = "Taymer qo'ydim.";
        break;
      case "music":
        intent = AndroidIntent(
          action: "android.media.action.MEDIA_PLAY_FROM_SEARCH",
          arguments: <String, dynamic>{"query": (a["query"] ?? "").toString()},
        );
        say = "Musiqa qo'yyapman.";
        break;
      case "calendar":
        intent = AndroidIntent(
          action: "android.intent.action.INSERT",
          type: "vnd.android.cursor.item/event",
          arguments: <String, dynamic>{"title": (a["title"] ?? "").toString()},
        );
        say = "Kalendarga qo'shyapman.";
        break;
      default:
        say = (a["text"] ?? "Bajarildi.").toString();
    }
    setState(() => _botText = say);
    try {
      if (intent != null) {
        await intent.launch();
      } else if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      say = "Bajarolmadim: $e";
      setState(() => _botText = say);
    }
    _push("bot", say);
    _set(JState.speaking);
    await _speak(say);
  }

  Future<String> _gemini() async {
    Object? lastErr;
    for (final m in geminiModels) {
      final url = Uri.parse(
          "https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent?key=$_key");
      final body = jsonEncode({
        "system_instruction": {"parts": [{"text": _sysPrompt()}]},
        "contents": _history,
        "generationConfig": {"temperature": 0.6, "maxOutputTokens": 1024}
      });
      final r = await http.post(url,
          headers: {"Content-Type": "application/json"}, body: body);
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final parts = j["candidates"]?[0]?["content"]?["parts"];
        if (parts != null) {
          final sb = StringBuffer();
          for (final p in parts) {
            if (p["text"] != null) sb.write(p["text"]);
          }
          return sb.toString().trim();
        }
        return "(bo'sh javob)";
      }
      lastErr = "HTTP ${r.statusCode}";
    }
    throw Exception(lastErr ?? "model topilmadi");
  }

  void _voicePicker() {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF111826),
        title: const Text("Erkak ovozni tanlang"),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text("Gemini bulut ovozi - o'zbek/rus/ingliz o'qiydi",
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
              ),
              for (final v in maleVoices)
                ListTile(
                  dense: true,
                  title: Text(v, style: const TextStyle(fontSize: 14)),
                  trailing: v == _voice
                      ? const Icon(Icons.check, color: Color(0xFF31C9FF))
                      : const Icon(Icons.volume_up, color: Colors.white24, size: 18),
                  onTap: () {
                    Navigator.pop(c);
                    _selectVoice(v);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text("Yopish")),
        ],
      ),
    );
  }

  void _settings() {
    final kc = TextEditingController(text: _key);
    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          backgroundColor: const Color(0xFF111826),
          title: const Text("Sozlamalar"),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: kc,
              decoration: const InputDecoration(
                  labelText: "Gemini API key", hintText: "AIza..."),
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text("Bulut ovozi (erkak)", style: TextStyle(fontSize: 13)),
              subtitle: Text(_cloudVoice ? "Yoniq - $_voice" : "O'chiq (telefon ovozi)",
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
              value: _cloudVoice,
              onChanged: (v) async {
                final p = await SharedPreferences.getInstance();
                await p.setBool("cloud_voice", v);
                setState(() => _cloudVoice = v);
                setD(() {});
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text("\"Jarvis\" bilan chaqirish", style: TextStyle(fontSize: 13)),
              subtitle: const Text("Shovqinda faqat 'Jarvis...' ga javob beradi",
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
              value: _wakeMode,
              onChanged: (v) async {
                final p = await SharedPreferences.getInstance();
                await p.setBool("wake_mode", v);
                setState(() => _wakeMode = v);
                setD(() {});
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text("Ilova qulfi (yuz/barmoq/parol)", style: TextStyle(fontSize: 13)),
              subtitle: const Text("Ochilganda telefon qulfini so'raydi",
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
              value: _lockEnabled,
              onChanged: (v) async {
                final p = await SharedPreferences.getInstance();
                await p.setBool("lock_enabled", v);
                setState(() {
                  _lockEnabled = v;
                  _unlocked = true;
                });
                setD(() {});
              },
            ),
            Row(children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _speak("Salom, men JARVIS. Ovoz sinovi."),
                  icon: const Icon(Icons.volume_up, size: 18),
                  label: const Text("Sinash"),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.pop(c);
                    _voicePicker();
                  },
                  icon: const Icon(Icons.record_voice_over, size: 18),
                  label: const Text("Ovoz"),
                ),
              ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text("Bekor")),
            ElevatedButton(
              onPressed: () {
                _saveKey(kc.text.trim());
                Navigator.pop(c);
              },
              child: const Text("Saqlash"),
            ),
          ],
        ),
      ),
    );
  }

  String get _statusLabel {
    switch (_state) {
      case JState.listening:
        return "Tinglayapman...";
      case JState.thinking:
        return "O'ylayapman...";
      case JState.speaking:
        return "Gapiryapman...";
      default:
        return "Bosib turib gapiring";
    }
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    _anim.dispose();
    _audio.dispose();
    _textCtl.dispose();
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_lockEnabled && !_unlocked) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock, size: 64, color: Color(0xFF31C9FF)),
              const SizedBox(height: 16),
              const Text("JARVIS qulflangan",
                  style: TextStyle(fontSize: 18, color: Colors.white)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _tryUnlock,
                icon: const Icon(Icons.fingerprint),
                label: const Text("Ochish"),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E17),
        elevation: 0,
        title: const Text("J A R V I S",
            style: TextStyle(
                letterSpacing: 4, fontWeight: FontWeight.w600, fontSize: 16)),
        actions: [
          IconButton(
              tooltip: "Moliya",
              onPressed: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const FinancePage()));
                await _loadTxns();
              },
              icon: const Icon(Icons.pie_chart_outline, color: Colors.white70)),
          IconButton(
              tooltip: "Obunalar",
              onPressed: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SubscriptionsPage()));
                await _loadSubs();
              },
              icon: const Icon(Icons.account_balance_wallet_outlined,
                  color: Colors.white70)),
          IconButton(
              onPressed: _settings,
              icon: const Icon(Icons.settings, color: Colors.white70)),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: _chat.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 96,
                            height: 96,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                  colors: [Color(0xFF31C9FF), Color(0xFF0A2A3F)]),
                            ),
                            child: const Icon(Icons.auto_awesome,
                                size: 42, color: Colors.white),
                          ),
                          const SizedBox(height: 18),
                          const Text("Salom! Men JARVIS.",
                              style:
                                  TextStyle(color: Colors.white, fontSize: 18)),
                          const SizedBox(height: 6),
                          const Text(
                              "Yozing yoki mikrofonni bosib gapiring.",
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 13)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      itemCount: _chat.length,
                      itemBuilder: (c, i) {
                        final m = _chat[i];
                        final me = m["role"] == "user";
                        return Align(
                          alignment:
                              me ? Alignment.centerRight : Alignment.centerLeft,
                          child: GestureDetector(
                            onLongPress: (me &&
                                    (m["audio"] ?? "").isEmpty &&
                                    (m["text"] ?? "").isNotEmpty)
                                ? () => _editMessage(i)
                                : null,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.78),
                              decoration: BoxDecoration(
                                color: me
                                    ? const Color(0xFF1E6BFF)
                                    : const Color(0xFF141B2A),
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: Radius.circular(me ? 16 : 4),
                                  bottomRight: Radius.circular(me ? 4 : 16),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if ((m["img"] ?? "").isNotEmpty)
                                    ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Image.memory(
                                            base64Decode(m["img"]!),
                                            fit: BoxFit.cover)),
                                  if ((m["audio"] ?? "").isNotEmpty)
                                    InkWell(
                                      onTap: () => _playAudio(m["audio"]!),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: const [
                                          Icon(Icons.play_circle_fill,
                                              color: Colors.white, size: 26),
                                          SizedBox(width: 8),
                                          Text("Ovozli xabar",
                                              style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14)),
                                        ],
                                      ),
                                    )
                                  else if ((m["text"] ?? "").isNotEmpty)
                                    Padding(
                                      padding: EdgeInsets.only(
                                          top: (m["img"] ?? "").isNotEmpty
                                              ? 6
                                              : 0),
                                      child: Text(m["text"] ?? "",
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15)),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_state == JState.thinking)
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(left: 20, bottom: 6),
                  child: Text("JARVIS yozmoqda...",
                      style:
                          TextStyle(color: Color(0xFF31C9FF), fontSize: 12)),
                ),
              ),
            if (_state == JState.listening)
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(left: 20, bottom: 6),
                  child: Text("Tinglayapman...",
                      style:
                          TextStyle(color: Color(0xFF2BF5C0), fontSize: 12)),
                ),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              color: const Color(0xFF0A0E17),
              child: Row(children: [
                IconButton(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined,
                      color: Colors.white70),
                ),
                Expanded(
                  child: TextField(
                    controller: _textCtl,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: "JARVIS'ga yozing...",
                      hintStyle: const TextStyle(color: Colors.white30),
                      filled: true,
                      fillColor: const Color(0xFF141B2A),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (t) {
                      _textCtl.clear();
                      if (t.trim().isNotEmpty) _process(t.trim());
                    },
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTapDown: (_) => _startRec(),
                  onTapUp: (_) => _stopRecAndSend(),
                  onTapCancel: () => _stopRecAndSend(),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _recording
                          ? const Color(0xFF17384A)
                          : const Color(0xFF1E6BFF),
                    ),
                    child: Icon(_recording ? Icons.stop : Icons.mic,
                        color: Colors.white, size: 24),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () {
                    final t = _textCtl.text.trim();
                    _textCtl.clear();
                    if (t.isNotEmpty) _process(t);
                  },
                  icon: const Icon(Icons.send, color: Color(0xFF31C9FF)),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== HISOB-KITOB / OBUNALAR =====================
class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key});
  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  List<Map<String, dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString("subs");
    final list = <Map<String, dynamic>>[];
    if (raw != null) {
      try {
        final d = jsonDecode(raw);
        if (d is List) {
          for (final e in d) {
            list.add(Map<String, dynamic>.from(e));
          }
        }
      } catch (_) {}
    }
    setState(() => _subs = list);
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString("subs", jsonEncode(_subs));
  }

  double _amt(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? "") ?? 0;
  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
  double _monthly(Map s) {
    final amt = _amt(s["amount"]);
    return (s["cycle"] == "year") ? amt / 12 : amt;
  }

  Map<String, double> _perCurrencyMonthly() {
    final m = <String, double>{};
    for (final s in _subs) {
      final c = (s["currency"] ?? "UZS").toString();
      m[c] = (m[c] ?? 0) + _monthly(s);
    }
    return m;
  }

  void _edit([int? idx]) {
    final s = idx != null
        ? _subs[idx]
        : {"name": "", "amount": 0, "currency": "UZS", "cycle": "month", "day": 1};
    final nameC = TextEditingController(text: (s["name"] ?? "").toString());
    final amtC = TextEditingController(
        text: _amt(s["amount"]) == 0 ? "" : _fmt(_amt(s["amount"])));
    String cur = (s["currency"] ?? "UZS").toString();
    String cycle = (s["cycle"] ?? "month").toString();
    final dayC = TextEditingController(text: (s["day"] ?? 1).toString());
    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          backgroundColor: const Color(0xFF111826),
          title: Text(idx == null ? "Yangi obuna" : "Tahrirlash"),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameC,
                decoration: const InputDecoration(
                    labelText: "Ilova nomi (masalan Netflix)"),
              ),
              TextField(
                controller: amtC,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: "Narxi"),
              ),
              const SizedBox(height: 8),
              Row(children: [
                const Text("Valyuta:", style: TextStyle(color: Colors.white54)),
                const SizedBox(width: 10),
                DropdownButton<String>(
                  value: cur,
                  dropdownColor: const Color(0xFF111826),
                  items: const ["UZS", "USD", "EUR", "RUB"]
                      .map((e) =>
                          DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) => setD(() => cur = v ?? "UZS"),
                ),
                const Spacer(),
                DropdownButton<String>(
                  value: cycle,
                  dropdownColor: const Color(0xFF111826),
                  items: const [
                    DropdownMenuItem(value: "month", child: Text("oylik")),
                    DropdownMenuItem(value: "year", child: Text("yillik")),
                  ],
                  onChanged: (v) => setD(() => cycle = v ?? "month"),
                ),
              ]),
              TextField(
                controller: dayC,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: "To'lov kuni (1-31)"),
              ),
            ]),
          ),
          actions: [
            if (idx != null)
              TextButton(
                onPressed: () {
                  setState(() => _subs.removeAt(idx));
                  _save();
                  Navigator.pop(c);
                },
                child: const Text("O'chirish",
                    style: TextStyle(color: Colors.redAccent)),
              ),
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text("Bekor")),
            ElevatedButton(
              onPressed: () {
                final item = {
                  "name":
                      nameC.text.trim().isEmpty ? "Ilova" : nameC.text.trim(),
                  "amount": _amt(amtC.text.trim()),
                  "currency": cur,
                  "cycle": cycle,
                  "day": int.tryParse(dayC.text.trim()) ?? 1,
                };
                setState(() {
                  if (idx == null) {
                    _subs.add(item);
                  } else {
                    _subs[idx] = item;
                  }
                });
                _save();
                Navigator.pop(c);
              },
              child: const Text("Saqlash"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final perCur = _perCurrencyMonthly();
    return Scaffold(
      appBar: AppBar(
        title: const Text("Hisob-kitob · Obunalar"),
        backgroundColor: const Color(0xFF0B1220),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        backgroundColor: const Color(0xFF31C9FF),
        icon: const Icon(Icons.add, color: Colors.black),
        label: const Text("Qo'shish", style: TextStyle(color: Colors.black)),
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF111826),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Jami xarajat",
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
              if (perCur.isEmpty)
                const Text("Hali obuna qo'shilmagan",
                    style: TextStyle(color: Colors.white38)),
              for (final e in perCur.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    "${_fmt(e.value)} ${e.key} / oy   ·   ${_fmt(e.value * 12)} ${e.key} / yil",
                    style: const TextStyle(
                        color: Color(0xFF31C9FF),
                        fontSize: 18,
                        fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _subs.isEmpty
              ? const Center(
                  child: Text(
                      "Pastdagi tugma bilan pullik ilovalaringizni qo'shing",
                      style: TextStyle(color: Colors.white38)))
              : ListView.builder(
                  itemCount: _subs.length,
                  itemBuilder: (c, i) {
                    final s = _subs[i];
                    return ListTile(
                      leading: const Icon(Icons.subscriptions,
                          color: Color(0xFF31C9FF)),
                      title: Text((s["name"] ?? "").toString(),
                          style: const TextStyle(color: Colors.white)),
                      subtitle: Text(
                        "${_fmt(_amt(s["amount"]))} ${s["currency"]} / ${s["cycle"] == "year" ? "yil" : "oy"}  ·  ${s["day"] ?? 1}-kun",
                        style: const TextStyle(color: Colors.white54),
                      ),
                      trailing: Text("${_fmt(_monthly(s))} ${s["currency"]}/oy",
                          style: const TextStyle(color: Colors.white70)),
                      onTap: () => _edit(i),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// ===================== MOLIYA (bank SMS hisob-kitob) =====================
class FinancePage extends StatefulWidget {
  const FinancePage({super.key});
  @override
  State<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends State<FinancePage> {
  final Telephony _telephony = Telephony.instance;
  List<Map<String, dynamic>> _txns = [];
  bool _busy = false;
  String _msg = "";

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString("txns");
    final list = <Map<String, dynamic>>[];
    if (raw != null) {
      try {
        final d = jsonDecode(raw);
        if (d is List) {
          for (final e in d) {
            list.add(Map<String, dynamic>.from(e));
          }
        }
      } catch (_) {}
    }
    list.sort((a, b) => (b["ts"] as int).compareTo(a["ts"] as int));
    setState(() => _txns = list);
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString("txns", jsonEncode(_txns));
  }

  String _money(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  String _categorize(String b, String dir) => jarvisCategory(b, dir);

  double? _num(String s) {
    var g = s.replaceAll(RegExp(r"[  ]"), "");
    if (RegExp(r"^\d+[.,]\d{1,2}$").hasMatch(g)) {
      g = g.replaceAll(",", ".");
    } else {
      g = g.replaceAll(RegExp(r"[.,]"), "");
    }
    return double.tryParse(g);
  }

  Map<String, dynamic>? _parse(String addr, String body, int dateMs) {
    final b = body.toLowerCase();
    final cur = RegExp(
        r"(\d[\d  ]*(?:[.,]\d{1,2})?)\s*(so['ʻ‘’]?m|s[uў]m|uzs|сўм|сум)",
        caseSensitive: false);
    final ms = cur.allMatches(body).toList();
    if (ms.isEmpty) return null;
    double? amount;
    for (final m in ms) {
      final s0 = m.start;
      final ctx = body.substring(s0 - 28 < 0 ? 0 : s0 - 28, s0).toLowerCase();
      if (ctx.contains("balans") ||
          ctx.contains("dostupno") ||
          ctx.contains("qoldiq") ||
          ctx.contains("ostatok") ||
          ctx.contains("баланс") ||
          ctx.contains("доступно")) {
        continue;
      }
      final v = _num(m.group(1)!);
      if (v != null && v >= 1) {
        amount = v;
        break;
      }
    }
    amount ??= _num(ms.first.group(1)!);
    if (amount == null || amount < 1 || amount > 2000000000) return null;
    const inKw = [
      "popoln", "kirim", "tushdi", "zachisl", "prixod", "приход",
      "пополн", "поступ", "nachisl", "vozvrat", "qaytar"
    ];
    const outKw = [
      "oplata", "pokupka", "spisan", "yechil", "chiqim", "to'lov",
      "снятие", "оплата", "покупка",
      "списан", "xarid", "otpravl", "perevod", "olindi"
    ];
    final isIn = inKw.any((k) => b.contains(k));
    final isOut = outKw.any((k) => b.contains(k));
    final dir = isIn && !isOut ? "in" : "out";
    return {
      "ts": dateMs,
      "amount": amount,
      "dir": dir,
      "cat": _categorize(b, dir),
      "bank": addr,
      "raw": body
    };
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _msg = "SMS o'qilyapti...";
    });
    bool granted = false;
    try {
      granted = (await _telephony.requestPhoneAndSmsPermissions) ?? false;
    } catch (_) {}
    if (!granted) {
      final st = await Permission.sms.request();
      granted = st.isGranted;
    }
    if (!granted) {
      setState(() {
        _busy = false;
        _msg = "SMS ruxsati berilmadi. Sozlamalardan ruxsat bering.";
      });
      return;
    }
    List<SmsMessage> msgs = [];
    try {
      msgs = await _telephony.getInboxSms(
          columns: [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE]);
    } catch (e) {
      setState(() {
        _busy = false;
        _msg = "O'qib bo'lmadi: $e";
      });
      return;
    }
    final seen = _txns.map((t) => "${t["ts"]}_${t["amount"]}").toSet();
    int added = 0;
    for (final m in msgs) {
      final t = _parse(m.address ?? "", m.body ?? "",
          m.date ?? DateTime.now().millisecondsSinceEpoch);
      if (t == null) continue;
      final k = "${t["ts"]}_${t["amount"]}";
      if (seen.contains(k)) continue;
      seen.add(k);
      _txns.add(t);
      added++;
    }
    _txns.sort((a, b) => (b["ts"] as int).compareTo(a["ts"] as int));
    await _save();
    setState(() {
      _busy = false;
      _msg = "$added ta yangi amaliyot qo'shildi.";
    });
  }

  void _addManual() {
    final amtC = TextEditingController();
    final noteC = TextEditingController();
    String dir = "out";
    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          backgroundColor: const Color(0xFF111826),
          title: const Text("Qo'lda qo'shish"),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: amtC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: "Summa (so'm)"),
            ),
            TextField(
              controller: noteC,
              decoration: const InputDecoration(labelText: "Izoh (masalan: taksi)"),
            ),
            const SizedBox(height: 8),
            Row(children: [
              const Text("Turi:", style: TextStyle(color: Colors.white54)),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: dir,
                dropdownColor: const Color(0xFF111826),
                items: const [
                  DropdownMenuItem(value: "out", child: Text("Chiqim")),
                  DropdownMenuItem(value: "in", child: Text("Kirim")),
                ],
                onChanged: (v) => setD(() => dir = v ?? "out"),
              ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text("Bekor")),
            ElevatedButton(
              onPressed: () {
                final a = double.tryParse(amtC.text
                        .trim()
                        .replaceAll(" ", "")
                        .replaceAll(",", ".")) ??
                    0;
                if (a > 0) {
                  final note = noteC.text.trim();
                  _txns.insert(0, {
                    "ts": DateTime.now().millisecondsSinceEpoch,
                    "amount": a,
                    "dir": dir,
                    "cat": dir == "in" ? "Kirim" : _categorize(note.toLowerCase(), dir),
                    "bank": "Qo'lda",
                    "raw": note,
                  });
                  _save();
                  setState(() {});
                }
                Navigator.pop(c);
              },
              child: const Text("Saqlash"),
            ),
          ],
        ),
      ),
    );
  }

  Color _catColor(String cat) {
    const map = {
      "Transport": Color(0xFF31C9FF),
      "Marketplace": Color(0xFFB388FF),
      "Ovqatlanish": Color(0xFFFFB74D),
      "Oziq-ovqat": Color(0xFF2BF5C0),
      "Aloqa": Color(0xFF64B5F6),
      "Kommunal": Color(0xFF4DB6AC),
      "Ko'ngilochar": Color(0xFFFF8A65),
      "Sog'liq": Color(0xFFF06292),
      "O'tkazma": Color(0xFF9575CD),
      "Xaridlar": Color(0xFFFF6B6B),
    };
    return map[cat] ?? const Color(0xFFFF6B6B);
  }

  String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int x) => x < 10 ? "0$x" : "$x";
    return "${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}";
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    double inc = 0, exp = 0;
    final cats = <String, double>{};
    final month = _txns.where((t) {
      final d = DateTime.fromMillisecondsSinceEpoch(t["ts"] as int);
      return d.year == now.year && d.month == now.month;
    }).toList();
    for (final t in month) {
      final a = (t["amount"] as num).toDouble();
      if (t["dir"] == "in") {
        inc += a;
      } else {
        exp += a;
        cats[t["cat"]] = (cats[t["cat"]] ?? 0) + a;
      }
    }
    final catList = cats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Scaffold(
      appBar: AppBar(
        title: const Text("Moliya · Bank hisob-kitob"),
        backgroundColor: const Color(0xFF0B1220),
        actions: [
          IconButton(
            tooltip: "Hammasini tozalash",
            onPressed: () {
              showDialog(
                context: context,
                builder: (c) => AlertDialog(
                  backgroundColor: const Color(0xFF111826),
                  title: const Text("Tozalash"),
                  content: const Text("Barcha amaliyotlar o'chirilsinmi?"),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text("Bekor")),
                    ElevatedButton(
                      onPressed: () {
                        setState(() => _txns = []);
                        _save();
                        Navigator.pop(c);
                      },
                      child: const Text("Ha, o'chir"),
                    ),
                  ],
                ),
              );
            },
            icon: const Icon(Icons.delete_outline, color: Colors.white70),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addManual,
        backgroundColor: const Color(0xFF31C9FF),
        icon: const Icon(Icons.add, color: Colors.black),
        label: const Text("Qo'lda", style: TextStyle(color: Colors.black)),
      ),
      body: ListView(children: [
        Container(
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF111826),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Shu oy (${now.month}/${now.year})",
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text("Kirim",
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
                Text("+${_money(inc)}",
                    style: const TextStyle(
                        color: Color(0xFF2BF5C0),
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
              ]),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text("Chiqim",
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
                Text("-${_money(exp)}",
                    style: const TextStyle(
                        color: Color(0xFFFF6B6B),
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
              ]),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text("Balans",
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
                Text(_money(inc - exp),
                    style: const TextStyle(
                        color: Color(0xFF31C9FF),
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
              ]),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.sms),
              label: Text(_busy ? "..." : "SMS'dan yangilash"),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final ok =
                    await NotificationListenerService.requestPermission();
                setState(() => _msg = ok
                    ? "Bildirishnoma yoqildi. Ilovani qayta oching."
                    : "Ruxsat berilmadi.");
              },
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text("Bank ilovalari: avtomatik ulash"),
            ),
          ),
        ),
        if (_msg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(_msg,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
        if (catList.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Kategoriyalar (chiqim)",
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 6),
                for (final e in catList)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(e.key,
                                style: const TextStyle(color: Colors.white)),
                            Text(
                                "${_money(e.value)} so'm  ·  ${exp > 0 ? (e.value / exp * 100).round() : 0}%",
                                style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value:
                                exp > 0 ? (e.value / exp).clamp(0.0, 1.0) : 0,
                            minHeight: 6,
                            backgroundColor: const Color(0xFF1E2A3F),
                            valueColor: AlwaysStoppedAnimation<Color>(
                                _catColor(e.key)),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 4),
          child: Text("Amaliyotlar",
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ),
        if (_txns.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                  "SMS'dan yangilang yoki qo'lda qo'shing.\nBank xabarlari avtomatik o'qiladi va ajratiladi.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38)),
            ),
          ),
        for (final t in _txns.take(100))
          ListTile(
            dense: true,
            leading: Icon(
                t["dir"] == "in" ? Icons.south_west : Icons.north_east,
                color: t["dir"] == "in"
                    ? const Color(0xFF2BF5C0)
                    : const Color(0xFFFF6B6B)),
            title: Text((t["cat"] ?? "").toString(),
                style: const TextStyle(color: Colors.white)),
            subtitle: Text(
              "${_fmtDate(t["ts"] as int)}  ·  ${t["bank"] ?? ""}",
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            trailing: Text(
              "${t["dir"] == "in" ? "+" : "-"}${_money((t["amount"] as num).toDouble())}",
              style: TextStyle(
                  color: t["dir"] == "in"
                      ? const Color(0xFF2BF5C0)
                      : const Color(0xFFFF6B6B),
                  fontWeight: FontWeight.w600),
            ),
          ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class OrbPainter extends CustomPainter {
  final double t;
  final JState state;
  OrbPainter(this.t, this.state);

  Color get _c {
    switch (state) {
      case JState.thinking:
        return const Color(0xFF9B6CFF);
      case JState.speaking:
        return const Color(0xFF22F0C4);
      case JState.listening:
        return const Color(0xFF35CFFF);
      default:
        return const Color(0xFF2E86FF);
    }
  }

  void _belt(Canvas canvas, Offset center, double R, Color c, double spin,
      bool active, int belt, bool front) {
    const n = 28;
    final rBelt = R * (1.26 + belt * 0.24);
    final dir = belt.isEven ? 1.0 : -1.0;
    final tilt = 0.46 + belt * 0.08;
    for (int i = 0; i < n; i++) {
      final ang = (i / n) * 2 * pi + t * 2 * pi * spin * 0.5 * dir + belt * 1.3;
      final depth = sin(ang);
      if (front ? depth <= 0 : depth > 0) continue;
      final f = (depth + 1) / 2;
      final p = center + Offset(cos(ang) * rBelt, sin(ang) * rBelt * tilt);
      canvas.drawCircle(
          p,
          1.0 + 2.0 * f,
          Paint()
            ..color = c.withOpacity((0.28 + 0.72 * f) * (active ? 1.0 : 0.5))
            ..maskFilter = f > 0.75
                ? const MaskFilter.blur(BlurStyle.normal, 1.2)
                : null);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final R = size.shortestSide * 0.23;
    final c = _c;
    final active = state != JState.idle;
    final spin = state == JState.thinking ? 2.2 : (active ? 1.2 : 0.5);

    // 1) tashqi atmosfera nuri (bir necha qatlam)
    for (int g = 0; g < 3; g++) {
      final rr = R * (2.7 - g * 0.55);
      final op = ((active ? 0.18 : 0.11) - g * 0.035).clamp(0.0, 1.0);
      canvas.drawCircle(
          center,
          rr,
          Paint()
            ..shader = RadialGradient(
                    colors: [c.withOpacity(op), c.withOpacity(0.0)])
                .createShader(Rect.fromCircle(center: center, radius: rr)));
    }

    // 2) aylanuvchi arc-reactor yoylari (yadro ortida)
    final seg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4
      ..color = c.withOpacity(0.65);
    for (int sIdx = 0; sIdx < 3; sIdx++) {
      final b = t * 2 * pi * spin * (sIdx.isEven ? 1 : -1) + sIdx * 2.1;
      final rr = R * (1.55 + sIdx * 0.18);
      canvas.drawArc(
          Rect.fromCircle(center: center, radius: rr), b, 1.15, false, seg);
      canvas.drawArc(Rect.fromCircle(center: center, radius: rr), b + pi, 0.6,
          false, seg);
    }

    // 3) orqa zarra kamarlari (yadro ularni yopadi -> 3D his)
    for (int belt = 0; belt < 3; belt++) {
      _belt(canvas, center, R, c, spin, active, belt, false);
    }

    // 4) yadro: ko'p qatlamli yorug'lik + issiq markaz
    final pulse = 1 + 0.06 * sin(t * 2 * pi * (active ? 2.2 : 1.1));
    final coreR = R * pulse;
    canvas.drawCircle(
        center,
        coreR * 1.6,
        Paint()
          ..shader = RadialGradient(
                  colors: [c.withOpacity(0.55), c.withOpacity(0.0)])
              .createShader(
                  Rect.fromCircle(center: center, radius: coreR * 1.6)));
    canvas.drawCircle(
        center,
        coreR,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.white, Colors.white, c, c.withOpacity(0.0)],
            stops: const [0.0, 0.28, 0.72, 1.0],
          ).createShader(Rect.fromCircle(center: center, radius: coreR)));
    canvas.drawCircle(center, coreR * 0.42,
        Paint()..color = Colors.white.withOpacity(0.95));

    // 5) old zarra kamarlari (yadro ustida)
    for (int belt = 0; belt < 3; belt++) {
      _belt(canvas, center, R, c, spin, active, belt, true);
    }

    // 6) yupqa ekvator halqasi
    canvas.drawCircle(
        center,
        R * 1.12,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = Colors.white.withOpacity(0.16));
  }

  @override
  bool shouldRepaint(OrbPainter o) => o.t != t || o.state != state;
}

class EdgeGlowPainter extends CustomPainter {
  final double t;
  final JState state;
  EdgeGlowPainter(this.t, this.state);

  @override
  void paint(Canvas canvas, Size size) {
    final c = state == JState.thinking
        ? const Color(0xFF7B5CFF)
        : const Color(0xFF2BF5C0);
    final glow = 0.35 + 0.35 * (0.5 + 0.5 * sin(t * 2 * pi * 2));
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = c.withOpacity(glow)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect.deflate(4), const Radius.circular(18)), paint);
  }

  @override
  bool shouldRepaint(EdgeGlowPainter o) => o.t != t || o.state != state;
}
