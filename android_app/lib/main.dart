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
    "Foydalanuvchi qaysi tilda gapirsa (o'zbek, rus, ingliz) o'sha tilda javob ber. Standart til - o'zbek. "
    "Agar foydalanuvchi telefon amalini so'rasa, FAQAT bitta JSON qaytar (boshqa hech qanday matnsiz): "
    "qo'ng'iroq uchun {\"action\":\"call\",\"number\":\"+998...\"} ; "
    "SMS uchun {\"action\":\"sms\",\"number\":\"+998...\",\"message\":\"matn\"} ; "
    "Google qidiruv uchun {\"action\":\"search\",\"query\":\"...\"} ; "
    "YouTube uchun {\"action\":\"youtube\",\"query\":\"...\"} ; "
    "xarita uchun {\"action\":\"maps\",\"query\":\"joy\"} ; "
    "sayt/ilova ochish uchun {\"action\":\"open\",\"url\":\"https://...\"} ; "
    "Telegram xabar uchun {\"action\":\"telegram\",\"message\":\"matn\"} (kim ekanini foydalanuvchi tanlaydi) yoki {\"action\":\"telegram\",\"username\":\"nomi\"} (shu chatni ochadi) . "
    "Agar amal kerak bo'lmasa, oddiy matn bilan javob ber (JSONsiz).";

enum JState { idle, listening, thinking, speaking }

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
  JState _state = JState.idle;
  bool _handsFree = false;
  bool _sttReady = false;
  bool _cloudVoice = true;
  String _userText = "";
  String _botText = "Salom! Men JARVIS. Sharni bosing yoki \"Jarvis\" deng.";

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
    _audio.onPlayerComplete.listen((_) => _afterSpeak());
    _initTts();
    _load();
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

  void _afterSpeak() {
    if (_handsFree) {
      _startListening();
    } else {
      _set(JState.idle);
    }
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
    if (mounted) setState(() {});
    if (_key.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _settings());
    } else {
      _handsFree = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _startListening());
    }
  }

  Future<void> _saveKey(String k) async {
    final p = await SharedPreferences.getInstance();
    await p.setString("gemini_key", k);
    if (mounted) setState(() => _key = k);
    if (k.isNotEmpty) {
      _handsFree = true;
      _startListening();
    }
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

  void _set(JState s) {
    if (mounted) setState(() => _state = s);
  }

  Future<void> _toggle() async {
    if (_key.isEmpty) {
      _settings();
      return;
    }
    if (_state == JState.idle) {
      _handsFree = true;
      await _startListening();
    } else {
      _handsFree = false;
      await _stt.stop();
      await _tts.stop();
      await _audio.stop();
      _set(JState.idle);
    }
  }

  Future<void> _startListening() async {
    if (_stt.isListening) return;
    if (!_sttReady) {
      _sttReady = await _stt.initialize(onError: (e) {}, onStatus: (s) {
        if ((s == "done" || s == "notListening") &&
            _handsFree &&
            _state == JState.listening) {
          Future.delayed(const Duration(milliseconds: 500), _startListening);
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
    await _stt.listen(
      localeId: "uz_UZ",
      listenFor: const Duration(seconds: 25),
      pauseFor: const Duration(seconds: 4),
      onResult: (r) {
        setState(() => _userText = r.recognizedWords);
        if (r.finalResult) {
          final t = r.recognizedWords.trim();
          if (t.isNotEmpty) {
            _handle(t);
          }
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
    final text = _stripWake(raw);
    if (text.isEmpty) {
      if (_handsFree) _startListening();
      return;
    }
    setState(() => _userText = text);
    _set(JState.thinking);
    _history.add({"role": "user", "parts": [{"text": text}]});
    String reply;
    try {
      reply = await _gemini();
    } catch (e) {
      reply = "Kechirasiz, xato: $e";
    }
    _history.add({"role": "model", "parts": [{"text": reply}]});
    final act = _tryAction(reply);
    if (act != null) {
      await _doAction(act);
    } else {
      setState(() => _botText = reply);
      _set(JState.speaking);
      await _speak(reply);
    }
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
    String say = "Bajarildi.";
    String enc(dynamic v) => Uri.encodeComponent((v ?? "").toString());
    switch (action) {
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
          uri = Uri.parse("https://t.me/share/url?url=&text=${enc(msg)}");
          say = "Telegram xabarini tayyorladim - kimga yuborishni tanlang.";
        } else if (un.isNotEmpty) {
          uri = Uri.parse("https://t.me/$un");
          say = "Telegramda $un chatini ochyapman.";
        } else {
          uri = Uri.parse("https://t.me");
          say = "Telegramni ochyapman.";
        }
        break;
      default:
        say = (a["text"] ?? "Bajarildi.").toString();
    }
    setState(() => _botText = say);
    if (uri != null) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        say = "Ocholmadim: $e";
        setState(() => _botText = say);
      }
    }
    _set(JState.speaking);
    await _speak(say);
  }

  Future<String> _gemini() async {
    Object? lastErr;
    for (final m in geminiModels) {
      final url = Uri.parse(
          "https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent?key=$_key");
      final body = jsonEncode({
        "system_instruction": {"parts": [{"text": systemPrompt}]},
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
        return "\"Jarvis\" deng";
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _audio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            return Stack(
              children: [
                if (_state == JState.thinking || _state == JState.speaking)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: EdgeGlowPainter(_anim.value, _state),
                      ),
                    ),
                  ),
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Text("J A R V I S",
                              style: TextStyle(
                                  fontSize: 18,
                                  letterSpacing: 4,
                                  fontWeight: FontWeight.w600)),
                          const Spacer(),
                          IconButton(
                              onPressed: _settings,
                              icon: const Icon(Icons.settings, color: Colors.white70)),
                        ],
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _toggle,
                      child: SizedBox(
                        width: 260,
                        height: 260,
                        child: CustomPaint(painter: OrbPainter(_anim.value, _state)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(_statusLabel,
                        style: const TextStyle(
                            color: Color(0xFF31C9FF), fontSize: 14, letterSpacing: 1)),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                      child: Column(
                        children: [
                          if (_userText.isNotEmpty)
                            Text("Siz: $_userText",
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white54)),
                          const SizedBox(height: 8),
                          Text(_botText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 16)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ],
            );
          },
        ),
      ),
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
