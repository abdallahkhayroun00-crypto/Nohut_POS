import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'pos_api.dart';
import 'style.dart';

class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.controller, required this.onPaired});
  final PersonelController controller;
  final VoidCallback onPaired;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final pin = TextEditingController();
  final address = TextEditingController();
  Uri? url;
  bool scanning = false;
  bool submitting = false;
  String? error;

  @override
  void dispose() {
    pin.dispose();
    address.dispose();
    super.dispose();
  }

  void _readQr(String raw) {
    final candidate = NohutApi.normalizeQr(raw);
    if (candidate == null) {
      setState(() => error = 'Geçersiz QR kodu. POS Personel QR kodunu okutun.');
      return;
    }
    setState(() {
      url = candidate;
      address.text = candidate.toString();
      scanning = false;
      error = null;
    });
  }

  Future<void> _pair() async {
    final next = url ?? NohutApi.normalizeQr(address.text);
    if (next == null || pin.text.trim().length != 6) {
      setState(() => error = 'Geçerli restoran QR kodu ve 6 haneli PIN gerekli.');
      return;
    }
    setState(() { submitting = true; error = null; });
    try {
      await widget.controller.api.pair(next, pin.text.trim());
      await widget.controller.refresh();
      if (!mounted) return;
      widget.onPaired();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Widget _step(BuildContext context, int n, String title, String hint, List<Widget> body, {bool done = false}) {
    final nc = context.nohut;
    final scheme = Theme.of(context).colorScheme;
    return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        CircleAvatar(radius: 13, backgroundColor: nc.heading,
          child: done ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
              : Text('$n', style: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.w800, fontSize: 13))),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
      ]),
      Padding(padding: const EdgeInsets.only(top: 4, bottom: 12, left: 36),
        child: Text(hint, style: TextStyle(color: nc.muted, fontSize: 13, height: 1.35))),
      ...body,
    ])));
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final nc = context.nohut;
    final found = url;
    return Scaffold(
      appBar: AppBar(title: const Text('Nohut Personel')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: width < 400 ? 16 : 24, vertical: 16),
            children: [
              const NohutBrandHeader(subtitle: 'Restoran bilgisayarına bir kez bağlanın'),
              const SizedBox(height: 18),
              _step(context, 1, 'QR kodunu okutun',
                'Windows POS’ta Ayarlar › Personel Bağlantısı’nı açın ve ekrandaki QR kodunu okutun.', [
                if (scanning)
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: SizedBox(height: 260, child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: MobileScanner(
                      onDetect: (capture) {
                        if (!scanning || capture.barcodes.isEmpty) return;
                        final raw = capture.barcodes.first.rawValue;
                        if (raw != null) _readQr(raw);
                      },
                    ),
                  ))),
                if (found != null && !scanning)
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [
                    Icon(Icons.check_circle, size: 18, color: nc.heading),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Bilgisayar bulundu · ${found.host}',
                      key: const ValueKey('pair-found'),
                      style: TextStyle(color: nc.heading, fontWeight: FontWeight.w700))),
                  ])),
                OutlinedButton.icon(
                  key: const ValueKey('pair-scan'),
                  icon: Icon(scanning ? Icons.close : Icons.qr_code_scanner),
                  onPressed: () => setState(() {
                    scanning = !scanning;
                    error = null;
                  }),
                  label: Text(scanning ? 'Kamerayı Kapat' : found == null ? 'QR Kodunu Tara' : 'Yeniden Tara'),
                ),
                const SizedBox(height: 4),
                Theme(data: Theme.of(context).copyWith(dividerColor: Colors.transparent), child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 4),
                  title: Text('Kamera yoksa adresi elle girin',
                    style: TextStyle(fontSize: 13.5, color: nc.muted, fontWeight: FontWeight.w600)),
                  children: [
                    TextField(
                      key: const ValueKey('pair-address'),
                      controller: address,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Bilgisayar adresi',
                        hintText: 'http://192.168.1.10:8787/personel',
                        prefixIcon: Icon(Icons.wifi),
                      ),
                      onChanged: (v) => setState(() => url = NohutApi.normalizeQr(v)),
                    ),
                  ],
                )),
              ], done: found != null),
              const SizedBox(height: 8),
              _step(context, 2, 'Tek seferlik PIN', 'QR kodunun altında yazan 6 haneli kod. 15 dakika geçerlidir.', [
                TextField(
                  key: const ValueKey('pair-pin'),
                  controller: pin,
                  obscureText: true,
                  maxLength: 6,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(letterSpacing: 6, fontWeight: FontWeight.w800, fontSize: 18),
                  onSubmitted: (_) => _pair(),
                  decoration: const InputDecoration(
                    labelText: 'PIN',
                    prefixIcon: Icon(Icons.lock_outline),
                    counterText: '',
                  ),
                ),
              ]),
              if (error != null)
                Padding(padding: const EdgeInsets.only(top: 10),
                  child: Text(error!, key: const ValueKey('pair-error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600))),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const ValueKey('pair-submit'),
                onPressed: submitting ? null : _pair,
                icon: submitting
                    ? const SizedBox(width: 17, height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: const Text('Bağlan'),
              ),
              const SizedBox(height: 12),
              Text('Telefon ve Windows POS aynı restoran Wi-Fi ağında olmalıdır; internet gerekmez. '
                'Bağlandıktan sonra kendi hesabınızla giriş yaparsınız. İlk kez giriyorsanız '
                'yöneticinizden aktivasyon kodu isteyin.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: nc.muted, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }
}
