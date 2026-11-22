import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core.dart';
import 'child_setup.dart' show TransparencyText;

/// Child home (KID-2, design §10.7): time left, schedule, transparency, SOS, requests, parent area.
class ChildHome extends StatefulWidget {
  const ChildHome({super.key});
  @override
  State<ChildHome> createState() => _ChildHomeState();
}

class _ChildHomeState extends State<ChildHome> {
  Map<String, dynamic> st = {}, today = {};
  Timer? timer;

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 60), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final s = await AgentBridge.status();
    final t = Map<String, dynamic>.from(await AgentBridge.call<Map>('today').catchError((_) => <dynamic, dynamic>{}) ?? {});
    if (!mounted) return;
    if (s['paired'] != true) {
      // Released (unpaired / turned 18 / account deleted): back to the role picker.
      await prefs.remove('role');
      if (mounted) Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const _Released()), (_) => false);
      return;
    }
    setState(() { st = s; today = t; });
  }

  Future<void> _sos() async {
    // KID-3: 5-second countdown to cancel an accidental press.
    final left = ValueNotifier(5);
    BuildContext? dialog;
    final t = Timer.periodic(const Duration(seconds: 1), (t) {
      left.value--;
      if (left.value <= 0) { t.cancel(); if (dialog != null && dialog!.mounted) Navigator.pop(dialog!, true); }
    });
    final send = await showDialog<bool>(context: context, barrierDismissible: false, builder: (ctx) {
      dialog = ctx;
      return ValueListenableBuilder<int>(valueListenable: left, builder: (_, n, _) => AlertDialog(
        title: Text(tr('Sending help request in $n…', '$n में मदद का संदेश जा रहा है…')),
        content: Text(tr('Your parents will be told right away.', 'आपके माता-पिता को तुरंत बताया जाएगा।')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel', 'रद्द करें'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Send now', 'अभी भेजें'))),
        ],
      ));
    });
    t.cancel();
    if (send == true && mounted) await attempt(context, () => AgentBridge.call('sos'), ok: tr('Your parents have been told. 💙', 'आपके माता-पिता को बता दिया गया। 💙'));
  }

  Future<void> _askTime() async {
    final reason = TextEditingController();
    final m = await showDialog<int>(context: context, builder: (_) => AlertDialog(
      title: Text(tr('Ask for more time', 'और समय माँगें')),
      content: TextField(controller: reason, maxLength: 140, decoration: InputDecoration(labelText: tr('Why? (optional)', 'क्यों? (वैकल्पिक)'))),
      actions: [for (final v in [15, 30, 60]) TextButton(onPressed: () => Navigator.pop(context, v), child: Text('$v min'))],
    ));
    if (m != null && mounted) {
      await attempt(context, () => AgentBridge.call('requestTime', {'minutes': m, 'reason': reason.text.trim().isEmpty ? null : reason.text.trim()}),
          ok: tr('Asked your parent ✓', 'माता-पिता से माँगा ✓'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = today['minutesLeft'] as num?;
    final used = today['usedMin'] as num? ?? 0;
    final sched = today['schedule'] as Map?;
    final next = today['nextSchedule'] as Map?;
    final paused = (st['pausedUntil'] as int? ?? 0) > DateTime.now().millisecondsSinceEpoch;
    final teen = st['ageBand'] == 'teen';
    return Scaffold(
      appBar: AppBar(title: Text(tr('Hi ${st['nickname'] ?? ''} 👋', 'नमस्ते ${st['nickname'] ?? ''} 👋'))),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Section(tr('Status', 'स्थिति'), Row(children: [
            Icon(paused ? Icons.pause_circle_rounded : Icons.verified_user_rounded, color: paused ? K.paused : K.ok),
            const SizedBox(width: 8),
            Expanded(child: Text(paused ? tr('Paused by your parent', 'माता-पिता ने रोका है') : tr('Your phone is protected', 'आपका फ़ोन सुरक्षित है'))),
          ])),
          Section(tr('Today', 'आज'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(left == null ? tr('${hm(used)} used today', 'आज ${hm(used)} इस्तेमाल') : tr('${hm(left)} left today', 'आज ${hm(left)} बाकी'),
                style: Theme.of(context).textTheme.headlineSmall),
            for (final a in List<Map>.from(today['apps'] as List? ?? []))
              if (a['left'] != null) Text(tr('${a['label']}: ${hm(a['left'] as num)} left', '${a['label']}: ${hm(a['left'] as num)} बाकी')),
            if (sched != null) Text(tr('${sched['name']} until ${sched['until']}', '${sched['name']} ${sched['until']} तक'), style: const TextStyle(color: K.high))
            else if (next != null) Text(tr('${next['name']} starts ${next['start']}', '${next['name']} ${next['start']} पर शुरू'), style: const TextStyle(color: K.muted)),
          ])),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: OutlinedButton.icon(
              onPressed: _askTime, icon: const Icon(Icons.more_time_rounded), label: Text(tr('Ask for more time', 'और समय माँगें')))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: OutlinedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(tr('What my parent can see', 'माता-पिता क्या देख सकते हैं'))),
                    body: Padding(padding: const EdgeInsets.all(24), child: TransparencyText(teen: teen))))),
              icon: const Icon(Icons.visibility_rounded), label: Text(tr('What my parent can see', 'माता-पिता क्या देख सकते हैं')))),
          Padding(padding: const EdgeInsets.all(16), child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: K.critical, side: const BorderSide(color: K.critical, width: 2), minimumSize: const Size.fromHeight(64)),
            onPressed: _sos, icon: const Icon(Icons.sos_rounded, size: 28), label: Text(tr('I need help', 'मुझे मदद चाहिए'), style: const TextStyle(fontSize: 18)),
          )),
          Section(tr('Talk to someone', 'किसी से बात करें'), Wrap(spacing: 8, children: [
            TextButton.icon(onPressed: () => launchUrl(Uri.parse('tel:1098')), icon: const Icon(Icons.call), label: const Text('Childline 1098')),
            TextButton.icon(onPressed: () => launchUrl(Uri.parse('tel:14416')), icon: const Icon(Icons.call), label: const Text('Tele-MANAS 14416')),
          ])),
          Center(child: TextButton.icon(
            onPressed: () async {
              final m = await askReport(context);
              if (m != null && context.mounted) {
                await attempt(context, () => AgentBridge.call('reportMisuse', {'message': m}), ok: tr('Report sent to Kavach. Thank you.', 'शिकायत Kavach को भेजी गई। धन्यवाद।'));
              }
            },
            icon: const Icon(Icons.report_rounded), label: Text(tr('Report misuse', 'दुरुपयोग की शिकायत')),
          )),
          Center(child: TextButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ParentArea())).then((_) => load()),
            icon: const Icon(Icons.lock_rounded), label: Text(tr('Parent area', 'पैरेंट एरिया')),
          )),
        ]),
      ),
    );
  }
}

