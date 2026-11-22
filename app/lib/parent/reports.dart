import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import '../core.dart';

/// Daily digest (DIG-2/6, design §10.4) with a 90-day calendar, plus the 7-day trend (DASH-6).
class ReportsTab extends StatefulWidget {
  final Map<String, dynamic> child;
  const ReportsTab({super.key, required this.child});
  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  DateTime day = DateTime.now();
  Map<String, dynamic>? digest;
  List<Map<String, dynamic>> week = [];
  bool loading = true;

  String _d(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    final cid = widget.child['id'] as String;
    try {
      final r = await Future.wait([
        sb.from('daily_digest').select().eq('child_id', cid).eq('day', _d(day)).maybeSingle(),
        sb.from('daily_digest').select('day, stats').eq('child_id', cid).gte('day', _d(day.subtract(const Duration(days: 6)))).lte('day', _d(day)).order('day'),
      ]);
      if (mounted) setState(() { digest = r[0] as Map<String, dynamic>?; week = List.from(r[1] as List); loading = false; });
    } catch (e) {
      if (mounted) { toast(context, '$e'); setState(() => loading = false); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.child['nickname'];
    final s = (digest?['stats'] as Map?)?.cast<String, dynamic>();
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        ListTile(
          title: Text('$name · ${day.day}/${day.month}/${day.year}', style: const TextStyle(fontWeight: FontWeight.w600)),
          trailing: IconButton(
            icon: const Icon(Icons.calendar_month_rounded), tooltip: tr('Pick a day', 'दिन चुनें'),
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: day, firstDate: DateTime.now().subtract(const Duration(days: 90)), lastDate: DateTime.now());
              if (d != null) { day = d; load(); }
            },
          ),
        ),
        if (loading) const Loading()
        else if (s == null)
          Section(tr('Digest', 'सारांश'), Text(tr('No digest for this day yet. It arrives every evening around 9 PM.', 'इस दिन का सारांश अभी नहीं है। यह हर शाम लगभग 9 बजे आता है।')))
        else ...[
          if (s['partial'] == true)
            Section(tr('Note', 'नोट'), Text(tr('Partial: the phone was offline, so this only includes what arrived earlier.', 'अधूरा: फ़ोन ऑफ़लाइन था, इसलिए इसमें केवल पहले आई जानकारी है।'))),
          Section(tr('Summary', 'सारांश'), Text('“${digest!['summary_text'] ?? ''}”', style: const TextStyle(fontSize: 16, height: 1.4))),
          Section(tr('Screen time', 'स्क्रीन टाइम'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${hm(s['screenMin'] as num? ?? 0)}${s['vsAvg7'] != null ? '  ${(s['vsAvg7'] as num) >= 0 ? '▲' : '▼'} ${(s['vsAvg7'] as num).abs()}% ${tr('vs 7-day avg', '7 दिन औसत से')}' : ''}',
                style: Theme.of(context).textTheme.titleLarge),
            Text('${tr('Pickups', 'फ़ोन उठाया')} ${s['pickups'] ?? 0} · ${tr('First', 'पहली बार')} ${s['firstUse'] ?? '—'} · ${tr('Last', 'आख़िरी')} ${s['lastUse'] ?? '—'}'),
            if ((s['lateNightMin'] as num? ?? 0) > 0)
              Text('⚠ ${s['lateNightMin']} ${tr('min late at night', 'मिनट देर रात')}', style: const TextStyle(color: K.high)),
            const SizedBox(height: 8),
            for (final a in List<Map>.from(s['topApps'] as List? ?? []))
              Row(children: [Expanded(child: Text('${a['label']}')), Text(hm(a['min'] as num))]),
          ])),
          Section(tr('Categories', 'श्रेणियाँ'), _CategoryBar(Map<String, dynamic>.from(s['categories'] as Map? ?? {}))),
          Section(tr('Risk timeline', 'जोखिम समयरेखा'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if ((s['risks'] as List? ?? []).isEmpty) Text(tr('No alerts.', 'कोई अलर्ट नहीं।')),
            for (final r in List<Map>.from(s['risks'] as List? ?? []))
              ListTile(
                dense: true, contentPadding: EdgeInsets.zero,
                leading: Icon(catOf(r['cat'] as String).icon, color: K.sev(r['sev'] as String)),
                title: Text('${catOf(r['cat'] as String).label} × ${r['count']}'),
                subtitle: Text(List<String>.from((r['times'] as List?)?.whereType<String>() ?? []).join(', ')),
                trailing: SevBadge(r['sev'] as String),
              ),
          ])),
          Section(tr('Other', 'अन्य'), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if ((s['newApps'] as List? ?? []).isNotEmpty)
              Text('${tr('New apps', 'नए ऐप')}: ${(s['newApps'] as List).map((a) => '${a['label']}${a['category'] != null ? ' (${a['category']}) ⚠' : ''}').join(', ')}'),
            Text('${tr('Blocked attempts', 'ब्लॉक किए गए प्रयास')}: ${s['blockedAttempts'] ?? 0}'),
            if ((s['incognitoSessions'] as num? ?? 0) > 0) Text('${tr('Private browsing sessions', 'प्राइवेट ब्राउज़िंग')}: ${s['incognitoSessions']}'),
            if ((s['pausedMin'] as num? ?? 0) > 0) Text('${tr('Monitoring paused', 'निगरानी रुकी')}: ${hm(s['pausedMin'] as num)}', style: const TextStyle(color: K.paused)),
            Text(_visibility(s)),
          ])),
        ],
        Section(tr('Last 7 days', 'पिछले 7 दिन'), _WeekChart(week)),
      ]),
    );
  }

  String _visibility(Map<String, dynamic> s) {
    final screen = (s['screenMin'] as num? ?? 0).toDouble();
    final limited = (s['limitedVisibilityMin'] as num? ?? 0).toDouble();
    final degraded = ((s['health'] as Map?)?['degradedMin'] as num? ?? 0).toDouble();
    if (screen == 0) return '${tr('Visibility', 'दृश्यता')}: —';
    final pct = (100 * (1 - ((limited + degraded) / screen).clamp(0, 1))).round();
    return pct >= 100
        ? '${tr('Visibility', 'दृश्यता')}: 100% ✓'
        : '${tr('Visibility', 'दृश्यता')}: $pct% — ${tr('some apps block screen analysis (e.g. Netflix, banking)', 'कुछ ऐप स्क्रीन जाँच रोकते हैं (जैसे Netflix, बैंकिंग)')}';
  }
}

