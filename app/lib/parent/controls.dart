import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core.dart';

/// Controls (design §10.5, SET-1, CTL-1/2/3/5, CLS-6/7): edits the child's policy and saves a new version.
class ControlsTab extends StatefulWidget {
  final Map<String, dynamic> child;
  final bool canEdit;
  const ControlsTab({super.key, required this.child, required this.canEdit});
  @override
  State<ControlsTab> createState() => _ControlsTabState();
}

class _ControlsTabState extends State<ControlsTab> {
  Map<String, dynamic>? p;
  String saved = '';
  Map<String, String> knownApps = {}; // pkg → label, from recent digests / today
  String get cid => widget.child['id'] as String;
  bool get dirty => p != null && jsonEncode(p) != saved;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final pol = await Api.latestPolicy(cid);
    final digests = await sb.from('daily_digest').select('stats').eq('child_id', cid).order('day', ascending: false).limit(7);
    final devs = await sb.from('device').select('today').eq('child_id', cid);
    final apps = <String, String>{};
    for (final d in [...digests.map((d) => d['stats']), ...devs.map((d) => d['today'])]) {
      for (final a in List<Map>.from((d as Map?)?['topApps'] as List? ?? [])) {
        if (a['pkg'] != null) apps[a['pkg'] as String] = a['label'] as String;
      }
    }
    if (mounted) setState(() { p = pol; saved = jsonEncode(pol); knownApps = apps; });
  }

  Future<void> save() async {
    if (await attempt(context, () => Api.savePolicy(cid, p!), ok: tr('Saved. The phone updates in a few seconds.', 'सेव हुआ। फ़ोन कुछ सेकंड में अपडेट होगा।'))) {
      setState(() => saved = jsonEncode(p));
    }
  }

  Map<String, dynamic> _obj(String k) => p![k] = Map<String, dynamic>.from(p![k] as Map? ?? {});
  List _list(Map<String, dynamic> m, String k) => m[k] = List.from(m[k] as List? ?? []);
  void set(VoidCallback f) => setState(f);

  @override
  Widget build(BuildContext context) {
    if (p == null) return const Loading();
    final teen = ageBandOf(widget.child['birth_year'] as int) == 'teen';
    final categories = _obj('categories');
    final limits = _obj('limits');
    final daily = Map<String, dynamic>.from(limits['dailyTotalMin'] as Map? ?? {});
    final perApp = Map<String, dynamic>.from(limits['perAppMin'] as Map? ?? {});
    final custom = _obj('custom');
    final allow = _obj('allow');
    final blocked = _obj('blocked');
    final monitoring = _obj('monitoring');

    return Stack(children: [
      AbsorbPointer(
        absorbing: !widget.canEdit,
        child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          if (!widget.canEdit) Section(tr('View only', 'केवल देखें'), Text(tr('Viewers can’t change rules.', 'व्यूअर नियम नहीं बदल सकते।'))),
          Section(tr('What to watch for', 'किस पर नज़र रखें'), Column(children: [
            for (final c in cats.where((c) => c.code != 'HORROR' || !teen)) _catRow(c, categories),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Show a “go back” screen on explicit content', 'अश्लील सामग्री पर “वापस जाएँ” स्क्रीन दिखाएँ')),
              value: (categories['SEX'] as Map?)?['intervene'] == 'blur',
              onChanged: (v) => set(() => categories['SEX'] = {...Map.from(categories['SEX'] as Map? ?? {}), 'intervene': v ? 'blur' : 'off'}),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('…and on graphic violence', '…और हिंसक सामग्री पर')),
              value: (categories['GORE'] as Map?)?['intervene'] == 'blur',
              onChanged: (v) => set(() => categories['GORE'] = {...Map.from(categories['GORE'] as Map? ?? {}), 'intervene': v ? 'blur' : 'off'}),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Check message notifications for grooming signs', 'मैसेज नोटिफ़िकेशन में ग्रूमिंग के संकेत जाँचें')),
              subtitle: Text(tr('Text is checked on the phone and thrown away. Needs notification access on the phone.', 'टेक्स्ट फ़ोन पर ही जाँच कर हटा दिया जाता है।')),
              value: monitoring['notifText'] == true,
              onChanged: (v) => set(() => monitoring['notifText'] = v),
            ),
          ])),
          Section(tr('Screen time', 'स्क्रीन टाइम'), Column(children: [
            _minutesRow(tr('Weekdays', 'सप्ताह के दिन'), daily['weekday'] as int?, (v) => set(() { daily['weekday'] = v; limits['dailyTotalMin'] = daily; })),
            _minutesRow(tr('Weekends', 'सप्ताहांत'), daily['weekend'] as int?, (v) => set(() { daily['weekend'] = v; limits['dailyTotalMin'] = daily; })),
            const Divider(),
            for (final e in perApp.entries)
              _minutesRow(knownApps[e.key] ?? e.key, e.value as int?, (v) => set(() {
                if (v == null) { perApp.remove(e.key); } else { perApp[e.key] = v; }
                limits['perAppMin'] = perApp;
              })),
            _addAppButton(tr('Add an app limit', 'ऐप की सीमा जोड़ें'), exclude: perApp.keys.toSet(), onPick: (pkg) => set(() { perApp[pkg] = 45; limits['perAppMin'] = perApp; })),
          ])),
          Section(tr('Schedules', 'समय-सारिणी'), Column(children: [
            for (final s in _list(p!, 'schedules')) _scheduleRow(Map<String, dynamic>.from(s as Map), (ns) => set(() {
              final l = _list(p!, 'schedules'); final i = l.indexOf(s);
              if (ns == null) { l.removeAt(i); } else { l[i] = ns; }
            })),
            TextButton.icon(
              icon: const Icon(Icons.add), label: Text(tr('Add schedule', 'समय-सारिणी जोड़ें')),
              onPressed: () => set(() => _list(p!, 'schedules').add({'name': tr('Homework', 'होमवर्क'), 'days': [1, 2, 3, 4, 5], 'start': '17:00', 'end': '19:00', 'mode': 'allowListOnly'})),
            ),
          ])),
          Section(tr('Blocked', 'ब्लॉक'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, children: [
              for (final c in ['dating', 'gambling', 'vault', 'vpn', 'second_space'])
                FilterChip(
                  label: Text(switch (c) { 'dating' => tr('Dating apps', 'डेटिंग ऐप'), 'gambling' => tr('Real-money games', 'पैसे वाले गेम'),
                    'vault' => tr('Hidden vaults', 'छिपे वॉल्ट'), 'vpn' => 'VPN', _ => tr('Dual-space apps', 'ड्यूल स्पेस ऐप') }),
                  selected: _list(blocked, 'appCategories').contains(c),
                  onSelected: (v) => set(() { final l = _list(blocked, 'appCategories'); v ? l.add(c) : l.remove(c); }),
                ),
            ]),
            for (final pkg in _list(blocked, 'apps'))
              ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.block), title: Text(knownApps[pkg] ?? '$pkg'),
                  trailing: IconButton(icon: const Icon(Icons.close), tooltip: tr('Unblock', 'अनब्लॉक'), onPressed: () => set(() => _list(blocked, 'apps').remove(pkg)))),
            _addAppButton(tr('Block an app', 'ऐप ब्लॉक करें'), exclude: _list(blocked, 'apps').cast<String>().toSet(), onPick: (pkg) => set(() => _list(blocked, 'apps').add(pkg))),
            _stringList(tr('Blocked sites', 'ब्लॉक साइटें'), _list(custom, 'domains').where((d) => (d as Map)['action'] == 'block').map((d) => (d as Map)['domain'] as String).toList(),
                hint: 'example.com',
                onAdd: (v) => set(() => _list(custom, 'domains').add({'domain': v.toLowerCase(), 'action': 'block'})),
                onRemove: (v) => set(() => _list(custom, 'domains').removeWhere((d) => (d as Map)['domain'] == v))),
          ])),
          Section(tr('Your keywords', 'आपके कीवर्ड'), _stringList('', _list(custom, 'keywords').map((k) => (k as Map)['text'] as String).toList(),
              hint: tr('e.g. meet me', 'जैसे मिलने आओ'),
              onAdd: (v) => set(() => _list(custom, 'keywords').add({'text': v, 'match': 'fuzzy', 'action': 'alert'})),
              onRemove: (v) => set(() => _list(custom, 'keywords').removeWhere((k) => (k as Map)['text'] == v)))),
          Section(tr('Always allowed', 'हमेशा अनुमति'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('These never alert and stay open during school time and downtime.', 'इन पर कभी अलर्ट नहीं आता और ये स्कूल/डाउनटाइम में भी खुलते हैं।'), style: const TextStyle(color: K.muted)),
            for (final pkg in _list(allow, 'apps'))
              ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.check_circle_outline), title: Text(knownApps[pkg] ?? '$pkg'),
                  trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => set(() => _list(allow, 'apps').remove(pkg)))),
            _addAppButton(tr('Allow an app', 'ऐप को अनुमति दें'), exclude: _list(allow, 'apps').cast<String>().toSet(), onPick: (pkg) => set(() => _list(allow, 'apps').add(pkg))),
            _stringList(tr('Allowed sites', 'अनुमत साइटें'), _list(allow, 'domains').cast<String>(), hint: 'khanacademy.org',
                onAdd: (v) => set(() => _list(allow, 'domains').add(v.toLowerCase())), onRemove: (v) => set(() => _list(allow, 'domains').remove(v))),
          ])),
          Section(tr('Never look at', 'कभी न देखें'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Kavach never reads or checks these screens (e.g. banking/UPI).', 'Kavach इन स्क्रीन को कभी नहीं पढ़ता (जैसे बैंकिंग/UPI)।'), style: const TextStyle(color: K.muted)),
            for (final pkg in _list(p!, 'excludedFromCapture'))
              ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.visibility_off_outlined), title: Text(knownApps[pkg] ?? '$pkg'),
                  trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => set(() => _list(p!, 'excludedFromCapture').remove(pkg)))),
            _addAppButton(tr('Add an app', 'ऐप जोड़ें'), exclude: _list(p!, 'excludedFromCapture').cast<String>().toSet(),
                onPick: (pkg) => set(() => _list(p!, 'excludedFromCapture').add(pkg))),
          ])),
        ]),
      ),
      if (dirty && widget.canEdit)
        Positioned(left: 16, right: 16, bottom: 16, child: FilledButton.icon(onPressed: save, icon: const Icon(Icons.save_rounded), label: Text(tr('Save changes', 'बदलाव सेव करें')))),
    ]);
  }

  Widget _catRow(Cat c, Map<String, dynamic> categories) {
    final m = Map<String, dynamic>.from(categories[c.code] as Map? ?? {'enabled': true, 'sensitivity': 'balanced', 'realtime': true});
    void put(String k, Object v) => set(() => categories[c.code] = {...m, k: v});
    return Column(children: [
      Row(children: [
        Icon(c.icon, color: K.primary),
        const SizedBox(width: 12),
        Expanded(child: Text(c.label)),
        Switch(value: m['enabled'] != false, onChanged: (v) => put('enabled', v)),
      ]),
      if (m['enabled'] != false)
        Padding(
          padding: const EdgeInsets.only(left: 36, bottom: 8),
          child: Row(children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 'relaxed', label: Text(tr('Relaxed', 'ढीला'))),
                ButtonSegment(value: 'balanced', label: Text(tr('Balanced', 'संतुलित'))),
                ButtonSegment(value: 'strict', label: Text(tr('Strict', 'सख़्त'))),
              ],
              selected: {m['sensitivity'] as String? ?? 'balanced'},
              onSelectionChanged: (s) => put('sensitivity', s.first),
            ),
            const SizedBox(width: 8),
            Expanded(child: CheckboxListTile(
              dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
              title: Text(tr('Alert now', 'तुरंत बताएँ')), value: m['realtime'] != false, onChanged: (v) => put('realtime', v ?? true),
            )),
          ]),
        ),
    ]);
  }

  Widget _minutesRow(String label, int? value, void Function(int?) onChanged) => Row(children: [
        Expanded(child: Text(label)),
        DropdownButton<int?>(
          value: value,
          items: [
            DropdownMenuItem(value: null, child: Text(tr('No limit', 'कोई सीमा नहीं'))),
            for (final m in [15, 30, 45, 60, 90, 120, 150, 180, 240, 300]) DropdownMenuItem(value: m, child: Text(hm(m))),
            if (value != null && ![15, 30, 45, 60, 90, 120, 150, 180, 240, 300].contains(value)) DropdownMenuItem(value: value, child: Text(hm(value))),
          ],
          onChanged: onChanged,
        ),
      ]);

  Widget _scheduleRow(Map<String, dynamic> s, void Function(Map<String, dynamic>?) onChanged) {
    const days = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    Future<String?> pick(String cur) async {
      final parts = cur.split(':');
      final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])));
      return t == null ? null : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    final ds = List<int>.from(s['days'] as List? ?? []);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.w600))),
        IconButton(icon: const Icon(Icons.delete_outline), tooltip: tr('Remove', 'हटाएँ'), onPressed: () => onChanged(null)),
      ]),
      Row(children: [
        TextButton(onPressed: () async { final v = await pick(s['start'] as String); if (v != null) onChanged({...s, 'start': v}); }, child: Text('${s['start']}')),
        const Text('→'),
        TextButton(onPressed: () async { final v = await pick(s['end'] as String); if (v != null) onChanged({...s, 'end': v}); }, child: Text('${s['end']}')),
        const Spacer(),
        DropdownButton<String>(
          value: s['mode'] as String,
          items: [
            DropdownMenuItem(value: 'lock', child: Text(tr('Lock phone', 'फ़ोन लॉक'))),
            DropdownMenuItem(value: 'allowListOnly', child: Text(tr('Allowed apps only', 'केवल अनुमत ऐप'))),
          ],
          onChanged: (v) => onChanged({...s, 'mode': v}),
        ),
      ]),
      Wrap(spacing: 4, children: [
        for (var i = 0; i < 7; i++)
          FilterChip(label: Text(days[i]), selected: ds.contains(i), onSelected: (v) => onChanged({...s, 'days': v ? [...ds, i] : (ds..remove(i))})),
      ]),
      const Divider(),
    ]);
  }

  Widget _addAppButton(String label, {required Set<String> exclude, required void Function(String) onPick}) => TextButton.icon(
        icon: const Icon(Icons.add),
        label: Text(label),
        onPressed: () async {
          final ctrl = TextEditingController();
          final options = knownApps.entries.where((e) => !exclude.contains(e.key)).toList();
          final pkg = await showModalBottomSheet<String>(context: context, isScrollControlled: true, builder: (_) => SafeArea(child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text(tr('Apps your child used recently', 'हाल में इस्तेमाल किए गए ऐप'), style: const TextStyle(fontWeight: FontWeight.w600))),
              if (options.isEmpty) ListTile(title: Text(tr('None yet — they appear after the first day of use.', 'अभी कोई नहीं — पहले दिन के बाद दिखेंगे।'))),
              for (final e in options) ListTile(title: Text(e.value), subtitle: Text(e.key), onTap: () => Navigator.pop(context, e.key)),
              Padding(padding: const EdgeInsets.all(16), child: TextField(
                controller: ctrl,
                decoration: InputDecoration(labelText: tr('Or package name', 'या पैकेज नाम'), hintText: 'com.example.app', border: const OutlineInputBorder()),
                onSubmitted: (v) => Navigator.pop(context, v.trim()),
              )),
            ]),
          )));
          if (pkg != null && RegExp(r'^[a-zA-Z][\w]*(\.[\w]+)+$').hasMatch(pkg)) onPick(pkg);
        },
      );

  Widget _stringList(String title, List<String> items, {required String hint, required void Function(String) onAdd, required void Function(String) onRemove}) {
    final ctrl = TextEditingController();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (title.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
      Wrap(spacing: 8, children: [for (final i in items) InputChip(label: Text(i), onDeleted: () => onRemove(i))]),
      TextField(
        controller: ctrl,
        decoration: InputDecoration(hintText: hint, suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () {
          if (ctrl.text.trim().isNotEmpty) onAdd(ctrl.text.trim());
        })),
        onSubmitted: (v) { if (v.trim().isNotEmpty) onAdd(v.trim()); },
      ),
    ]);
  }
}
