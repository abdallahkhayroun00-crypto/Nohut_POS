import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;

import 'brand.dart';
import 'windows_vault.dart';
import 'trendyol_go_ui.dart' show openExternalPage;

/// Stores future restaurant-partner credentials encrypted under Windows DPAPI.
/// This is configuration only: a saved key is NOT a connected/approved API.
class PartnerCredentialsCard extends StatefulWidget {
  const PartnerCredentialsCard({
    super.key,
    required this.partner,
    required this.databasePath,
    required this.portalUrl,
    this.documentationUrl,
  });

  final String partner, databasePath, portalUrl;
  final String? documentationUrl;

  @override
  State<PartnerCredentialsCard> createState() =>
      _PartnerCredentialsCardState();
}

class _PartnerCredentialsCardState extends State<PartnerCredentialsCard> {
  late final WindowsVault vault = WindowsVault(
    File(paths.join(
      Platform.environment['APPDATA'] ?? paths.dirname(widget.databasePath),
      'NohutFalafel',
      widget.partner == 'Yemeksepeti'
          ? 'yemeksepeti-credentials.dpapi'
          : 'migros-yemek-credentials.dpapi',
    )),
  );
  bool busy = true;
  bool saved = false;
  String restaurantId = '';
  String chainId = '';
  String message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final details = await vault.load();
      if (!mounted) return;
      setState(() {
        saved = details != null && details['apiKey'] != null;
        restaurantId = '${details?['restaurantId'] ?? ''}';
        chainId = '${details?['chainId'] ?? ''}';
        message = '';
        busy = false;
      });
    } catch (_) {
      if (mounted) setState(() {
        busy = false;
        message = 'Windows güvenli kasası okunamadı.';
      });
    }
  }

  Future<void> _configure() async {
    if (busy) return;
    final keyOnly = widget.partner == 'Migros Yemek';
    final id = TextEditingController(text: restaurantId);
    final chain = TextEditingController(text: chainId);
    final key = TextEditingController();
    final secret = TextEditingController();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${widget.partner} · API Hazırlığı'),
        content: SizedBox(
          width: 435,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Bu adım erişim bilgilerini Windows üzerinde '
                  'güvenli saklar. Canlı sipariş entegrasyonunu başlatmaz.',
                  style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                TextField(
                  controller: id,
                  decoration: const InputDecoration(
                    labelText: 'Restoran ID / Şube kimliği',
                    prefixIcon: Icon(Icons.storefront_outlined),
                    border: OutlineInputBorder()),
                ),
                if (keyOnly) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: chain,
                    decoration: const InputDecoration(
                      labelText: 'Zincir ID (varsa)',
                      prefixIcon: Icon(Icons.hub_outlined),
                      border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 7),
                  const Text('Migros paneli → Restoran Bilgileri → '
                    'POS Entegrasyonları. Şubeyi ve yetkiyi doğrulayın.',
                    style: TextStyle(fontSize: 11,
                      color: NohutBrand.muted)),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: key,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'API Key / Client ID',
                    prefixIcon: Icon(Icons.vpn_key_outlined),
                    border: OutlineInputBorder()),
                ),
                if (!keyOnly) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: secret,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'API Secret / Client Secret'),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx,
                [id.text.trim(), key.text.trim(), secret.text.trim(),
                 chain.text.trim()]),
            child: const Text('Güvenli Kaydet'),
          ),
        ],
      ),
    );
    id.dispose(); chain.dispose(); key.dispose(); secret.dispose();
    if (result == null || !mounted) return;
    if (result[0].isEmpty) {
      setState(() => message = 'Restoran / şube kimliği gerekli.');
      return;
    }
    setState(() => busy = true);
    try {
      final previous = await vault.load() ?? <String, dynamic>{};
      final nextKey = result[1].isNotEmpty ? result[1] : '${previous['apiKey'] ?? ''}';
      final nextSecret = result[2].isNotEmpty
          ? result[2] : '${previous['apiSecret'] ?? ''}';
      if (nextKey.isEmpty || (!keyOnly && nextSecret.isEmpty)) {
        throw FormatException(
          keyOnly ? 'Migros restoran API Key gerekli.' : 'API Key ve Secret gerekli.',
        );
      }
      await vault.save({
        'restaurantId': result[0],
        'chainId': result[3],
        'apiKey': nextKey,
        'apiSecret': nextSecret,
      });
      if (mounted) setState(() {
        saved = true;
        restaurantId = result[0];
        chainId = result[3];
        message = 'DPAPI ile kaydedildi. Migros API bağlantısı '
            'henüz doğrulanmadı.';
      });
    } on FormatException catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted) setState(() =>
          message = 'API bilgileri güvenli şekilde kaydedilemedi.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove() async {
    if (busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${widget.partner} bağlantı bilgilerini sil?'),
        content: const Text('Kaydedilen API anahtarları bu bilgisayardan silinir.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sil')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await vault.clear();
      if (mounted) setState(() {
        saved = false;
        restaurantId = '';
        chainId = '';
        message = 'Kaydedilen bilgiler silindi.';
      });
    } catch (_) {
      if (mounted) setState(() => message = 'Silme başarısız.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xffFFF3DF),
                child: Icon(
                  saved ? Icons.lock_outline : Icons.link_off_outlined,
                  color: NohutBrand.gold,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.partner,
                        style: const TextStyle(fontWeight: FontWeight.w800,
                            color: NohutBrand.green, fontSize: 17)),
                    Text(
                      saved
                          ? 'Bilgiler şifreli kaydedildi · Canlı API bağlantısı yok'
                          : 'Bağlı değil · POS API yetkisi ve dokümanı gerekli',
                      style: const TextStyle(color: NohutBrand.muted,
                          fontSize: 12),
                    ),
                    if (restaurantId.isNotEmpty)
                      Text('Restoran: $restaurantId' +
                        (chainId.isEmpty ? '' : ' · Zincir: $chainId'),
                          style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              if (busy)
                const Icon(Icons.hourglass_empty_outlined,
                    color: NohutBrand.muted, size: 20),
            ],
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(message, style: const TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _configure,
                icon: const Icon(Icons.key_outlined, size: 16),
                label: Text(saved ? 'Bilgileri Düzenle' : 'API Bilgilerini Kaydet'),
              ),
              OutlinedButton.icon(
                onPressed: () => openExternalPage(context, widget.portalUrl),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Partner Paneli'),
              ),
              if (widget.documentationUrl != null)
                TextButton.icon(
                  onPressed: () => openExternalPage(
                      context, widget.documentationUrl!),
                  icon: const Icon(Icons.menu_book_outlined, size: 16),
                  label: const Text('API Dokümanı'),
                ),
              if (saved)
                TextButton(
                  onPressed: busy ? null : _remove,
                  child: const Text('Anahtarları Sil'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
