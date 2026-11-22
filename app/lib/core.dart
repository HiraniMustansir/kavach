import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ---------- config (flutter run --dart-define-from-file=../.env) ----------

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

SupabaseClient get sb => Supabase.instance.client;
late SharedPreferences prefs;

// ---------- i18n: English + Hindi at launch (KID-6, PRD §8 Localisation) ----------

final lang = ValueNotifier<String>('en');

/// Inline bilingual strings: every UI string is written once in each language, next to where it's used.
String tr(String en, String hi) => lang.value == 'hi' ? hi : en;

Future<void> setLang(String l) async {
  lang.value = l;
  await prefs.setString('lang', l);
}

// ---------- design tokens (design §8.1) ----------

class K {
  static const primary = Color(0xFF1F5EFF);
  static const teal = Color(0xFF14B8A6);
  static const bg = Color(0xFFF6F7FB);
  static const muted = Color(0xFF5B6275);
  static const critical = Color(0xFFD92D20);
  static const high = Color(0xFFE8590C);
  static const medium = Color(0xFFF5B400);
  static const low = Color(0xFF64748B);
  static const ok = Color(0xFF12B76A);
  static const paused = Color(0xFF7C3AED);

  static Color sev(String s) => switch (s) { 'critical' => critical, 'high' => high, 'medium' => medium, _ => low };

  static ThemeData theme(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: primary, brightness: b,
      primary: dark ? const Color(0xFF7FA2FF) : primary,
      secondary: dark ? const Color(0xFF5EEAD4) : teal,
      surface: dark ? const Color(0xFF0F1220) : Colors.white,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? const Color(0xFF090B14) : bg,
      cardTheme: CardThemeData(elevation: dark ? 0 : 1, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
      chipTheme: const ChipThemeData(shape: StadiumBorder()),
    );
  }
}

// ---------- risk taxonomy (PRD §6.5) ----------

class Cat {
  final String code, en, hi;
  final IconData icon;
  const Cat(this.code, this.en, this.hi, this.icon);
  String get label => tr(en, hi);
}

const cats = [
  Cat('SEX', 'Sexual content', 'अश्लील सामग्री', Icons.visibility_off_rounded),
  Cat('CSE', 'Grooming & sextortion', 'ग्रूमिंग और ब्लैकमेल', Icons.shield_rounded),
  Cat('GORE', 'Violence & gore', 'हिंसा', Icons.warning_amber_rounded),
  Cat('SELF', 'Self-harm', 'आत्म-हानि', Icons.volunteer_activism_rounded),
  Cat('STRNG', 'Strangers', 'अजनबी', Icons.person_search_rounded),
  Cat('WEAP', 'Weapons', 'हथियार', Icons.gavel_rounded),
  Cat('DRUG', 'Drugs & alcohol', 'नशा और शराब', Icons.medication_rounded),
  Cat('GAMB', 'Gambling', 'जुआ', Icons.casino_rounded),
  Cat('HATE', 'Hate speech', 'नफ़रत भरी भाषा', Icons.campaign_rounded),
  Cat('BULLY', 'Bullying', 'धमकाना', Icons.sentiment_dissatisfied_rounded),
  Cat('SCAM', 'Scams', 'धोखाधड़ी', Icons.phishing_rounded),
  Cat('HORROR', 'Scary content (under 13)', 'डरावनी सामग्री (13 से कम)', Icons.nights_stay_rounded),
];
const extraCats = [
  Cat('CUSTOM', 'Your keywords', 'आपके कीवर्ड', Icons.flag_rounded),
  Cat('BEH', 'Unusual activity', 'असामान्य गतिविधि', Icons.insights_rounded),
  Cat('SOS', 'SOS', 'SOS', Icons.sos_rounded),
  Cat('TAMPER', 'Protection', 'सुरक्षा', Icons.security_rounded),
];
Cat catOf(String code) => [...cats, ...extraCats].firstWhere((c) => c.code == code, orElse: () => Cat(code, code, code, Icons.flag_rounded));

String sevLabel(String s) => switch (s) {
      'critical' => tr('Critical', 'गंभीर'),
      'high' => tr('High', 'उच्च'),
      'medium' => tr('Medium', 'मध्यम'),
      _ => tr('Low', 'कम'),
    };

String ageBandOf(int birthYear) => DateTime.now().year - birthYear <= 12 ? 'child' : 'teen';

String hm(num minutes) {
  final m = minutes.round();
  return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
}

