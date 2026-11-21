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

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(title: const Text('Nohut Personel · Android')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: EdgeInsets.symmetric(
              horizontal: width < 400 ? 18 : 28, vertical: 22),
            children: [
              const NohutBrandHeader(subtitle: 'Güvenli, tek seferlik eşleştirme'),
              const SizedBox(height: 24),
              Card(child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.phonelink_lock, size: 46, color: NohutStyle.green),
                    const SizedBox(height: 12),
                    const Text('Restoran bilgisayarına bağlan',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontFamily: 'Bree', fontSize: 25)),
                    const SizedBox(height: 10),
                    const Text(
                      '1. Bilgisayarda Ayarlar → Personel Bağlantısı açın.\n'
                      '2. QR kodunu okutun.\n'
                      '3. Altındaki 6 haneli PIN kodunu girin.\n'
                      'Bundan sonra uygulama bağlantıyı hatırlar.',
                      style: TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 16),
                    if (scanning)
                      SizedBox(height: 260, child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: MobileScanner(
                          onDetect: (capture) {
                            if (!scanning || capture.barcodes.isEmpty) return;
                            final raw = capture.barcodes.first.rawValue;
                            if (raw != null) _readQr(raw);
                          },
                        ),
                      )),
                    OutlinedButton.icon(
                      icon: Icon(scanning ? Icons.close : Icons.qr_code_scanner),
                      onPressed: () => setState(() {
                        scanning = !scanning;
                        error = null;
                      }),
                      label: Text(scanning ? 'Kamerayı Kapat' : 'QR Kodunu Tara'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: address,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Bilgisayar adresi',
                        hintText: 'http://192.168.1.10:8787/personel',
                        prefixIcon: Icon(Icons.wifi),
                      ),
                      onChanged: (v) => url = NohutApi.normalizeQr(v),
                    ),
                    const SizedBox(height: 13),
                    TextField(
                      controller: pin,
                      obscureText: true,
                      maxLength: 6,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Tek seferlik PIN',
                        prefixIcon: Icon(Icons.lock_outline),
                        counterText: '',
                      ),
                    ),
                    if (error != null)
                      Padding(padding: const EdgeInsets.only(bottom: 9),
                        child: Text(error!,
                          style: const TextStyle(color: Colors.red))),
                    FilledButton.icon(
                      onPressed: submitting ? null : _pair,
                      icon: submitting
                          ? const SizedBox(width: 17, height: 17,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.link),
                      label: const Text('Bir Kez Eşleştir'),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 13),
              const Text('Telefon ve Windows POS aynı restoran Wi-Fi ağında '
                'olmalıdır. İnternet gerekmez. iPhone personel sayfası '
                'ayrı şekilde Safari üzerinden çalışmaya devam eder.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: NohutStyle.muted)),
            ],
          ),
        ),
      ),
    );
  }
}
