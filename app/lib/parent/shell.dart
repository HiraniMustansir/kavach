import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../core.dart';
import '../main.dart' show fcmToken, firebaseReady;
import 'alerts.dart';
import 'auth.dart';
import 'controls.dart';
import 'family.dart';
import 'home.dart';
import 'reports.dart';
import 'settings.dart';

/// Parent app frame: onboarding check, app lock (ACC-7), child switcher (DASH-1), bottom nav (design §9).
class ParentShell extends StatefulWidget {
  const ParentShell({super.key});
  @override
  State<ParentShell> createState() => _ParentShellState();
}

class _ParentShellState extends State<ParentShell> with WidgetsBindingObserver {
  List<Map<String, dynamic>>? kids;
  bool hasFamily = true;
  String role = 'owner';
  int child = 0, tab = 0;
  bool locked = prefs.getBool('appLock') ?? true;
  DateTime? backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    _registerPush();
    if (locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) backgroundedAt = DateTime.now();
    if (s == AppLifecycleState.resumed && (prefs.getBool('appLock') ?? true) && backgroundedAt != null &&
        DateTime.now().difference(backgroundedAt!) > const Duration(seconds: 30)) {
      setState(() => locked = true);
      _unlock();
    }
  }

  Future<void> _unlock() async {
    final auth = LocalAuthentication();
    try {
      if (!await auth.isDeviceSupported()) return setState(() => locked = false);
      final ok = await auth.authenticate(localizedReason: tr('Unlock Kavach', 'Kavach अनलॉक करें'));
      if (ok) setState(() => locked = false);
    } catch (_) {
      setState(() => locked = false); // no screen lock set up on this phone → nothing to check against
    }
  }

  Future<void> _registerPush() async {
    if (!firebaseReady) return;
    await FirebaseMessaging.instance.requestPermission();
    final t = await fcmToken();
    if (t == null) return;
    await sb.from('guardian_push_token').upsert({
      'token': t, 'guardian_id': sb.auth.currentUser!.id, 'platform': Platform.isIOS ? 'ios' : 'android',
      'updated_at': DateTime.now().toIso8601String(),
    });
    // Tapping an alert notification opens the Alerts tab.
    FirebaseMessaging.onMessageOpenedApp.listen((m) { if (m.data['kind'] == 'alert' && mounted) setState(() => tab = 1); });
    FirebaseMessaging.onMessage.listen((m) {
      final n = m.notification;
      if (n != null && mounted) toast(context, '${n.title ?? ''} · ${n.body ?? ''}');
    });
  }

  Future<void> load() async {
    try {
      final fams = await Api.myFamilies();
      final k = await Api.children();
      setState(() {
        hasFamily = fams.isNotEmpty;
        role = fams.isEmpty ? 'owner' : fams.first['role'] as String;
        kids = k;
        if (child >= k.length) child = 0;
      });
    } catch (e) {
      if (mounted) toast(context, '$e');
      setState(() => kids = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (locked) {
      return Scaffold(body: Center(child: FilledButton.icon(onPressed: _unlock, icon: const Icon(Icons.lock_rounded), label: Text(tr('Unlock', 'अनलॉक')))));
    }
    if (kids == null) return const Scaffold(body: Loading());
    if (!hasFamily) return Onboarding(onDone: load);
    if (kids!.isEmpty) return FamilyScreen(onChanged: load, firstRun: true);

    final c = kids![child];
    final pages = [
      HomeTab(key: ValueKey('h${c['id']}'), child: c, onGoAlerts: () => setState(() => tab = 1)),
      AlertsTab(key: ValueKey('a${c['id']}'), child: c),
      ReportsTab(key: ValueKey('r${c['id']}'), child: c),
      ControlsTab(key: ValueKey('c${c['id']}'), child: c, canEdit: role != 'viewer'),
    ];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (var i = 0; i < kids!.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  avatar: Text(kids![i]['avatar'] as String? ?? '🙂'),
                  label: Text(kids![i]['nickname'] as String),
                  selected: i == child,
                  onSelected: (_) => setState(() => child = i),
                ),
              ),
          ]),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_rounded),
            onSelected: (v) async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => v == 'family' ? FamilyScreen(onChanged: load) : const SettingsScreen()));
              load();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'family', child: Text(tr('Family & devices', 'परिवार और डिवाइस'))),
              PopupMenuItem(value: 'settings', child: Text(tr('Settings', 'सेटिंग्स'))),
            ],
          ),
        ],
      ),
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_rounded), label: tr('Home', 'होम')),
          NavigationDestination(icon: const Icon(Icons.notifications_rounded), label: tr('Alerts', 'अलर्ट')),
          NavigationDestination(icon: const Icon(Icons.insights_rounded), label: tr('Reports', 'रिपोर्ट')),
          NavigationDestination(icon: const Icon(Icons.tune_rounded), label: tr('Controls', 'नियंत्रण')),
        ],
      ),
    );
  }
}
