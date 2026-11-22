import 'package:material_ui/material_ui.dart';

import '../core.dart';
import 'pairing.dart';

/// Family (design §9): children, their devices, guardians. Adding a child runs the consent step (VPC-1..4).
class FamilyScreen extends StatefulWidget {
  final VoidCallback onChanged;
  final bool firstRun;
  const FamilyScreen({super.key, required this.onChanged, this.firstRun = false});
  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  List<Map<String, dynamic>>? kids, devices, members;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final k = await Api.children();
    final ids = k.map((c) => c['id']).toList();
    final d = ids.isEmpty ? [] : await sb.from('device').select().inFilter('child_id', ids).isFilter('unpaired_at', null);
    final fams = await Api.myFamilies();
    final m = fams.isEmpty ? [] : await sb.from('family_member').select('role, guardian(display_name, phone_e164)').eq('family_id', fams.first['family_id'] as String);
    if (mounted) setState(() { kids = k; devices = List.from(d); members = List.from(m); });
  }

  Future<void> _add() async {
    final added = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const AddChildScreen()));
    if (added == true) { await load(); widget.onChanged(); }
  }

  @override
  Widget build(BuildContext context) {
    final body = kids == null ? const Loading() : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      if (widget.firstRun)
        Section(tr('Get started', 'शुरू करें'), Text(tr('Add your child to set up their phone.', 'फ़ोन सेट करने के लिए अपने बच्चे को जोड़ें।'))),
      Section(tr('Children', 'बच्चे'), Column(children: [
        for (final c in kids!)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            leading: Text(c['avatar'] as String? ?? '🙂', style: const TextStyle(fontSize: 28)),
            title: Text(c['nickname'] as String),
            subtitle: Text('${tr('Born', 'जन्म')} ${c['birth_year']} · ${ageBandOf(c['birth_year'] as int) == 'child' ? tr('Child', 'बच्चा') : tr('Teen', 'किशोर')}'),
            children: [
              for (final d in devices!.where((d) => d['child_id'] == c['id']))
                ListTile(
                  leading: const Icon(Icons.smartphone_rounded),
                  title: Text('${d['model'] ?? 'Android'} · ${tr('Tier', 'स्तर')} ${d['tier']}'),
                  subtitle: Text('${d['health_state']}'),
                  trailing: TextButton(
                    child: Text(tr('Remove', 'हटाएँ')),
                    onPressed: () async {
                      final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
                        title: Text(tr('Remove Kavach from this phone?', 'इस फ़ोन से Kavach हटाएँ?')),
                        content: Text(tr('Protection stops and the phone goes back to normal (PAIR-6).', 'सुरक्षा बंद होगी और फ़ोन सामान्य हो जाएगा।')),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel', 'रद्द करें'))),
                          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Remove', 'हटाएँ'))),
                        ],
                      ));
                      if (ok == true && context.mounted) { await attempt(context, () => Api.command(c['id'] as String, 'unpair')); load(); }
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add_to_home_screen_rounded),
                title: Text(tr('Set up a phone', 'फ़ोन सेट करें')),
                onTap: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => PairingScreen(child: c))); load(); },
              ),
            ],
          ),
        TextButton.icon(onPressed: _add, icon: const Icon(Icons.person_add_rounded), label: Text(tr('Add child', 'बच्चा जोड़ें'))),
      ])),
      Section(tr('Guardians', 'अभिभावक'), Column(children: [
        for (final m in members!)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_rounded),
            title: Text('${(m['guardian'] as Map?)?['display_name'] ?? '—'}'),
            subtitle: Text('${m['role']}'),
          ),
        Text(tr('Inviting a co-guardian is coming soon.', 'सह-अभिभावक को जोड़ना जल्द आएगा।'), style: const TextStyle(color: K.muted)),
      ])),
    ]);
    return Scaffold(appBar: AppBar(title: Text(tr('Family & devices', 'परिवार और डिवाइस'))), body: body);
  }
}

/// ACC-4 + VPC-1..4: nickname, birth year (not DOB), avatar → itemised consent → default policy for the age band.
class AddChildScreen extends StatefulWidget {
  const AddChildScreen({super.key});
  @override
  State<AddChildScreen> createState() => _AddChildScreenState();
}

