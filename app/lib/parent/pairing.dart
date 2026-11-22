import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core.dart';

/// PAIR-1/2 + design §10.6: choose tier → (backup) → QR + code with TTL → live checklist.
class PairingScreen extends StatefulWidget {
  final Map<String, dynamic> child;
  const PairingScreen({super.key, required this.child});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  String tier = 'A';
  bool backedUp = false;
  Map<String, dynamic>? session;
  DateTime? startedAt;
  Map<String, dynamic>? device;
  Timer? poll, tick;

  @override
  void dispose() {
    poll?.cancel();
    tick?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final r = await Api.parent('pair-start', {'childId': widget.child['id'], 'tier': tier});
      startedAt = DateTime.now().toUtc();
      setState(() => session = r);
      tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
      poll = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> _poll() async {
    final r = await sb.from('device').select().eq('child_id', widget.child['id'] as String)
        .gte('paired_at', startedAt!.subtract(const Duration(seconds: 5)).toIso8601String()).order('paired_at', ascending: false).limit(1);
    if (r.isNotEmpty && mounted) setState(() => device = r.first);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.child['nickname'];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Set up $name’s phone', '$name का फ़ोन सेट करें'))),
      body: ListView(padding: const EdgeInsets.all(16), children: session == null ? _choose() : _qr()),
    );
  }

  List<Widget> _choose() => [
        Text(tr('Step 1 · Choose protection', 'चरण 1 · सुरक्षा चुनें'), style: Theme.of(context).textTheme.titleMedium),
        RadioGroup<String>(groupValue: tier, onChanged: (v) => setState(() => tier = v!), child: Column(children: [
        _tierCard('A', tr('Fully protected (recommended)', 'पूरी सुरक्षा (सुझाव)'),
            tr('Your child can’t remove Kavach. Needs a phone reset (~15 min).', 'बच्चा Kavach नहीं हटा सकता। फ़ोन रीसेट करना होगा (~15 मिनट)।')),
        _tierCard('B', tr('Protected (no reset)', 'सुरक्षित (रीसेट नहीं)'),
            tr('Removing it needs your PIN, and you’re told right away.', 'हटाने के लिए आपका PIN चाहिए, और आपको तुरंत बताया जाएगा।')),
        _tierCard('C', tr('Basic', 'बेसिक'), tr('Quick setup. You’re alerted if protection stops.', 'जल्दी सेटअप। सुरक्षा रुकने पर आपको बताया जाएगा।')),
        ])),
        if (tier == 'A') ...[
          const SizedBox(height: 16),
          Text(tr('Step 2 · Back up the child’s phone', 'चरण 2 · बच्चे के फ़ोन का बैकअप लें'), style: Theme.of(context).textTheme.titleMedium),
          Text(tr('Resetting erases the phone. Back up photos and chats (Google One / WhatsApp backup) first.',
              'रीसेट से फ़ोन का सब मिट जाता है। पहले फ़ोटो और चैट का बैकअप लें (Google One / WhatsApp बैकअप)।')),
          CheckboxListTile(value: backedUp, onChanged: (v) => setState(() => backedUp = v ?? false), title: Text(tr('I’ve backed up', 'मैंने बैकअप ले लिया'))),
        ],
        const SizedBox(height: 16),
        FilledButton(onPressed: tier == 'A' && !backedUp ? null : _start, child: Text(tr('Show setup code', 'सेटअप कोड दिखाएँ'))),
      ];

  Widget _tierCard(String t, String title, String body) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: tier == t ? K.primary : Colors.transparent, width: 2)),
        child: RadioListTile<String>(value: t, title: Text(title), subtitle: Text(body)),
      );

  List<Widget> _qr() {
    final exp = DateTime.parse(session!['expiresAt'] as String).difference(DateTime.now());
    final expired = exp.isNegative && device == null;
    final steps = tier == 'A'
        ? tr('On the child’s phone: factory reset → on the welcome screen tap 6 times → scan this code → connect to Wi-Fi.',
            'बच्चे के फ़ोन पर: फ़ैक्टरी रीसेट → वेलकम स्क्रीन पर 6 बार टैप करें → यह कोड स्कैन करें → Wi-Fi से जोड़ें।')
        : tr('On the child’s phone: install Kavach from Play Store → “This is my child’s phone” → scan this code or type it.',
            'बच्चे के फ़ोन पर: Play Store से Kavach लगाएँ → “यह मेरे बच्चे का फ़ोन है” → यह कोड स्कैन करें या टाइप करें।');
    final d = device;
    return [
      Text(steps),
      const SizedBox(height: 16),
      if (!expired && d == null) ...[
        Center(child: Container(color: Colors.white, padding: const EdgeInsets.all(12),
            child: QrImageView(data: session!['qr'] as String, size: 260, semanticsLabel: tr('Setup QR code', 'सेटअप QR कोड')))),
        const SizedBox(height: 8),
        Center(child: SelectableText(session!['code'] as String, style: const TextStyle(fontSize: 28, letterSpacing: 4, fontWeight: FontWeight.w700))),
        Center(child: Text('${tr('Expires in', 'समाप्ति')} ${exp.inMinutes}:${(exp.inSeconds % 60).toString().padLeft(2, '0')}', style: const TextStyle(color: K.muted))),
      ],
      if (expired) FilledButton(onPressed: () { poll?.cancel(); tick?.cancel(); setState(() => session = null); }, child: Text(tr('Code expired — make a new one', 'कोड की समय-सीमा ख़त्म — नया बनाएँ'))),
      const SizedBox(height: 16),
      Text(tr('Live checklist', 'लाइव चेकलिस्ट'), style: Theme.of(context).textTheme.titleMedium),
      _check(d != null, tr('Kavach installed and connected', 'Kavach लगा और जुड़ गया')),
      _check(d != null && d['health_state'] == 'protected', tr('Protection on (permissions granted)', 'सुरक्षा चालू (अनुमतियाँ दी गईं)')),
      _check(d != null && d['last_heartbeat'] != null && DateTime.parse(d['last_heartbeat'] as String).isAfter(DateTime.parse(d['paired_at'] as String).add(const Duration(seconds: 10))),
          tr('Self-test finished', 'सेल्फ़-टेस्ट पूरा')),
      if (d != null) ...[
        const SizedBox(height: 16),
        Text(tr('A test alert will arrive on this phone when setup finishes on the child’s phone.', 'बच्चे के फ़ोन पर सेटअप पूरा होने पर इस फ़ोन पर एक टेस्ट अलर्ट आएगा।')),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Done', 'हो गया'))),
      ],
    ];
  }

  Widget _check(bool ok, String text) => ListTile(
        dense: true,
        leading: Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked, color: ok ? K.ok : K.muted),
        title: Text(text),
      );
}