/// PIN-gated parent controls on the child phone (ACC-8, CTL-8, PAIR-6, diagnostics).
class ParentArea extends StatefulWidget {
  const ParentArea({super.key});
  @override
  State<ParentArea> createState() => _ParentAreaState();
}

class _ParentAreaState extends State<ParentArea> {
  bool unlocked = false;
  final pin = TextEditingController();
  String? msg;
  Map<String, dynamic>? diag;

  Future<void> _check() async {
    final r = Map<String, dynamic>.from(await AgentBridge.call<Map>('verifyPin', {'pin': pin.text}) ?? {});
    pin.clear();
    setState(() {
      switch (r['result']) {
        case 'OK': unlocked = true; msg = null;
        case 'WRONG': msg = tr('${r['left']} tries left', '${r['left']} कोशिशें बाकी');
        case 'NO_PIN': msg = tr('No parent PIN set yet. Set it in Kavach → Settings on the parent phone.', 'अभी PIN सेट नहीं। माता-पिता के फ़ोन पर सेट करें।');
        default: msg = tr('Too many tries. Try again in 15 minutes.', 'बहुत बार गलत। 15 मिनट बाद कोशिश करें।');
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Parent area', 'पैरेंट एरिया'))),
        body: ListView(padding: const EdgeInsets.all(16), children: unlocked ? _menu() : [
          TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number, maxLength: 6, autofocus: true,
              decoration: InputDecoration(labelText: tr('Parent PIN', 'पैरेंट PIN'), border: const OutlineInputBorder()),
              onSubmitted: (_) => _check()),
          if (msg != null) Text(msg!, style: const TextStyle(color: K.high)),
          FilledButton(onPressed: _check, child: Text(tr('Unlock', 'अनलॉक'))),
        ]),
      );

  List<Widget> _menu() => [
        Text(tr('Pause monitoring', 'निगरानी रोकें'), style: const TextStyle(fontWeight: FontWeight.w700)),
        Wrap(spacing: 8, children: [
          for (final m in [15, 60, 240, 1440])
            OutlinedButton(onPressed: () async { await AgentBridge.call('pause', {'minutes': m}); if (mounted) toast(context, tr('Paused', 'रोका गया')); }, child: Text(hm(m))),
          TextButton(onPressed: () async { await AgentBridge.call('resume'); if (mounted) toast(context, tr('Resumed', 'फिर शुरू')); }, child: Text(tr('Resume', 'फिर शुरू'))),
        ]),
        const Divider(height: 32),
        ListTile(leading: const Icon(Icons.healing_rounded), title: Text(tr('Diagnostics', 'डायग्नोस्टिक्स')),
            onTap: () async { final d = Map<String, dynamic>.from(await AgentBridge.call<Map>('diagnostics') ?? {}); setState(() => diag = d); }),
        if (diag != null) ...[
          for (final k in ['accessibility', 'usageAccess', 'notifications', 'batteryExempt', 'admin', 'deviceOwner', 'notificationListener', 'visionModel'])
            ListTile(dense: true, title: Text(k), trailing: Icon(diag![k] == true ? Icons.check_circle : Icons.cancel, color: diag![k] == true ? K.ok : K.muted)),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: () => AgentBridge.call('openAccessibility'), child: Text(tr('Accessibility', 'सुलभता'))),
            TextButton(onPressed: () => AgentBridge.call('openUsageAccess'), child: Text(tr('Usage access', 'उपयोग एक्सेस'))),
            TextButton(onPressed: () => AgentBridge.call('openAutostart'), child: Text(tr('Autostart', 'ऑटोस्टार्ट'))),
          ]),
          Text('${tr('Health', 'स्थिति')}: ${diag!['health']} ${diag!['healthReason'] ?? ''}'),
        ],
        const Divider(height: 32),
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: K.critical),
          icon: const Icon(Icons.link_off_rounded),
          label: Text(tr('Remove Kavach from this phone', 'इस फ़ोन से Kavach हटाएँ')),
          onPressed: () async {
            final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
              title: Text(tr('Remove Kavach?', 'Kavach हटाएँ?')),
              content: Text(tr('Protection stops and the phone goes back to normal. Your parent will be told.', 'सुरक्षा बंद होगी और फ़ोन सामान्य होगा। माता-पिता को बताया जाएगा।')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel', 'रद्द करें'))),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Remove', 'हटाएँ'))),
              ],
            ));
            if (ok == true) {
              await AgentBridge.call('unpair');
              await prefs.remove('role');
              if (mounted) Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const _Released()), (_) => false);
            }
          },
        ),
      ];
}

class _Released extends StatelessWidget {
  const _Released();
  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(
      tr('Kavach is no longer protecting this phone. You can uninstall it now.', 'Kavach अब इस फ़ोन की सुरक्षा नहीं कर रहा। आप इसे अनइंस्टॉल कर सकते हैं।'),
      textAlign: TextAlign.center))));
}