String clock(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

// ---------- backend calls ----------

class Api {
  /// Calls the `parent` Edge Function (JWT attached by supabase_flutter).
  static Future<Map<String, dynamic>> parent(String route, [Map<String, dynamic>? body]) async {
    try {
      final r = await sb.functions.invoke('parent/$route', body: body ?? {});
      return (r.data as Map).cast<String, dynamic>();
    } on FunctionException catch (e) {
      final d = e.details;
      throw ApiError(d is Map && d['error'] != null ? '${d['error']}' : 'Request failed (${e.status})');
    }
  }

  static Future<List<Map<String, dynamic>>> myFamilies() async =>
      List<Map<String, dynamic>>.from(await sb.from('family_member').select('family_id, role, notify_prefs').eq('guardian_id', sb.auth.currentUser!.id));

  static Future<List<Map<String, dynamic>>> children() async {
    final fams = (await myFamilies()).map((f) => f['family_id']).toList();
    if (fams.isEmpty) return [];
    return List<Map<String, dynamic>>.from(await sb.from('child').select().inFilter('family_id', fams).order('created_at'));
  }

  static Future<Map<String, dynamic>> latestPolicy(String childId) async {
    final r = await sb.from('policy').select('version, body').eq('child_id', childId).order('version', ascending: false).limit(1).maybeSingle();
    return r == null ? defaultPolicy('child') : Map<String, dynamic>.from(r['body'] as Map);
  }

  static Future<void> savePolicy(String childId, Map<String, dynamic> body) => parent('save-policy', {'childId': childId, 'body': body});

  static Future<void> command(String childId, String kind, [Map<String, dynamic>? args]) =>
      parent('command', {'childId': childId, 'kind': kind, 'args': args ?? {}});
}

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}

/// Age-band defaults (PRD §3): Child strict, Teen privacy-respecting (only high-severity realtime).
Map<String, dynamic> defaultPolicy(String band) {
  final child = band == 'child';
  return {
    'ageBand': band,
    'monitoring': {'screenAi': true, 'notifText': false, 'location': false, 'pausedUntil': null},
    'categories': {
      for (final c in cats)
        c.code: {
          'enabled': c.code != 'HORROR' || child,
          'sensitivity': c.code == 'SEX' && child ? 'strict' : 'balanced',
          'realtime': child || ['SEX', 'CSE', 'SELF', 'STRNG', 'GORE'].contains(c.code),
          if (c.code == 'SEX' || c.code == 'GORE') 'intervene': c.code == 'SEX' && child ? 'blur' : 'off',
        }
    },
    'custom': {'keywords': [], 'apps': [], 'domains': []},
    'allow': {'apps': [], 'domains': []},
    'excludedFromCapture': ['com.phonepe.app', 'net.one97.paytm', 'com.google.android.apps.nbu.paisa.user', 'in.org.npci.upiapp', 'com.sbi.lotusintouch'],
    'limits': {
      'dailyTotalMin': child ? {'weekday': 120, 'weekend': 180} : {'weekday': 180, 'weekend': 240},
      'perCategoryMin': {},
      'perAppMin': {},
    },
    'schedules': [
      if (child) {'name': 'School', 'days': [1, 2, 3, 4, 5], 'start': '08:00', 'end': '14:00', 'mode': 'allowListOnly'},
      {'name': 'Bedtime', 'days': [0, 1, 2, 3, 4, 5, 6], 'start': child ? '21:30' : '23:00', 'end': '06:30', 'mode': 'lock'},
    ],
    'blocked': {'apps': [], 'appCategories': child ? ['dating', 'gambling'] : ['gambling'], 'webCategories': ['adult', 'gambling']},
    'behaviour': {'lateNight': {'from': '23:00', 'to': '05:00', 'minMinutes': 15}},
  };
}

// ---------- native agent bridge (Android child mode) ----------

class AgentBridge {
  static const _ch = MethodChannel('app.kavach/agent');
  static Future<T?> call<T>(String m, [Map<String, dynamic>? a]) => _ch.invokeMethod<T>(m, a);
  static Future<Map<String, dynamic>> status() async => Map<String, dynamic>.from(await call<Map>('status') ?? {});
  static Future<Map<String, dynamic>> pair(String token, String? fcm) async =>
      jsonDecode((await call<String>('pair', {'token': token, 'fcmToken': fcm}))!) as Map<String, dynamic>;
}

// ---------- shared widgets ----------

class SevBadge extends StatelessWidget {
  final String severity;
  const SevBadge(this.severity, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = K.sev(severity);
    // Severity never by colour alone (design §8.1): icon + label too.
    final icon = switch (severity) { 'critical' => Icons.error_rounded, 'high' => Icons.warning_rounded, 'medium' => Icons.info_rounded, _ => Icons.circle_outlined };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 4),
        Text(sevLabel(severity).toUpperCase(), style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 11)),
      ]),
    );
  }
}

class Section extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const Section(this.title, this.child, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title.toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: K.muted, letterSpacing: 0.8))),
              ?trailing,
            ]),
            const SizedBox(height: 8),
            child,
          ]),
        ),
      );
}

void toast(BuildContext context, String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

/// Runs an async action with a snackbar on failure; returns true on success.
Future<bool> attempt(BuildContext context, Future<void> Function() f, {String? ok}) async {
  try {
    await f();
    if (ok != null && context.mounted) toast(context, ok);
    return true;
  } catch (e) {
    if (context.mounted) toast(context, '$e');
    return false;
  }
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
}
