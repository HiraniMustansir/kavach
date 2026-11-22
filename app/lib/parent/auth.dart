import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core.dart';

/// ACC-2: phone OTP sign-in (India first). Google/Apple sign-in need provider setup in Supabase first.
class PhoneAuth extends StatefulWidget {
  const PhoneAuth({super.key});
  @override
  State<PhoneAuth> createState() => _PhoneAuthState();
}

class _PhoneAuthState extends State<PhoneAuth> {
  final phone = TextEditingController();
  final code = TextEditingController();
  bool sent = false, busy = false;

  String get e164 {
    final d = phone.text.replaceAll(RegExp(r'[^0-9+]'), '');
    return d.startsWith('+') ? d : '+91$d';
  }

  Future<void> _send() async {
    if (!RegExp(r'^\+\d{10,15}$').hasMatch(e164)) return toast(context, tr('Enter a valid mobile number', 'सही मोबाइल नंबर डालें'));
    setState(() => busy = true);
    final ok = await attempt(context, () => sb.auth.signInWithOtp(phone: e164));
    setState(() { busy = false; sent = ok; });
  }

  Future<void> _verify() async {
    setState(() => busy = true);
    await attempt(context, () => sb.auth.verifyOTP(type: OtpType.sms, phone: e164, token: code.text.trim()));
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Sign in', 'साइन इन'))),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          Text(tr('We’ll text you a code to sign in.', 'साइन इन के लिए हम आपको एक कोड भेजेंगे।')),
          const SizedBox(height: 16),
          TextField(
            controller: phone, enabled: !sent, keyboardType: TextInputType.phone, autofillHints: const [AutofillHints.telephoneNumber],
            decoration: InputDecoration(labelText: tr('Mobile number', 'मोबाइल नंबर'), prefixText: '+91 ', border: const OutlineInputBorder()),
          ),
          if (sent) ...[
            const SizedBox(height: 16),
            TextField(
              controller: code, keyboardType: TextInputType.number, autofillHints: const [AutofillHints.oneTimeCode], maxLength: 6,
              decoration: InputDecoration(labelText: tr('6-digit code', '6 अंकों का कोड'), border: const OutlineInputBorder()),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : (sent ? _verify : _send),
            child: Text(sent ? tr('Verify', 'पुष्टि करें') : tr('Send code', 'कोड भेजें')),
          ),
          if (sent) TextButton(onPressed: () => setState(() => sent = false), child: Text(tr('Change number', 'नंबर बदलें'))),
          const SizedBox(height: 24),
          Text(tr('Kavach is for parents and guardians of children under 18 only.', 'Kavach केवल 18 वर्ष से कम उम्र के बच्चों के माता-पिता और अभिभावकों के लिए है।'),
              style: const TextStyle(color: K.muted)),
        ]),
      );
}

/// ACC-3: name + create the family (guardian row, family, owner membership in one RPC).
class Onboarding extends StatefulWidget {
  final VoidCallback onDone;
  const Onboarding({super.key, required this.onDone});
  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final name = TextEditingController();
  bool adult = false, busy = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Welcome', 'स्वागत है'))),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          TextField(controller: name, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: tr('Your name', 'आपका नाम'), border: const OutlineInputBorder())),
          const SizedBox(height: 16),
          CheckboxListTile(
            value: adult, onChanged: (v) => setState(() => adult = v ?? false),
            title: Text(tr('I am 18 or older and a parent or legal guardian', 'मेरी उम्र 18 या उससे ज़्यादा है और मैं माता-पिता या कानूनी अभिभावक हूँ')),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy || !adult || name.text.trim().isEmpty ? null : () async {
              setState(() => busy = true);
              final ok = await attempt(context, () => sb.rpc('create_family', params: {
                    'p_display_name': name.text.trim(), 'p_locale': lang.value == 'hi' ? 'hi-IN' : 'en-IN'}));
              if (ok) widget.onDone();
              if (mounted) setState(() => busy = false);
            },
            child: Text(tr('Continue', 'आगे बढ़ें')),
          ),
          TextButton(onPressed: () => sb.auth.signOut(), child: Text(tr('Sign out', 'साइन आउट'))),
        ]),
      );
}
