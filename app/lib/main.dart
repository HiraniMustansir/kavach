import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'child/child_home.dart';
import 'child/child_setup.dart';
import 'core.dart';
import 'parent/auth.dart';
import 'parent/shell.dart';

/// Firebase is optional (no google-services.json → no push, everything else works).
bool firebaseReady = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  lang.value = prefs.getString('lang') ?? (Platform.localeName.startsWith('hi') ? 'hi' : 'en');
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseKey);
  try {
    await Firebase.initializeApp();
    firebaseReady = true;
  } catch (_) {}
  runApp(const KavachApp());
}

Future<String?> fcmToken() async {
  if (!firebaseReady) return null;
  try {
    return await FirebaseMessaging.instance.getToken();
  } catch (_) {
    return null;
  }
}

class KavachApp extends StatelessWidget {
  const KavachApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: lang,
        builder: (_, l, _) => MaterialApp(
          title: 'Kavach',
          debugShowCheckedModeBanner: false,
          theme: K.theme(Brightness.light),
          darkTheme: K.theme(Brightness.dark),
          locale: Locale(l),
          home: const Root(),
        ),
      );
}

/// ACC-1: one app, role chosen on first launch.
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  String? role = prefs.getString('role');
  bool? childPaired;

  @override
  void initState() {
    super.initState();
    if (role == 'child') _checkChild();
    // Tier A: provisioning left a pairing token, so this is definitely the child's phone.
    if (role == null && Platform.isAndroid) {
      AgentBridge.status().then((s) { if (s['pendingToken'] != null) _setRole('child'); });
    }
  }

  Future<void> _checkChild() async {
    final s = await AgentBridge.status();
    if (s['paired'] == true) AgentBridge.call('startAgent');
    setState(() => childPaired = s['paired'] == true);
  }

  Future<void> _setRole(String r) async {
    await prefs.setString('role', r);
    setState(() => role = r);
    if (r == 'child') _checkChild();
  }

  @override
  Widget build(BuildContext context) {
    if (role == 'parent') return const ParentGate();
    if (role == 'child') {
      if (childPaired == null) return const Scaffold(body: Loading());
      return childPaired! ? const ChildHome() : ChildSetup(onPaired: () => setState(() => childPaired = true));
    }
    return RolePicker(onPick: _setRole);
  }
}

class RolePicker extends StatelessWidget {
  final void Function(String) onPick;
  const RolePicker({super.key, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 32),
          const Icon(Icons.shield_rounded, size: 72, color: K.primary),
          const SizedBox(height: 12),
          Text('Kavach', textAlign: TextAlign.center, style: t.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
          Text(tr('Safer screens for your kids', 'बच्चों के लिए सुरक्षित स्क्रीन'), textAlign: TextAlign.center, style: t.titleMedium?.copyWith(color: K.muted)),
          const SizedBox(height: 40),
          _RoleCard(icon: Icons.family_restroom_rounded, title: tr("I'm a parent", 'मैं माता-पिता हूँ'),
              body: tr('Set up and get alerts', 'सेटअप करें और अलर्ट पाएँ'), onTap: () => onPick('parent')),
          const SizedBox(height: 12),
          if (Platform.isAndroid)
            _RoleCard(icon: Icons.smartphone_rounded, title: tr("This is my child's phone", 'यह मेरे बच्चे का फ़ोन है'),
                body: tr('A parent sets this up', 'माता-पिता इसे सेट करते हैं'), onTap: () => onPick('child'))
          else
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(tr(
                "iPhones don't allow screen analysis by other apps. Kavach for a child's iPhone (limits & blocking) is coming. Install Kavach on your child's Android phone instead.",
                'iPhone दूसरे ऐप्स को स्क्रीन देखने नहीं देता। बच्चे के iPhone के लिए Kavach (सीमाएँ और ब्लॉकिंग) जल्द आएगा। अभी बच्चे के Android फ़ोन पर Kavach लगाएँ।')))),
          const SizedBox(height: 32),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton(onPressed: () => setLang('en'), child: const Text('English')),
            const Text('·'),
            TextButton(onPressed: () => setLang('hi'), child: const Text('हिन्दी')),
          ]),
        ]),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final VoidCallback onTap;
  const _RoleCard({required this.icon, required this.title, required this.body, required this.onTap});
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: Icon(icon, size: 36, color: K.primary),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
          subtitle: Text(body),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      );
}

/// Parent mode: sign-in → onboarding → app (behind the app lock).
class ParentGate extends StatelessWidget {
  const ParentGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
        stream: sb.auth.onAuthStateChange,
        builder: (_, _) => sb.auth.currentSession == null ? const PhoneAuth() : const ParentShell(),
      );
}
