import 'dart:convert';
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
    "Sen - JARVIS, foydalanuvchining shaxsiy AI yordamchisi. Qisqa, aniq, iliq javob ber. "
    "Foydalanuvchi qaysi tilda gapirsa (o'zbek, rus, ingliz) o'sha tilda javob ber. "
    "Standart til - o'zbek.";

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'JARVIS',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF0A0E14),
          colorScheme: const ColorScheme.dark(primary: Color(0xFF31C9FF)),
        ),
        home: const ChatPage(),
      );
}

class Msg {
  final String text;
  final bool me;
  Msg(this.text, this.me);
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _msgs = <Msg>[];
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _stt = stt.SpeechToText();
  final _tts = FlutterTts();
  bool _listening = false, _busy = false;
  String _key = "";
  final _history = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _tts.setLanguage("uz-UZ");
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _key = p.getString("gemini_key") ?? "";
    setState(() {});
    if (_key.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _settings());
    }
  }

  Future<void> _saveKey(String k) async {
    final p = await SharedPreferences.getInstance();
    await p.setString("gemini_key", k);
    setState(() => _key = k);
  }

  void _add(String t, bool me) {
    setState(() => _msgs.add(Msg(t, me)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send(String text) async {
    text = text.trim();
    if (text.isEmpty) return;
    if (_key.isEmpty) {
      _settings();
      return;
    }
    _ctrl.clear();
    _add(text, true);
    setState(() => _busy = true);
    _history.add({"role": "user", "parts": [{"text": text}]});
    try {
      final reply = await _gemini();
      _history.add({"role": "model", "parts": [{"text": reply}]});
      _add(reply, false);
      await _tts.speak(reply);
    } catch (e) {
      _add("[xato] $e", false);
    }
    setState(() => _busy = false);
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

  Future<void> _mic() async {
    if (_listening) {
      _stt.stop();
      setState(() => _listening = false);
      return;
    }
    final ok = await _stt.initialize();
    if (!ok) {
      _add("Mikrofon ishlamadi (ruxsat bering).", false);
      return;
    }
    setState(() => _listening = true);
    _stt.listen(
      localeId: "uz_UZ",
      onResult: (res) {
        if (res.finalResult) {
          setState(() => _listening = false);
          _send(res.recognizedWords);
        }
      },
    );
  }

  void _settings() {
    final kc = TextEditingController(text: _key);
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF111826),
        title: const Text("Sozlamalar"),
        content: TextField(
          controller: kc,
          decoration: const InputDecoration(
              labelText: "Gemini API key", hintText: "AIza..."),
        ),
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

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF111826),
          title: const Text("JARVIS", style: TextStyle(letterSpacing: 3)),
          actions: [
            IconButton(onPressed: _settings, icon: const Icon(Icons.settings))
          ],
        ),
        body: Column(children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(14),
              itemCount: _msgs.length,
              itemBuilder: (c, i) {
                final m = _msgs[i];
                return Align(
                  alignment: m.me ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 5),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(c).size.width * 0.8),
                    decoration: BoxDecoration(
                      color: m.me
                          ? const Color(0xFF31C9FF)
                          : const Color(0xFF111826),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(m.text,
                        style: TextStyle(
                            color: m.me
                                ? const Color(0xFF04121B)
                                : Colors.white)),
                  ),
                );
              },
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Container(
            padding: const EdgeInsets.all(10),
            color: const Color(0xFF0D1420),
            child: Row(children: [
              IconButton(
                onPressed: _mic,
                icon: Icon(_listening ? Icons.mic : Icons.mic_none,
                    color: _listening
                        ? const Color(0xFF31C9FF)
                        : Colors.white70),
              ),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  onSubmitted: _send,
                  decoration: const InputDecoration(
                      hintText: "Xabar yozing yoki mikrofon...",
                      border: InputBorder.none),
                ),
              ),
              IconButton(
                onPressed: () => _send(_ctrl.text),
                icon: const Icon(Icons.send, color: Color(0xFF31C9FF)),
              ),
            ]),
          ),
        ]),
      );
}