class _AddChildScreenState extends State<AddChildScreen> {
  final name = TextEditingController();
  int year = DateTime.now().year - 10;
  String avatar = '🙂';
  bool busy = false, agree = false;
  final scopes = {'screen_ai': true, 'usage': true, 'notif': false, 'location': false};
  static const noticeVersion = '2026-11-22';

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().year;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Add child', 'बच्चा जोड़ें'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: tr('Nickname', 'उपनाम'), helperText: tr('A nickname is fine', 'उपनाम काफ़ी है'), border: const OutlineInputBorder())),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text(tr('Birth year', 'जन्म वर्ष'))),
          DropdownButton<int>(value: year, items: [for (var y = now; y >= now - 17; y--) DropdownMenuItem(value: y, child: Text('$y'))], onChanged: (v) => setState(() => year = v!)),
        ]),
        Wrap(spacing: 8, children: [
          for (final a in ['🙂', '🦁', '🐯', '🦊', '🐼', '🚀', '⚽', '🎨', '🌸', '🎮'])
            ChoiceChip(label: Text(a, style: const TextStyle(fontSize: 22)), selected: avatar == a, onSelected: (_) => setState(() => avatar = a)),
        ]),
        const Divider(height: 32),
        Text(tr('What Kavach collects (consent notice v$noticeVersion)', 'Kavach क्या जानकारी लेता है (सहमति सूचना v$noticeVersion)'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(tr(
          'On the child’s phone only: what is on screen is checked by on-device AI. Screenshots, messages and typed text never leave the phone.\n'
          'Sent to us: the type of content found (e.g. “violence”), the app name, website domain, time, and screen-time totals.\n'
          'Kept: alerts 90 days, daily summaries 1 year, this consent record as the law requires. You can export or delete everything in Settings.\n'
          'Grievance officer: see Settings → Help. You can change or withdraw consent at any time.',
          'केवल बच्चे के फ़ोन पर: स्क्रीन पर क्या है, यह फ़ोन पर ही AI जाँचता है। स्क्रीनशॉट, मैसेज और टाइप किया गया टेक्स्ट फ़ोन से बाहर नहीं जाते।\n'
          'हमें भेजा जाता है: मिली सामग्री का प्रकार (जैसे “हिंसा”), ऐप का नाम, वेबसाइट डोमेन, समय और स्क्रीन-टाइम।\n'
          'रखा जाता है: अलर्ट 90 दिन, दैनिक सारांश 1 साल, यह सहमति रिकॉर्ड क़ानून के अनुसार। सेटिंग्स में आप सब एक्सपोर्ट या डिलीट कर सकते हैं।\n'
          'शिकायत अधिकारी: सेटिंग्स → मदद देखें। आप कभी भी सहमति बदल या वापस ले सकते हैं।')),
        SwitchListTile(value: scopes['screen_ai']!, onChanged: (v) => setState(() => scopes['screen_ai'] = v),
            title: Text(tr('Screen content analysis (on the phone)', 'स्क्रीन सामग्री की जाँच (फ़ोन पर)'))),
        SwitchListTile(value: scopes['usage']!, onChanged: (v) => setState(() => scopes['usage'] = v), title: Text(tr('App usage and screen time', 'ऐप उपयोग और स्क्रीन टाइम'))),
        SwitchListTile(value: scopes['notif']!, onChanged: (v) => setState(() => scopes['notif'] = v), title: Text(tr('Message notification checks', 'मैसेज नोटिफ़िकेशन जाँच'))),
        SwitchListTile(value: scopes['location']!, onChanged: (v) => setState(() => scopes['location'] = v), title: Text(tr('Location with SOS', 'SOS के साथ लोकेशन'))),
        CheckboxListTile(
          value: agree, onChanged: (v) => setState(() => agree = v ?? false), controlAffinity: ListTileControlAffinity.leading,
          title: Text(tr('I am this child’s parent or legal guardian and I give consent for the items switched on above.',
              'मैं इस बच्चे का माता-पिता/कानूनी अभिभावक हूँ और ऊपर चालू की गई चीज़ों के लिए सहमति देता/देती हूँ।')),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: busy || !agree || name.text.trim().isEmpty ? null : _save,
          child: Text(tr('Add child', 'बच्चा जोड़ें')),
        ),
      ]),
    );
  }

  Future<void> _save() async {
    setState(() => busy = true);
    final ok = await attempt(context, () async {
      final fam = (await Api.myFamilies()).firstWhere((f) => f['role'] != 'viewer');
      final c = await sb.from('child').insert({'family_id': fam['family_id'], 'nickname': name.text.trim(), 'birth_year': year, 'avatar': avatar}).select().single();
      // VPC-4: immutable consent record. shortcut: OTP-verified account + age declaration; DigiLocker age token per counsel (PRD §15 Q1).
      await sb.from('consent_record').insert({
        'family_id': fam['family_id'], 'guardian_id': sb.auth.currentUser!.id, 'child_id': c['id'],
        'notice_version': noticeVersion, 'scopes': scopes, 'verification_method': 'otp_age_decl',
      });
      final p = defaultPolicy(ageBandOf(year));
      (p['monitoring'] as Map)['screenAi'] = scopes['screen_ai'];
      (p['monitoring'] as Map)['notifText'] = scopes['notif'];
      (p['monitoring'] as Map)['location'] = scopes['location'];
      await Api.savePolicy(c['id'] as String, p);
    });
    if (!mounted) return;
    setState(() => busy = false);
    if (ok) Navigator.pop(context, true);
  }
}
