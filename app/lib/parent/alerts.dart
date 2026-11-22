import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core.dart';

/// ALR-7: history with filters and resolution state.
class AlertsTab extends StatefulWidget {
  final Map<String, dynamic> child;
  const AlertsTab({super.key, required this.child});
  @override
  State<AlertsTab> createState() => _AlertsTabState();
}

class _AlertsTabState extends State<AlertsTab> {
  List<Map<String, dynamic>>? items;
  String? sev, cat;
  bool openOnly = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    var q = sb.from('risk_event').select().eq('child_id', widget.child['id'] as String);
    if (sev != null) q = q.eq('severity', sev!);
    if (cat != null) q = q.eq('category', cat!);
    if (openOnly) q = q.inFilter('status', ['new', 'seen']);
    try {
      final r = await q.order('occurred_at', ascending: false).limit(200);
      if (mounted) setState(() => items = List.from(r));
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: load,
        child: ListView(children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              FilterChip(label: Text(tr('Unresolved', 'अनसुलझे')), selected: openOnly, onSelected: (v) { openOnly = v; load(); }),
              const SizedBox(width: 8),
              for (final s in ['critical', 'high', 'medium', 'low'])
                Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(
                  label: Text(sevLabel(s)), selected: sev == s, onSelected: (v) { sev = v ? s : null; load(); })),
              DropdownButton<String?>(
                value: cat, hint: Text(tr('Category', 'श्रेणी')),
                items: [DropdownMenuItem(value: null, child: Text(tr('All', 'सभी'))),
                  for (final c in [...cats, ...extraCats]) DropdownMenuItem(value: c.code, child: Text(c.label))],
                onChanged: (v) { cat = v; load(); },
              ),
            ]),
          ),
          if (items == null) const Loading()
          else if (items!.isEmpty)
            Padding(padding: const EdgeInsets.all(32), child: Column(children: [
              const Icon(Icons.check_circle_rounded, color: K.teal, size: 48),
              Text(tr('No alerts here.', 'यहाँ कोई अलर्ट नहीं।')),
            ]))
          else
            for (final a in items!) AlertTile(a, onChanged: load),
        ]),
      );
}

class AlertTile extends StatelessWidget {
  final Map<String, dynamic> a;
  final VoidCallback? onChanged;
  const AlertTile(this.a, {super.key, this.onChanged});
  @override
  Widget build(BuildContext context) {
    final c = catOf(a['category'] as String);
    final t = DateTime.parse(a['occurred_at'] as String);
    return ListTile(
      leading: Icon(c.icon, color: K.sev(a['severity'] as String)),
      title: Text(c.label, style: TextStyle(fontWeight: a['status'] == 'new' ? FontWeight.w700 : FontWeight.w500)),
      subtitle: Text('${a['app_label'] ?? a['app_pkg']} · ${_day(t)} ${clock(t)}'),
      trailing: SevBadge(a['severity'] as String),
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => AlertDetail(a)));
        onChanged?.call();
      },
    );
  }

  static String _day(DateTime t) {
    final now = DateTime.now();
    final l = t.toLocal();
    if (l.year == now.year && l.month == now.month && l.day == now.day) return tr('Today', 'आज');
    return '${l.day}/${l.month}';
  }
}

/// Alert detail (design §10.3) with the Critical variant (ALR-3: helplines, support first).
class AlertDetail extends StatefulWidget {
  final Map<String, dynamic> a;
  const AlertDetail(this.a, {super.key});
  @override
  State<AlertDetail> createState() => _AlertDetailState();
}

class _AlertDetailState extends State<AlertDetail> {
  late Map<String, dynamic> a = widget.a;

  @override
  void initState() {
    super.initState();
    if (a['status'] == 'new') _update({'status': 'seen'});
  }

  Future<void> _update(Map<String, dynamic> v) async {
    await sb.from('risk_event').update(v).eq('id', a['id'] as String).eq('occurred_at', a['occurred_at'] as String);
    if (mounted) setState(() => a = {...a, ...v});
  }

  Future<void> _blockApp() async {
    final cid = a['child_id'] as String;
    final pkg = a['app_pkg'] as String;
    await attempt(context, () async {
      final p = await Api.latestPolicy(cid);
      final blocked = Map<String, dynamic>.from(p['blocked'] as Map? ?? {});
      blocked['apps'] = {...List<String>.from(blocked['apps'] as List? ?? []), pkg}.toList();
      await Api.savePolicy(cid, {...p, 'blocked': blocked});
    }, ok: tr('Blocked ${a['app_label'] ?? pkg}', '${a['app_label'] ?? pkg} ब्लॉक किया'));
  }

  Future<void> _blockSite() async {
    final cid = a['child_id'] as String;
    await attempt(context, () async {
      final p = await Api.latestPolicy(cid);
      final custom = Map<String, dynamic>.from(p['custom'] as Map? ?? {});
      custom['domains'] = [...List.from(custom['domains'] as List? ?? []), {'domain': a['domain'], 'action': 'block'}];
      await Api.savePolicy(cid, {...p, 'custom': custom});
    }, ok: tr('Blocked ${a['domain']}', '${a['domain']} ब्लॉक किया'));
  }

