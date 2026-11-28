// İlk Aktivasyon (§24.2, W6 local): the person types the one-time code the
// owner created in Windows › Kullanıcılar, chooses their own password and
// this phone's 5-digit PIN. Windows checks everything; nothing is decided
// on the phone.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pos_api.dart';
import 'style.dart';

/// Formats input as XXXX-XXXX from the code alphabet (no 0/O/1/I/L).
class ActivationCodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final clipped = raw.length > 8 ? raw.substring(0, 8) : raw;
    final text = clipped.length > 4 ? '${clipped.substring(0, 4)}-${clipped.substring(4)}' : clipped;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

class ActivationPage extends StatefulWidget {
  const ActivationPage({super.key, required this.api});
  final NohutApi api;
  @override
  State<ActivationPage> createState() => _ActivationPageState();
}

class _ActivationPageState extends State<ActivationPage> {
  final user = TextEditingController(), code = TextEditingController();
  final pass = TextEditingController(), pass2 = TextEditingController();
  final pin = TextEditingController(), pin2 = TextEditingController();
  String? error;
  bool busy = false, showPass = false;

  @override
  void dispose() {
    for (final c in [user, code, pass, pass2, pin, pin2]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _check() {
    if (user.text.trim().length < 3) return 'Kullanıcı adınızı girin.';
    if (code.text.replaceAll('-', '').length != 8) return 'Aktivasyon kodu 8 karakterdir.';
    if (pass.text.length < 8) return 'Şifre en az 8 karakter olmalı.';
    if (pass.text != pass2.text) return 'Şifreler aynı değil.';
    if (!RegExp(r'^[0-9]{5}$').hasMatch(pin.text)) return 'PIN 5 rakam olmalı.';
    if (pin.text != pin2.text) return 'PIN’ler aynı değil.';
    return null;
  }

  Future<void> _submit() async {
    final problem = _check();
    if (problem != null) {
      HapticFeedback.heavyImpact();
      setState(() => error = problem);
      return;
    }
    setState(() { busy = true; error = null; });
    try {
      await widget.api.activate(username: user.text, code: code.text,
          password: pass.text, pin: pin.text);
      HapticFeedback.lightImpact();
      if (mounted) Navigator.of(context).pop(true);
    } on FormatException catch (e) {
      HapticFeedback.heavyImpact();
      if (mounted) setState(() { busy = false; error = e.message; });
    } catch (_) {
      if (mounted) setState(() { busy = false; error = 'Laptop bağlantısı kurulamadı.'; });
    }
  }

  Widget _step(int n, String title, String hint, List<Widget> fields) {
    final nc = context.nohut;
    return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        CircleAvatar(radius: 13, backgroundColor: nc.heading,
          child: Text('$n', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary,
            fontWeight: FontWeight.w800, fontSize: 13))),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
      ]),
      Padding(padding: const EdgeInsets.only(top: 4, bottom: 12, left: 36),
        child: Text(hint, style: TextStyle(color: nc.muted, fontSize: 13))),
      ...fields,
    ])));
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 10);
    return Scaffold(
      appBar: AppBar(title: const Text('Hesabımı Etkinleştir')),
      body: AutofillGroup(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        _step(1, 'Kodunuz', 'Yöneticinizin Windows’ta oluşturduğu tek seferlik kod.', [
          TextField(key: const ValueKey('activation-username'), controller: user,
            autofillHints: const [AutofillHints.username], textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Kullanıcı adı', prefixIcon: Icon(Icons.person_outline))),
          gap,
          TextField(key: const ValueKey('activation-code'), controller: code,
            textCapitalization: TextCapitalization.characters, textInputAction: TextInputAction.next,
            inputFormatters: [ActivationCodeFormatter()],
            style: const TextStyle(letterSpacing: 3, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(labelText: 'Aktivasyon kodu', hintText: 'ABCD-EFGH',
              prefixIcon: Icon(Icons.key_outlined))),
        ]),
        const SizedBox(height: 8),
        _step(2, 'Şifreniz', 'En az 8 karakter. Yalnızca siz bileceksiniz.', [
          TextField(key: const ValueKey('activation-password'), controller: pass, obscureText: !showPass,
            autofillHints: const [AutofillHints.newPassword], textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: 'Yeni şifre', prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(tooltip: showPass ? 'Gizle' : 'Göster',
                onPressed: () => setState(() => showPass = !showPass),
                icon: Icon(showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined)))),
          gap,
          TextField(key: const ValueKey('activation-password2'), controller: pass2, obscureText: !showPass,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Yeni şifre (tekrar)', prefixIcon: Icon(Icons.lock_outline))),
        ]),
        const SizedBox(height: 8),
        _step(3, 'Bu telefonun PIN’i', '5 rakam. Uygulama kilitlenince şifre yerine bunu girersiniz.', [
          Row(children: [
            Expanded(child: TextField(key: const ValueKey('activation-pin'), controller: pin, obscureText: true,
              keyboardType: TextInputType.number, maxLength: 5,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'PIN', counterText: ''))),
            const SizedBox(width: 10),
            Expanded(child: TextField(key: const ValueKey('activation-pin2'), controller: pin2, obscureText: true,
              keyboardType: TextInputType.number, maxLength: 5,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'PIN (tekrar)', counterText: ''))),
          ]),
        ]),
        if (error != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!,
            key: const ValueKey('activation-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600))),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('activation-submit'),
          onPressed: busy ? null : _submit,
          icon: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check_circle_outline),
          label: const Text('Etkinleştir ve Giriş Yap')),
        const SizedBox(height: 10),
        Text('Kod tek kullanımlıktır ve 3 gün geçerlidir. Süresi dolarsa yöneticinizden yenisini isteyin.',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: context.nohut.muted)),
      ])),
    );
  }
}
