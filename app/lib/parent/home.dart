import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core.dart';
import 'alerts.dart';
import 'pairing.dart';

/// Parent home (design §10.2): status, today, alerts, quick actions, pending requests.
class HomeTab extends StatefulWidget {
  final Map<String, dynamic> child;
  final VoidCallback onGoAlerts;
  const HomeTab({super.key, required this.child, required this.onGoAlerts});
  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  List<Map<String, dynamic>>? devices, todayAlerts, requests;
  Timer? timer;
  String get cid => widget.child['id'] as String;

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final start = DateTime.now().copyWith(hour: 0, minute: 0, second: 0).toUtc().toIso8601String();
    try {
      final r = await Future.wait([
        sb.from('device').select().eq('child_id', cid).isFilter('unpaired_at', null).order('paired_at'),
        sb.from('risk_event').select().eq('child_id', cid).gte('occurred_at', start).order('occurred_at', ascending: false),
        sb.from('child_request').select().eq('child_id', cid).eq('status', 'pending').order('created_at', ascending: false),
      ]);
      if (mounted) setState(() { devices = List.from(r[0]); todayAlerts = List.from(r[1]); requests = List.from(r[2]); });
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> _cmd(String kind, [Map<String, dynamic>? args]) => attempt(context, () => Api.command(cid, kind, args),
      ok: tr('Sent to ${widget.child['nickname']}’s phone', '${widget.child['nickname']} के फ़ोन पर भेजा'));

  Future<int?> _pickMinutes(List<int> options) => showModalBottomSheet<int>(
        context: context,
        builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final m in options) ListTile(title: Text(m >= 60 ? hm(m) : '$m min'), onTap: () => Navigator.pop(context, m)),
        ])),
      );

  @override
  Widget build(BuildContext context) {
    if (devices == null) return const Loading();
    final name = widget.child['nickname'] as String;
    final teen = ageBandOf(widget.child['birth_year'] as int) == 'teen';
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        if (devices!.isEmpty)
          Section(tr('Set up', 'सेटअप'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('$name’s phone isn’t connected yet.', '$name का फ़ोन अभी जुड़ा नहीं है।')),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_rounded),
              label: Text(tr('Set up $name’s phone', '$name का फ़ोन सेट करें')),
              onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => PairingScreen(child: widget.child))); load(); },
            ),
          ])),
        for (final d in devices!) _StatusCard(d),
        if (devices!.isNotEmpty) _TodayCard(devices!.first, showLive: !teen),
        _AlertsCard(todayAlerts ?? [], onTap: widget.onGoAlerts),
        for (final r in requests ?? []) _RequestCard(r, onDone: load),
        if (devices!.isNotEmpty)
          Section(tr('Quick actions', 'त्वरित कार्य'), Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: () => _cmd('lock'), icon: const Icon(Icons.lock_rounded), label: Text(tr('Lock now', 'अभी लॉक करें'))),
            OutlinedButton.icon(onPressed: () => _cmd('unlock'), icon: const Icon(Icons.lock_open_rounded), label: Text(tr('Unlock', 'अनलॉक'))),
            OutlinedButton.icon(
              onPressed: () async { final m = await _pickMinutes([15, 30, 60]); if (m != null) _cmd('add_time', {'minutes': m}); },
              icon: const Icon(Icons.more_time_rounded), label: Text(tr('Add time', 'समय जोड़ें'))),
            OutlinedButton.icon(
              onPressed: () async { final m = await _pickMinutes([15, 60, 240, 1440]); if (m != null) _cmd('pause', {'minutes': m}); },
              icon: const Icon(Icons.pause_circle_rounded), label: Text(tr('Pause monitoring', 'निगरानी रोकें'))),
          ])),
      ]),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final Map<String, dynamic> d;
  const _StatusCard(this.d);
  @override
  Widget build(BuildContext context) {
    final state = d['health_state'] as String? ?? 'protected';
    final last = d['last_heartbeat'] == null ? null : DateTime.parse(d['last_heartbeat'] as String);
    final ago = last == null ? '—' : _ago(DateTime.now().difference(last));
    final (color, label, icon) = switch (state) {
      'degraded' => (K.medium, tr('Protection off', 'सुरक्षा बंद'), Icons.gpp_maybe_rounded),
      'offline' => (K.low, tr('Offline', 'ऑफ़लाइन'), Icons.cloud_off_rounded),
      'paused' => (K.paused, tr('Paused', 'रुका हुआ'), Icons.pause_circle_rounded),
      _ => (K.ok, tr('Protected', 'सुरक्षित'), Icons.verified_user_rounded),
    };
    return Section(tr('Status', 'स्थिति'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: 8),
        Text('$label · ${d['model'] ?? 'Android'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      ]),
      const SizedBox(height: 4),
      Text('${tr('Last seen', 'आख़िरी बार')} $ago${d['battery'] != null ? ' · 🔋 ${d['battery']}%' : ''} · ${tr('Tier', 'स्तर')} ${d['tier']}',
          style: const TextStyle(color: K.muted)),
      if (state == 'degraded' && d['health_reason'] != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('${d['health_reason']}', style: TextStyle(color: K.high))),
      if (state == 'degraded')
        TextButton(onPressed: () => _fixSheet(context, d['health_reason'] as String?), child: Text(tr('How to fix', 'कैसे ठीक करें'))),
      if (state == 'offline')
        TextButton(onPressed: () => _whySheet(context), child: Text(tr('Why?', 'क्यों?'))),
    ]));
  }

  static String _ago(Duration d) => d.inMinutes < 1 ? tr('just now', 'अभी') : d.inMinutes < 60 ? '${d.inMinutes} min' : d.inHours < 24 ? '${d.inHours} h' : '${d.inDays} d';

  void _fixSheet(BuildContext ctx, String? reason) => showModalBottomSheet(context: ctx, builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(tr(
            'On your child’s phone open Kavach → Parent area (your PIN) → Diagnostics, and turn the missing permission back on. Reason: ${reason ?? '-'}',
            'बच्चे के फ़ोन पर Kavach खोलें → पैरेंट एरिया (आपका PIN) → डायग्नोस्टिक्स, और बंद हुई अनुमति फिर से चालू करें। कारण: ${reason ?? '-'}')),
      ));

  void _whySheet(BuildContext ctx) => showModalBottomSheet(context: ctx, builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(tr('Common reasons: the phone is switched off, has no internet, or a battery saver stopped Kavach. You were alerted when it went offline.',
            'आम कारण: फ़ोन बंद है, इंटरनेट नहीं है, या बैटरी सेवर ने Kavach रोक दिया। ऑफ़लाइन होने पर आपको बताया गया था।')),
      ));
}