  @override
  Widget build(BuildContext context) {
    final c = catOf(a['category'] as String);
    final critical = a['severity'] == 'critical';
    final t = DateTime.parse(a['occurred_at'] as String);
    final selfHarm = a['category'] == 'SELF' || a['category'] == 'SOS';
    return Scaffold(
      appBar: AppBar(title: Text(tr('Alert', 'अलर्ट')), backgroundColor: critical ? K.critical.withValues(alpha: 0.12) : null),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [Icon(c.icon, color: K.sev(a['severity'] as String), size: 32), const SizedBox(width: 12),
          Expanded(child: Text(c.label, style: Theme.of(context).textTheme.titleLarge)), SevBadge(a['severity'] as String)]),
        const SizedBox(height: 8),
        Text('${clock(t)} · ${t.toLocal().day}/${t.toLocal().month}${a['duration_s'] != null ? ' · ~${a['duration_s']}s' : ''}', style: const TextStyle(color: K.muted)),
        Text('${tr('App', 'ऐप')}: ${a['app_label'] ?? a['app_pkg']}${a['domain'] != null ? ' · ${a['domain']}' : ''}'),
        if (a['custom_keyword'] != null) Text('${tr('Your keyword', 'आपका कीवर्ड')}: “${a['custom_keyword']}”'),
        const SizedBox(height: 12),
        Text('${a['description']}', style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        Text(tr('No screenshot is stored — Kavach only keeps what kind of content it was.',
            'कोई स्क्रीनशॉट सेव नहीं होता — Kavach सिर्फ़ सामग्री का प्रकार रखता है।'), style: const TextStyle(color: K.muted)),
        if (critical || selfHarm) ...[
          const SizedBox(height: 16),
          Card(
            color: K.critical.withValues(alpha: 0.08),
            child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('How to help right now', 'अभी कैसे मदद करें'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(tr('Stay calm and check in with your child in person. Listen first; don’t punish. If you think they are in danger, call for help.',
                  'शांत रहें और बच्चे से खुद मिलकर बात करें। पहले सुनें, सज़ा न दें। अगर ख़तरा लगे तो मदद के लिए कॉल करें।')),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton.icon(onPressed: () => launchUrl(Uri.parse('tel:14416')), icon: const Icon(Icons.call), label: const Text('Tele-MANAS 14416')),
                FilledButton.icon(onPressed: () => launchUrl(Uri.parse('tel:1098')), icon: const Icon(Icons.call), label: const Text('Childline 1098')),
                OutlinedButton.icon(onPressed: () => launchUrl(Uri.parse('tel:112')), icon: const Icon(Icons.emergency), label: const Text('112')),
              ]),
            ])),
          ),
        ],
        const SizedBox(height: 16),
        Text(tr('What you can do', 'आप क्या कर सकते हैं'), style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(tr('• Talk calmly about what they saw and how it felt.', '• शांति से बात करें कि उन्होंने क्या देखा और कैसा लगा।')),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (!(a['app_pkg'] as String).startsWith('app.kavach') && a['app_pkg'] != 'android')
            OutlinedButton.icon(onPressed: _blockApp, icon: const Icon(Icons.block), label: Text(tr('Block ${a['app_label'] ?? 'app'}', '${a['app_label'] ?? 'ऐप'} ब्लॉक करें'))),
          if (a['domain'] != null) OutlinedButton.icon(onPressed: _blockSite, icon: const Icon(Icons.public_off), label: Text(tr('Block site', 'साइट ब्लॉक करें'))),
          OutlinedButton.icon(onPressed: () => attempt(context, () => Api.command(a['child_id'] as String, 'lock'), ok: tr('Locked', 'लॉक किया')),
              icon: const Icon(Icons.lock), label: Text(tr('Lock now', 'अभी लॉक करें'))),
        ]),
        const Divider(height: 32),
        Text(tr('Was this alert useful?', 'क्या यह अलर्ट काम का था?')),
        Row(children: [
          ChoiceChip(label: Text(tr('👍 Helpful', '👍 काम का')), selected: a['feedback'] == 'useful', onSelected: (_) => _update({'feedback': 'useful'})),
          const SizedBox(width: 8),
          ChoiceChip(label: Text(tr('Not a problem', 'कोई दिक्कत नहीं')), selected: a['feedback'] == 'not_a_problem',
              onSelected: (_) => _update({'feedback': 'not_a_problem', 'status': 'dismissed'})),
        ]),
        const SizedBox(height: 16),
        if (a['status'] != 'resolved')
          FilledButton(onPressed: () => _update({'status': 'resolved'}), child: Text(tr('Mark as resolved', 'सुलझा हुआ मानें')))
        else
          Text(tr('Resolved ✓', 'सुलझ गया ✓'), style: const TextStyle(color: K.ok)),
      ]),
    );
  }
}
