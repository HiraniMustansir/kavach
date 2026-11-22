import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core.dart';
import '../main.dart' show fcmToken;

/// PAIR-3/4/5/8: parent-driven wizard on the child phone, one permission per screen, then a self-test.
class ChildSetup extends StatefulWidget {
  final VoidCallback onPaired;
  const ChildSetup({super.key, required this.onPaired});
  @override
  State<ChildSetup> createState() => _ChildSetupState();
}

class _ChildSetupState extends State<ChildSetup> with WidgetsBindingObserver {
  int step = 0; // 0 code, 1 child explainer, 2 permissions, 3 self-test
  Map<String, dynamic> st = {};
  final code = TextEditingController();
  bool busy = false, scanning = false;
  Map<String, dynamic>? test;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh().then((_) {
      // Tier A: the token came in the provisioning extras; pair straight away.
      final t = st['pendingToken'] as String?;
      if (t != null && st['paired'] != true) _pair(t);
      if (st['paired'] == true) setState(() => step = 2);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from a Settings screen → re-check what's granted.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) { if (s == AppLifecycleState.resumed) _refresh(); }

  Future<void> _refresh() async { final s = await AgentBridge.status(); if (mounted) setState(() => st = s); }

  Future<void> _pair(String token) async {
    final t = token.startsWith('KAVACH:') ? token.substring(7) : token;
    setState(() => busy = true);
    final ok = await attempt(context, () async { await AgentBridge.pair(t, await fcmToken()); });
    await _refresh();
    if (mounted) setState(() { busy = false; if (ok) step = 1; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Set up Kavach', 'Kavach सेट करें')), actions: [
          TextButton(onPressed: () => setLang(lang.value == 'hi' ? 'en' : 'hi').then((_) => setState(() {})), child: Text(lang.value == 'hi' ? 'English' : 'हिन्दी')),
        ]),
        body: SafeArea(child: switch (step) { 0 => _code(), 1 => _explain(), 2 => _permissions(), _ => _selfTest() }),
      );

  Widget _code() => ListView(padding: const EdgeInsets.all(24), children: [
        Text(tr('Parent: scan the code shown in Kavach on your phone, or type it.', 'माता-पिता: अपने फ़ोन पर Kavach में दिखा कोड स्कैन करें या टाइप करें।'),
            style: Theme.of(context).textTheme.titleMedium),
        if ((st['otherAdmins'] as List? ?? []).isNotEmpty)
          Card(color: K.medium.withValues(alpha: 0.15), child: Padding(padding: const EdgeInsets.all(12), child: Text(tr(
              'This phone is already managed by another app (${(st['otherAdmins'] as List).join(', ')}). If it’s Google Family Link, remove supervision first, or use Protected (no reset) setup.',
              'यह फ़ोन पहले से किसी दूसरे ऐप से मैनेज है (${(st['otherAdmins'] as List).join(', ')})। Google Family Link हो तो पहले उसे हटाएँ।')))),
        const SizedBox(height: 16),
        if (scanning)
          SizedBox(height: 300, child: MobileScanner(onDetect: (cap) {
            final v = cap.barcodes.firstOrNull?.rawValue;
            if (v != null && !busy) { setState(() => scanning = false); _pair(v); }
          }))
        else
          OutlinedButton.icon(onPressed: () => setState(() => scanning = true), icon: const Icon(Icons.qr_code_scanner_rounded), label: Text(tr('Scan code', 'कोड स्कैन करें'))),
        const SizedBox(height: 16),
        TextField(controller: code, textCapitalization: TextCapitalization.characters, maxLength: 10,
            decoration: InputDecoration(labelText: tr('Or type the 10-letter code', 'या 10 अक्षरों का कोड टाइप करें'), border: const OutlineInputBorder())),
        FilledButton(onPressed: busy ? null : () => _pair(code.text.trim()), child: busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(tr('Connect', 'जोड़ें'))),
      ]);

  /// Age-appropriate explanation for the child (PAIR-3, KID-2 transparency).
  Widget _explain() => ListView(padding: const EdgeInsets.all(24), children: [
        const Icon(Icons.shield_rounded, size: 72, color: K.primary),
        const SizedBox(height: 12),
        Text(tr('Hi ${st['nickname'] ?? ''}! This phone is protected by Kavach.', 'नमस्ते ${st['nickname'] ?? ''}! यह फ़ोन Kavach से सुरक्षित है।'),
            style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        const TransparencyText(),
        const SizedBox(height: 24),
        FilledButton(onPressed: () => setState(() => step = 2), child: Text(tr('OK, got it', 'ठीक है, समझ गया/गई'))),
      ]);

  Widget _permissions() {
    final tier = st['tier'] as String? ?? 'C';
    final items = <(_Perm, bool)>[
      (_Perm(tr('Notifications', 'सूचनाएँ'), tr('So your child sees time warnings and the Kavach status.', 'ताकि बच्चे को समय की चेतावनी दिखे।'),
          () => AgentBridge.call('requestNotifications')), st['notifications'] == true),
      (_Perm(tr('Screen protection (Accessibility)', 'स्क्रीन सुरक्षा (सुलभता)'),
          tr('Turn on “Kavach” in Accessibility. Android 13+: if it’s greyed out, open App info → ⋮ → Allow restricted settings first.',
              'सुलभता में “Kavach” चालू करें। Android 13+: अगर धुंधला हो, तो पहले App info → ⋮ → Allow restricted settings खोलें।'),
          _accessibility), st['accessibility'] == true),
      (_Perm(tr('Usage access', 'उपयोग एक्सेस'), tr('For screen time and limits.', 'स्क्रीन टाइम और सीमाओं के लिए।'), () => AgentBridge.call('openUsageAccess')), st['usageAccess'] == true),
      (_Perm(tr('Run in background', 'बैकग्राउंड में चलें'), tr('So the battery saver doesn’t stop protection.', 'ताकि बैटरी सेवर सुरक्षा न रोके।'),
          () => AgentBridge.call('requestBatteryExemption')), st['batteryExempt'] == true),
      if (tier == 'B') (_Perm(tr('Device admin', 'डिवाइस एडमिन'), tr('Lets Kavach lock the phone and warn you before it’s removed.', 'Kavach फ़ोन लॉक कर सके और हटाने से पहले आपको बताए।'),
          () => AgentBridge.call('activateAdmin')), st['admin'] == true),
      (_Perm(tr('Message checks (optional)', 'मैसेज जाँच (वैकल्पिक)'), tr('Only if you turned this on in consent.', 'केवल अगर आपने सहमति में चालू किया हो।'),
          () => AgentBridge.call('openNotificationListener'), optional: true), st['notificationListener'] == true),
    ];
    final required = items.where((i) => !i.$1.optional);
    final oem = st['oem'] as String? ?? '';
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(tr('Parent: turn these on', 'माता-पिता: इन्हें चालू करें'), style: Theme.of(context).textTheme.titleMedium),
      for (final (p, ok) in items)
        Card(child: ListTile(
          leading: Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked, color: ok ? K.ok : K.muted),
          title: Text(p.title), subtitle: Text(p.body),
          trailing: ok ? null : FilledButton.tonal(onPressed: p.open, child: Text(tr('Turn on', 'चालू करें'))),
        )),
      if (['xiaomi', 'redmi', 'poco', 'oppo', 'realme', 'oneplus', 'vivo', 'iqoo', 'samsung'].contains(oem))
        Card(child: ListTile(
          leading: const Icon(Icons.battery_alert_rounded),
          title: Text(tr('$oem: allow autostart', '$oem: ऑटोस्टार्ट चालू करें')),
          subtitle: Text(tr('This phone brand stops background apps. Allow Kavach to auto-start / run in background.', 'यह ब्रांड बैकग्राउंड ऐप रोकता है। Kavach को ऑटो-स्टार्ट की अनुमति दें।')),
          trailing: FilledButton.tonal(onPressed: () => AgentBridge.call('openAutostart'), child: Text(tr('Open', 'खोलें'))),
        )),
      const SizedBox(height: 16),
      FilledButton(onPressed: required.every((i) => i.$2) ? () { setState(() => step = 3); _runTest(); } : null, child: Text(tr('Run self-test', 'सेल्फ़-टेस्ट चलाएँ'))),
    ]);
  }

