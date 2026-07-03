import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const JarvisApp());

const geminiModels = [
  "gemini-2.5-pro", "gemini-3-pro-preview", "gemini-pro-latest",
  "gemini-flash-latest", "gemini-2.5-flash", "gemini-2.0-flash"
];
const systemPrompt =
    "Sen - JARVIS, foydalanuvchining shaxsiy AI yordamchisi. Qisqa, tabiiy, iliq javob ber "
    "(1-3 gap, ovozda eshitiladi). Foydalanuvchi qaysi tilda gapirsa (o'zbek, rus, ingliz) "
    "o'sha tilda javob ber. Standart til - o'zbek.";

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
  late final AnimationController _anim;
  String _key = "";
  String _ttsLang = "uz-UZ";
  final _history = <Map<String, dynamic>>[];
  JState _state = JState.idle;
  bool _handsFree = false;
  bool _sttReady = false;
  String _userText = "";
  String _botText = "Salom! Men JARVIS. Sharni bosing yoki gapiring.";

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
    _initTts();
    _load();
  }

  Future<void> _initTts() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      _ttsLang = "en-US";
      for (final l in ["uz-UZ", "ru-RU", "en-US"]) {
        try {
          final ok = await _tts.isLanguageAvailable(l);
          if (ok == true) {
            _ttsLang = l;
            break;
          }
        } catch (_) {}
      }
      await _tts.setLanguage(_ttsLang);
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (_) {}
    _tts.setCompletionHandler(() {
      if (_handsFree) {
        _startListening();
      } else {
        _set(JState.idle);
      }
    });
    _tts.setErrorHandler((msg) {
      if (_handsFree) {
        _startListening();
      } else {
        _set(JState.idle);
      }
    });
  }

  Future<void> _speak(String text) async {
    try {
      await _tts.stop();
      await _tts.setLanguage(_ttsLang);
      await _tts.setVolume(1.0);
      await _tts.speak(text);
    } catch (_) {
      if (_handsFree) _startListening();
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _key = p.getString("gemini_key") ?? "";
    if (mounted) setState(() {});
    if (_key.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _settings());
    }
  }

  Future<void> _saveKey(String k) async {
    final p = await SharedPreferences.getInstance();
    await p.setString("gemini_key", k);
    if (mounted) setState(() => _key = k);
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
      _set(JState.idle);
    }
  }

  Future<void> _startListening() async {
    if (!_sttReady) {
      _sttReady = await _stt.initialize(onError: (e) {}, onStatus: (s) {});
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
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      onResult: (r) {
        setState(() => _userText = r.recognizedWords);
        if (r.finalResult) {
          final t = r.recognizedWords.trim();
          if (t.isNotEmpty) {
            _handle(t);
          } else if (_handsFree) {
            _startListening();
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
    setState(() => _botText = reply);
    _set(JState.speaking);
    await _speak(reply);
  }

  Future<String> _gemini() async {
    Object? lastErr;
    for (final m in geminiModels) {
      final url = Uri.parse(
          "https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent?key=$_key");
      final body = jsonEncode({
        "system_instruction": {"parts": [{"text": systemPrompt}]},
        "contents": _history,
        "generationConfig": {"temperature": 0.7, "maxOutputTokens": 1024}
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

  void _settings() {
    final kc = TextEditingController(text: _key);
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF111826),
        title: const Text("Sozlamalar"),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: kc,
            decoration: const InputDecoration(
                labelText: "Gemini API key", hintText: "AIza..."),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _speak("Salom, men JARVIS. Ovoz sinovi."),
              icon: const Icon(Icons.volume_up),
              label: const Text("Ovozni sinash"),
            ),
          ),
          Text("TTS tili: $_ttsLang",
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
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
        return "Tayyor";
    }
  }

  @override
  void dispose() {
    _anim.dispose();
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
                              icon: const Icon(Icons.settings,
                                  color: Colors.white70)),
                        ],
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _toggle,
                      child: SizedBox(
                        width: 260,
                        height: 260,
                        child: CustomPaint(
                          painter: OrbPainter(_anim.value, _state),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(_statusLabel,
                        style: const TextStyle(
                            color: Color(0xFF31C9FF),
                            fontSize: 15,
                            letterSpacing: 1)),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 10),
                      child: Column(
                        children: [
                          if (_userText.isNotEmpty)
                            Text("Siz: $_userText",
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white54)),
                          const SizedBox(height: 8),
                          Text(_botText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 16)),
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
        return const Color(0xFF7B5CFF);
      case JState.speaking:
        return const Color(0xFF2BF5C0);
      case JState.listening:
        return const Color(0xFF31C9FF);
      default:
        return const Color(0xFF2E7BFF);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final baseR = size.shortestSide * 0.26;
    final c = _c;
    final active = state != JState.idle;
    final speed = state == JState.thinking ? 2.4 : (active ? 1.4 : 0.7);

    final glow = Paint()
      ..shader = RadialGradient(colors: [
        c.withOpacity(0.45),
        c.withOpacity(0.0),
      ]).createShader(Rect.fromCircle(center: center, radius: baseR * 2.4));
    canvas.drawCircle(center, baseR * 2.4, glow);

    final pulse = 1 + 0.07 * sin(t * 2 * pi * (active ? 2 : 1));
    final core = Paint()
      ..shader = RadialGradient(colors: [Colors.white, c]).createShader(
          Rect.fromCircle(center: center, radius: baseR * pulse));
    canvas.drawCircle(center, baseR * pulse, core);

    final pp = Paint()..color = c.withOpacity(0.9);
    const n = 46;
    for (int i = 0; i < n; i++) {
      final ang = (i / n) * 2 * pi + t * 2 * pi * speed;
      final wobble = sin(t * 2 * pi * 3 + i * 0.7);
      final rr = baseR * 1.35 + baseR * 0.55 * wobble;
      final p = center + Offset(cos(ang) * rr, sin(ang) * rr * 0.62);
      canvas.drawCircle(p, 1.6 + 1.2 * (0.5 + 0.5 * wobble), pp);
    }

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withOpacity(0.25);
    canvas.drawCircle(center, baseR * 1.15, ring);
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
        RRect.fromRectAndRadius(rect.deflate(4), const Radius.circular(18)),
        paint);
  }

  @override
  bool shouldRepaint(EdgeGlowPainter o) => o.t != t || o.state != state;
}
