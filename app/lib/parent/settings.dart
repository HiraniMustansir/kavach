import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core.dart';

/// Settings (design §9): notifications (ACC-6), language, app lock (ACC-7), parent PIN (ACC-8),
/// privacy rights (ACC-9), help (SET-4).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? member;
  bool appLock = prefs.getBool('appLock') ?? true;

  @override
  void initState() {
    super.initState();
    Api.myFamilies().then((f) { if (mounted && f.isNotEmpty) setState(() => member = f.first); });
  }

  Map<String, dynamic> get np => Map<String, dynamic>.from(member?['notify_prefs'] as Map? ?? {});

  Future<void> _savePrefs(Map<String, dynamic> v) async {
    final next = {...np, ...v};
    setState(() => member = {...member!, 'notify_prefs': next});
    await attempt(context, () => sb.from('family_member').update({'notify_prefs': next})
        .eq('family_id', member!['family_id'] as String).eq('guardian_id', sb.auth.currentUser!.id));
  }

  Future<void> _setPin() async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: Text(tr('Parent PIN', 'पैरेंट PIN')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('Used on your child’s phone to change settings, pause, or remove Kavach.', 'बच्चे के फ़ोन पर सेटिंग बदलने, रोकने या Kavach हटाने के लिए।')),
        TextField(controller: a, obscureText: true, keyboardType: TextInputType.number, maxLength: 6, decoration: InputDecoration(labelText: tr('New 6-digit PIN', 'नया 6 अंकों का PIN'))),
        TextField(controller: b, obscureText: true, keyboardType: TextInputType.number, maxLength: 6, decoration: InputDecoration(labelText: tr('Repeat PIN', 'PIN दोबारा'))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel', 'रद्द करें'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Save', 'सेव करें'))),
      ],
    ));
    if (ok != true || !mounted) return;
    if (a.text != b.text) return toast(context, tr('PINs don’t match', 'PIN मेल नहीं खाते'));
    await attempt(context, () => Api.parent('set-pin', {'pin': a.text}), ok: tr('PIN saved. Child phones update in a few seconds.', 'PIN सेव हुआ।'));
  }

  Future<void> _quietHours() async {
    final from = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 22, minute: 0), helpText: tr('Quiet from', 'शांत समय शुरू'));
    if (from == null || !mounted) return;
    final to = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 7, minute: 0), helpText: tr('Quiet until', 'शांत समय ख़त्म'));
    if (to == null) return;
    String f(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    _savePrefs({'quietFrom': f(from), 'quietTo': f(to)});
  }

  Future<void> _export() async {
    await attempt(context, () async {
      final data = await Api.parent('export');
      await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)));
    }, ok: tr('Your data was copied to the clipboard as JSON.', 'आपका डेटा JSON के रूप में कॉपी हुआ।'));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: Text(tr('Delete account?', 'अकाउंट डिलीट करें?')),
      content: Text(tr('This deletes your family, children, alerts and summaries, and releases your children’s phones. This can’t be undone.',
          'इससे आपका परिवार, बच्चे, अलर्ट और सारांश मिट जाएँगे और बच्चों के फ़ोन मुक्त हो जाएँगे। यह वापस नहीं होगा।')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel', 'रद्द करें'))),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: K.critical), onPressed: () => Navigator.pop(context, true), child: Text(tr('Delete', 'डिलीट करें'))),
      ],
    ));
    if (ok != true || !mounted) return;
    if (await attempt(context, () => Api.parent('delete-account'))) {
      await sb.auth.signOut();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chips = [...cats, extraCats[0], extraCats[1], extraCats[3]];
    final selected = Set<String>.from(np['categories'] as List? ?? chips.map((c) => c.code));
    return Scaffold(
      appBar: AppBar(title: Text(tr('Settings', 'सेटिंग्स'))),
      body: ListView(children: [
        Section(tr('Notifications', 'सूचनाएँ'), Column(children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Quiet hours', 'शांत समय')),
            subtitle: Text(np['quietFrom'] == null ? tr('Off', 'बंद') : '${np['quietFrom']} → ${np['quietTo']}'),
            trailing: np['quietFrom'] == null ? null : IconButton(icon: const Icon(Icons.close), onPressed: () => _savePrefs({'quietFrom': null, 'quietTo': null})),
            onTap: _quietHours,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Critical alerts break through quiet hours', 'गंभीर अलर्ट शांत समय में भी आएँ')),
            value: np['criticalBypassQuiet'] != false, onChanged: (v) => _savePrefs({'criticalBypassQuiet': v}),
          ),
          Align(alignment: Alignment.centerLeft, child: Text(tr('Alert me about', 'मुझे इनके बारे में बताएँ'), style: const TextStyle(fontWeight: FontWeight.w600))),
          Wrap(spacing: 6, children: [
            for (final c in chips)
              FilterChip(label: Text(c.label), selected: selected.contains(c.code),
                  onSelected: (v) => _savePrefs({'categories': (v ? (selected..add(c.code)) : (selected..remove(c.code))).toList()})),
          ]),
        ])),
        Section(tr('Security', 'सुरक्षा'), Column(children: [
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.pin_rounded), title: Text(tr('Set parent PIN', 'पैरेंट PIN सेट करें')), onTap: _setPin),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.fingerprint_rounded),
            title: Text(tr('Lock Kavach with fingerprint/PIN', 'फ़िंगरप्रिंट/PIN से Kavach लॉक करें')),
            value: appLock, onChanged: (v) { prefs.setBool('appLock', v); setState(() => appLock = v); },
          ),
        ])),
        Section(tr('Language', 'भाषा'), SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'en', label: Text('English')), ButtonSegment(value: 'hi', label: Text('हिन्दी'))],
          selected: {lang.value},
          onSelectionChanged: (s) async { await setLang(s.first); setState(() {}); },
        )),
        Section(tr('Privacy', 'गोपनीयता'), Column(children: [
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.download_rounded), title: Text(tr('Export my data', 'मेरा डेटा एक्सपोर्ट करें')), onTap: _export),
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.delete_forever_rounded, color: K.critical),
              title: Text(tr('Delete account', 'अकाउंट डिलीट करें'), style: const TextStyle(color: K.critical)), onTap: _delete),
        ])),
        Section(tr('Help', 'मदद'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.report_rounded), title: Text(tr('Report misuse', 'दुरुपयोग की शिकायत')),
              onTap: () async {
                final m = await askReport(context);
                if (m == null || !context.mounted) return;
                await attempt(context, () => sb.from('abuse_report').insert({
                      'family_id': member?['family_id'], 'reporter': 'guardian', 'reporter_guardian': sb.auth.currentUser!.id, 'message': m}),
                    ok: tr('Report sent. Thank you.', 'शिकायत भेजी गई। धन्यवाद।'));
              }),
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.call), title: const Text('Tele-MANAS 14416'), onTap: () => launchUrl(Uri.parse('tel:14416'))),
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.call), title: const Text('Childline 1098'), onTap: () => launchUrl(Uri.parse('tel:1098'))),
          Text(tr('Grievance officer (DPDP): contact details are published in the privacy notice.', 'शिकायत अधिकारी (DPDP): संपर्क विवरण गोपनीयता सूचना में दिए गए हैं।'), style: const TextStyle(color: K.muted)),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () async { await sb.auth.signOut(); if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst); },
              child: Text(tr('Sign out', 'साइन आउट'))),
        ])),
      ]),
    );
  }
}