  /// Play policy: prominent disclosure + affirmative consent before sending the user to Accessibility settings.
  Future<void> _accessibility() async {
    final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => AlertDialog(
      title: Text(tr('How Kavach uses Accessibility', 'Kavach सुलभता का उपयोग कैसे करता है')),
      content: SingleChildScrollView(child: Text(tr(
        'Kavach uses the Accessibility service to see which app is open, read on-screen text and web addresses, and take screenshots to check for unsafe content like sexual or violent material.\n\n'
        'All of this is checked on this phone only. Screenshots and text are deleted right after the check and are never uploaded. Your parent only receives the type of content found, the app and the time.\n\n'
        'It is also used to show block screens and to stop Kavach being turned off without the parent PIN.',
        'Kavach सुलभता सेवा से देखता है कि कौन-सा ऐप खुला है, स्क्रीन का टेक्स्ट और वेब पता पढ़ता है, और अश्लील या हिंसक जैसी असुरक्षित सामग्री जाँचने के लिए स्क्रीनशॉट लेता है।\n\n'
        'यह सब केवल इसी फ़ोन पर जाँचा जाता है। स्क्रीनशॉट और टेक्स्ट जाँच के तुरंत बाद मिटा दिए जाते हैं और कभी अपलोड नहीं होते। माता-पिता को केवल सामग्री का प्रकार, ऐप और समय मिलता है।\n\n'
        'इसका उपयोग ब्लॉक स्क्रीन दिखाने और पैरेंट PIN के बिना Kavach बंद होने से रोकने के लिए भी होता है।'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Not now', 'अभी नहीं'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Agree & continue', 'सहमत, आगे बढ़ें'))),
      ],
    ));
    if (ok == true) {
      if ((st['sdk'] as int? ?? 0) >= 33 && st['tier'] != 'A') await AgentBridge.call('openAppDetails'); // PAIR-8 restricted settings
      await AgentBridge.call('openAccessibility');
    }
  }

  /// Each call sends one test alert to the parent, so it runs only when asked (not from build).
  Future<void> _runTest() async {
    setState(() => test = null);
    final r = await AgentBridge.call<Map>('selfTest');
    if (mounted) setState(() => test = Map<String, dynamic>.from(r ?? {}));
  }

  Widget _selfTest() {
    if (test == null) return const Loading();
    final t = test!;
    Widget row(String label, bool? ok, [String? note]) => ListTile(
          leading: Icon(ok == null ? Icons.remove_circle_outline : ok ? Icons.check_circle_rounded : Icons.error_rounded, color: ok == null ? K.muted : ok ? K.ok : K.critical),
          title: Text(label), subtitle: note == null ? null : Text(note));
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(tr('Self-test', 'सेल्फ़-टेस्ट'), style: Theme.of(context).textTheme.titleLarge),
      row(tr('Screen protection', 'स्क्रीन सुरक्षा'), t['accessibility'] == true),
      row(tr('Usage access', 'उपयोग एक्सेस'), t['usageAccess'] == true),
      row(tr('Screenshot check works on this phone', 'इस फ़ोन पर स्क्रीनशॉट जाँच काम करती है'), t['screenshot'] as bool?,
          (t['sdk'] as int? ?? 0) < 30 ? tr('Android 10 or older: text and website checks only.', 'Android 10 या पुराना: केवल टेक्स्ट और वेबसाइट जाँच।') : null),
      row(tr('Image AI model', 'इमेज AI मॉडल'), t['modelLoaded'] == true ? true : null,
          t['modelLoaded'] == true ? null : tr('Not installed yet: text, website and app checks are active.', 'अभी नहीं लगा: टेक्स्ट, वेबसाइट और ऐप जाँच चालू है।')),
      row(tr('Device protection (Tier A)', 'डिवाइस सुरक्षा (स्तर A)'), t['tier'] == 'A' ? t['deviceOwner'] == true : null),
      row(tr('Test alert sent to parent', 'माता-पिता को टेस्ट अलर्ट भेजा'), t['testAlertSent'] == true),
      if (t['hasPin'] != true)
        Card(color: K.medium.withValues(alpha: 0.15), child: Padding(padding: const EdgeInsets.all(12),
            child: Text(tr('Parent: set your parent PIN in Kavach → Settings on your phone.', 'माता-पिता: अपने फ़ोन पर Kavach → सेटिंग्स में पैरेंट PIN सेट करें।')))),
      const SizedBox(height: 16),
      Row(children: [
        OutlinedButton(onPressed: _runTest, child: Text(tr('Run again', 'फिर चलाएँ'))),
        const SizedBox(width: 8),
        Expanded(child: FilledButton(onPressed: () { AgentBridge.call('startAgent'); widget.onPaired(); }, child: Text(tr('Finish', 'पूरा करें')))),
      ]),
    ]);
  }
}