class _CategoryBar extends StatelessWidget {
  final Map<String, dynamic> c;
  const _CategoryBar(this.c);
  static const colors = {'video': Color(0xFF1F5EFF), 'games': Color(0xFF14B8A6), 'social': Color(0xFFE8590C), 'education': Color(0xFF12B76A),
    'communication': Color(0xFF7C3AED), 'browsing': Color(0xFFF5B400), 'other': Color(0xFF64748B)};
  static String name(String k) => switch (k) {
        'video' => tr('Video', 'वीडियो'), 'games' => tr('Games', 'गेम'), 'social' => tr('Social', 'सोशल'), 'education' => tr('Learning', 'पढ़ाई'),
        'communication' => tr('Chat', 'चैट'), 'browsing' => tr('Browsing', 'ब्राउज़िंग'), _ => tr('Other', 'अन्य'),
      };
  @override
  Widget build(BuildContext context) {
    final entries = c.entries.where((e) => (e.value as num) > 0).toList()..sort((a, b) => (b.value as num).compareTo(a.value as num));
    final total = entries.fold<num>(0, (s, e) => s + (e.value as num));
    if (total == 0) return Text(tr('No usage recorded.', 'कोई उपयोग दर्ज नहीं।'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Row(children: [
          for (final e in entries) Expanded(flex: ((e.value as num) * 1000 / total).round().clamp(1, 1000),
              child: Container(height: 18, color: colors[e.key] ?? K.low)),
        ]),
      ),
      const SizedBox(height: 8),
      // Text summary so the chart is readable with TalkBack too (design §13).
      Wrap(spacing: 12, children: [for (final e in entries) Text('● ${name(e.key)} ${hm(e.value as num)}', style: TextStyle(color: colors[e.key] ?? K.low))]),
    ]);
  }
}

class _WeekChart extends StatelessWidget {
  final List<Map<String, dynamic>> week;
  const _WeekChart(this.week);
  @override
  Widget build(BuildContext context) {
    if (week.isEmpty) return Text(tr('Not enough data yet.', 'अभी पर्याप्त डेटा नहीं।'));
    final mins = [for (final d in week) ((d['stats'] as Map)['screenMin'] as num? ?? 0).toDouble()];
    return Column(children: [
      SizedBox(
        height: 160,
        child: BarChart(BarChartData(
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(), rightTitles: const AxisTitles(), topTitles: const AxisTitles(),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (v, _) {
              final i = v.toInt();
              return i < week.length ? Text((week[i]['day'] as String).substring(8), style: const TextStyle(fontSize: 11)) : const SizedBox();
            })),
          ),
          barGroups: [for (var i = 0; i < mins.length; i++) BarChartGroupData(x: i, barRods: [BarChartRodData(toY: mins[i], color: K.primary, width: 16, borderRadius: BorderRadius.circular(4))])],
        )),
      ),
      Text([for (var i = 0; i < week.length; i++) '${(week[i]['day'] as String).substring(5)}: ${hm(mins[i])}'].join(' · '),
          style: const TextStyle(color: K.muted, fontSize: 12)),
    ]);
  }
}