class _TodayCard extends StatelessWidget {
  final Map<String, dynamic> d;
  final bool showLive;
  const _TodayCard(this.d, {required this.showLive});
  @override
  Widget build(BuildContext context) {
    final t = (d['today'] as Map?)?.cast<String, dynamic>() ?? {};
    final used = (t['usedMin'] as num?) ?? 0;
    final left = t['minutesLeft'] as num?;
    final limit = left == null ? null : used + left;
    final apps = List<Map>.from(t['topApps'] as List? ?? []);
    return Section(tr('Today', 'आज'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        SizedBox(
          width: 72, height: 72,
          child: Stack(alignment: Alignment.center, children: [
            CircularProgressIndicator(
              value: limit == null || limit == 0 ? 0 : (used / limit).clamp(0, 1).toDouble(), strokeWidth: 8,
              backgroundColor: K.primary.withValues(alpha: 0.12),
              semanticsLabel: tr('Screen time', 'स्क्रीन टाइम'),
            ),
            Text(hm(used), style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(width: 16),
        Expanded(child: Text(limit == null ? tr('No daily limit', 'कोई सीमा नहीं') : tr('of ${hm(limit)} limit', '${hm(limit)} सीमा में से'),
            style: const TextStyle(color: K.muted))),
      ]),
      const SizedBox(height: 12),
      for (final a in apps)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text('${a['label']}')),
            Text(hm(a['min'] as num), style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        ),
      if (showLive && d['current_app'] != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('${tr('Now', 'अभी')}: ${d['current_app']}', style: const TextStyle(color: K.muted))),
    ]));
  }
}

class _AlertsCard extends StatelessWidget {
  final List<Map<String, dynamic>> alerts;
  final VoidCallback onTap;
  const _AlertsCard(this.alerts, {required this.onTap});
  @override
  Widget build(BuildContext context) {
    final open = alerts.where((a) => a['status'] == 'new' || a['status'] == 'seen').toList();
    int n(String s) => open.where((a) => a['severity'] == s).length;
    final top = alerts.where((a) => a['severity'] != 'low').take(3);
    return Section(tr('Alerts today', 'आज के अलर्ट'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (alerts.isEmpty)
        Row(children: [
          const Icon(Icons.check_circle_rounded, color: K.teal),
          const SizedBox(width: 8),
          Text(tr('Nothing worrying today.', 'आज कुछ चिंता की बात नहीं।')),
        ])
      else ...[
        Wrap(spacing: 12, children: [
          Text('${n('critical')} ${tr('critical', 'गंभीर')}', style: const TextStyle(color: K.critical, fontWeight: FontWeight.w600)),
          Text('${n('high')} ${tr('high', 'उच्च')}', style: const TextStyle(color: K.high, fontWeight: FontWeight.w600)),
          Text('${n('medium')} ${tr('medium', 'मध्यम')}', style: const TextStyle(color: K.muted, fontWeight: FontWeight.w600)),
        ]),
        for (final a in top) AlertTile(a),
        TextButton(onPressed: onTap, child: Text(tr('All alerts', 'सभी अलर्ट'))),
      ],
    ]));
  }
}

/// CTL-7: approve or deny a child's request.
class _RequestCard extends StatelessWidget {
  final Map<String, dynamic> r;
  final VoidCallback onDone;
  const _RequestCard(this.r, {required this.onDone});
  @override
  Widget build(BuildContext context) {
    final title = r['kind'] == 'more_time' ? tr('Asks for ${r['minutes']} more minutes', '${r['minutes']} मिनट और माँग रहा है') : tr('Asks for an app', 'एक ऐप माँग रहा है');
    Future<void> decide(bool ok) async {
      await attempt(context, () => Api.parent('decide-request', {'requestId': r['id'], 'approve': ok}));
      onDone();
    }
    return Section(tr('Request', 'अनुरोध'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      if (r['reason'] != null || r['app_pkg'] != null) Text([r['app_pkg'], r['reason']].whereType<String>().join(' · '), style: const TextStyle(color: K.muted)),
      Row(children: [
        FilledButton(onPressed: () => decide(true), child: Text(tr('Approve', 'मंज़ूर'))),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: () => decide(false), child: Text(tr('Deny', 'मना करें'))),
      ]),
    ]));
  }
}