class _Perm {
  final String title, body;
  final Future<void> Function() open;
  final bool optional;
  _Perm(this.title, this.body, this.open, {this.optional = false});
}

/// "What my parent can see" (design §10.7), age-appropriate.
class TransparencyText extends StatelessWidget {
  final bool teen;
  const TransparencyText({super.key, this.teen = false});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Your parent CAN see:', 'आपके माता-पिता देख सकते हैं:'), style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(tr('• Which apps you use and for how long', '• आप कौन-से ऐप कितनी देर चलाते हैं')),
        Text(tr('• If something unsafe shows up on screen (like violent or adult stuff) — the type, the app and the time', '• अगर स्क्रीन पर कुछ असुरक्षित दिखे (जैसे हिंसक या बड़ों वाली चीज़ें) — उसका प्रकार, ऐप और समय')),
        Text(tr('• When you press “I need help”', '• जब आप “मुझे मदद चाहिए” दबाते हैं')),
        const SizedBox(height: 8),
        Text(tr('Your parent can NOT:', 'आपके माता-पिता नहीं कर सकते:'), style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(tr('• See your photos or your screen', '• आपकी फ़ोटो या स्क्रीन देखना')),
        Text(tr('• Read your messages', '• आपके मैसेज पढ़ना')),
        if (teen) ...[
          const SizedBox(height: 8),
          Text(tr('For small things, your parent only sees a count in a daily summary.', 'छोटी बातों के लिए माता-पिता को केवल दैनिक सारांश में गिनती दिखती है।')),
        ],
      ]);
}
