/// Ayarlar → Yedekleme ve Geri Yükleme (spec V5.1 §6.3, §12.1, §20.2).
///
/// Owner-only actions (restore) need the Recovery Key plus a typed
/// confirmation; per-user permissions arrive with Phase 3 auth (§20.3).
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;

import 'backup_container.dart';
import 'integration_secrets.dart';
import 'backup_service.dart';
import 'operations_ui.dart';

String _mb(int bytes) => '${(bytes / 1000000).toStringAsFixed(2)} MB';

String _when(Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (d == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

class BackupPanel extends StatefulWidget {
  const BackupPanel({super.key, required this.service, required this.restore});
  final BackupService service;
  final RestoreManager restore;
  @override
  State<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends State<BackupPanel> {
  bool busy = false, hasKey = false;
  String message = '';

  BackupService get service => widget.service;

  @override
  void initState() {
    super.initState();
    _refreshKey();
  }

  Future<void> _refreshKey() async {
    final key = await service.keyStore.load();
    if (mounted) setState(() => hasKey = key != null);
  }

  void _say(String text) {
    if (!mounted) return;
    setState(() => message = text);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      _say('$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _createKey() async {
    final key = RecoveryKey.generate();
    final groups = key.split('-');
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, redraw) => AlertDialog(
          title: const Text('Kurtarma Anahtarı'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Bu anahtarı kâğıda yazın ve güvenli bir yerde saklayın. '
                  'Bilgisayar bozulursa yedekler yalnızca bu anahtarla '
                  'açılabilir. Kaybolursa yedekler açılamaz; Nohut da kurtaramaz.',
                ),
                const SizedBox(height: 14),
                SelectableText(
                  key,
                  key: const ValueKey('recovery-key-text'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 18,
                    fontWeight: FontWeight.w700, letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: key)),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Kopyala (sonra panoyu temizleyin)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: confirm,
                  decoration: InputDecoration(
                    labelText: 'Onay: son grubu yazın (${groups.length}. grup)',
                  ),
                  onChanged: (_) => redraw(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç'),
            ),
            FilledButton(
              onPressed: confirm.text.trim().toUpperCase() == groups.last
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('Yazdım · Kaydet'),
            ),
          ],
        ),
      ),
    );
    confirm.dispose();
    if (ok != true) return;
    await service.keyStore.save(key);
    await _refreshKey();
    _say('Kurtarma anahtarı bu bilgisayarda güvenli kasaya kaydedildi.');
  }

  Future<void> _enterKey() async {
    final v = await askFields(context, 'Var Olan Kurtarma Anahtarı', [
      ('Kurtarma anahtarı (13 grup × 4)', ''),
    ], validate: (v) {
      try {
        RecoveryKey.normalize(v[0]);
        return null;
      } on BackupException catch (e) {
        return e.message;
      }
    });
    if (v == null) return;
    await service.keyStore.save(v[0]);
    await _refreshKey();
    _say('Kurtarma anahtarı kaydedildi.');
  }

  Future<void> _pickFolder({required bool mirror}) async {
    final dir = await getDirectoryPath(
      confirmButtonText: 'Seç',
      initialDirectory: mirror ? service.mirrorFolder : service.folder,
    );
    if (dir == null) return;
    await _run(() async {
      await service.configure(
          folder: mirror ? null : dir, mirror: mirror ? dir : null);
      _say(mirror ? 'Ayna klasörü kaydedildi.' : 'Yedek klasörü kaydedildi.');
    });
  }

  Future<void> _verify(BackupFileInfo info) async {
    final key = await service.keyStore.load() ??
        (await askFields(context, 'Yedeği Doğrula', [
          ('Kurtarma anahtarı', ''),
        ]))?.first;
    if (key == null) return;
    await _run(() async {
      final m = await service.container.verify(info.file, recoveryKey: key);
      _say('Doğrulandı: ${_when(m.createdAt)} · ${m.orderCount} sipariş · '
          'revizyon ${m.revision}');
    });
  }

  Future<void> _restore(BackupFileInfo info) async {
    final m = info.manifest;
    if (m == null) return;
    final v = await askFields(context, 'Verileri Geri Yükle (yalnız sahip)', [
      ('Kurtarma anahtarı', ''),
      ('Onay için GERİ YÜKLE yazın', ''),
      ('Onaylayan kişi', ''),
    ], validate: (v) {
      if (v[1].trim().toUpperCase() != 'GERİ YÜKLE') {
        return 'Onay metni hatalı.';
      }
      if (v[2].trim().isEmpty) return 'Onaylayan kişi gerekli.';
      try {
        RecoveryKey.normalize(v[0]);
        return null;
      } on BackupException catch (e) {
        return e.message;
      }
    });
    if (v == null || !mounted) return;
    var withTrendyol = false;
    try {
      withTrendyol = BackupContainer.hasIntegrations(info.file);
    } catch (_) {}
    final sure = await confirmAction(
      context,
      'Geri yükleme planlansın mı?',
      'Yedek: ${_when(m.createdAt)} · revizyon ${m.revision} · '
          '${m.orderCount} sipariş.\n'
          'Program yeniden başlatıldığında mevcut veriler bir güvenlik '
          'kopyasına taşınır ve bu yedek yüklenir. Yedekten sonra girilen '
          'kayıtlar yüklenen veride olmaz (güvenlik kopyasında kalır). '
          'Eski fişler otomatik basılmaz.'
          '${withTrendyol ? '\nTrendyol bağlantı bilgileri de bu bilgisayarın güvenli kasasına aktarılır; '
              'burada çalışan farklı bilgiler varsa korunur.' : ''}',
      confirm: 'Planla',
    );
    if (!sure) return;
    await _run(() async {
      await widget.restore.stage(info.file,
          recoveryKey: v[0], confirmedBy: v[2].trim(),
          container: service.container);
      _say('Geri yükleme hazır. Programı kapatıp açınca uygulanacak.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final history = service.store.backupHistory(limit: 30);
    final backups = service.listBackups();
    final settings =
        service.store.read().data['settings'] as Map? ?? const {};
    final last = settings['backupLastSuccessAt'];
    final lastError = '${settings['backupLastError'] ?? ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (busy) const LinearProgressIndicator(),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _Tile('Son Yedekleme', _when(last),
              ok: last != null, icon: Icons.history),
          _Tile('Kurtarma Anahtarı', hasKey ? 'Bu bilgisayarda' : 'Yok',
              ok: hasKey, icon: Icons.key_outlined),
          if (service.lastTrendyolCapture != null)
            _Tile('Trendyol Bağlantısı',
                switch (service.lastTrendyolCapture!) {
                  IntegrationCapture.included => 'Yedekte (şifreli)',
                  IntegrationCapture.notConfigured => 'Kayıtlı değil',
                  IntegrationCapture.unreadable => 'Kasa okunamadı',
                },
                ok: service.lastTrendyolCapture != IntegrationCapture.unreadable,
                icon: Icons.delivery_dining_outlined),
          _Tile('Otomatik Yedekleme',
              settings['backupAuto'] == true ? 'Açık · günde 1' : 'Kapalı',
              ok: settings['backupAuto'] == true, icon: Icons.schedule),
          _Tile('Yedek sayısı', '${backups.length}',
              ok: backups.isNotEmpty, icon: Icons.inventory_2_outlined),
        ]),
        if (widget.restore.hasPending)
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Geri yükleme bekliyor'),
              subtitle: const Text(
                  'Program yeniden başlatıldığında uygulanacak.'),
              trailing: TextButton(
                onPressed: () => _run(() async {
                  await widget.restore.cancelPending();
                  _say('Bekleyen geri yükleme iptal edildi.');
                }),
                child: const Text('İptal Et'),
              ),
            ),
          ),
        if (lastError.isNotEmpty && lastError != 'null')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(lastError,
                style: TextStyle(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: busy || !hasKey
                ? null
                : () => _run(() async {
                    final r = await service.runNow();
                    _say(r.message);
                  }),
            icon: const Icon(Icons.backup_outlined),
            label: const Text('Şimdi Yedekle'),
          ),
          if (!hasKey) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : _createKey,
              icon: const Icon(Icons.key),
              label: const Text('Kurtarma Anahtarı Oluştur'),
            ),
            OutlinedButton(
              onPressed: busy ? null : _enterKey,
              child: const Text('Var Olan Anahtarı Gir'),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Otomatik Yedekleme'),
          subtitle: const Text(
              'Günde bir kez, program açıkken. Hiçbir yedek otomatik silinmez.'),
          value: settings['backupAuto'] == true,
          onChanged: !hasKey || busy
              ? null
              : (v) => _run(() async {
                  await service.configure(auto: v);
                  setState(() {});
                }),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Yedek klasörü'),
          subtitle: Text(service.folder),
          trailing: TextButton(
            onPressed: busy ? null : () => _pickFolder(mirror: false),
            child: const Text('Değiştir'),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.usb),
          title: const Text('Ayna klasörü (USB, NAS veya Drive/OneDrive klasörü)'),
          subtitle: Text(service.mirrorFolder ??
              'Seçilmedi · bilgisayar bozulursa yedek de kaybolabilir'),
          trailing: TextButton(
            onPressed: busy ? null : () => _pickFolder(mirror: true),
            child: const Text('Seç'),
          ),
        ),
        const Divider(),
        Text('Yedekler', style: theme.textTheme.titleMedium),
        if (backups.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Henüz yedek yok.'),
          ),
        for (final b in backups.take(20))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(b.manifest == null
                ? Icons.error_outline : Icons.lock_outline),
            title: Text(b.manifest == null
                ? paths.basename(b.file.path)
                : '${_when(b.manifest!.createdAt)} · '
                  '${b.manifest!.orderCount} sipariş'),
            subtitle: Text(b.error ??
                '${_mb(b.bytes)} · revizyon ${b.manifest!.revision} · '
                '${paths.basename(b.file.path)}'),
            trailing: b.manifest == null
                ? null
                : Wrap(spacing: 4, children: [
                    TextButton(
                      onPressed: busy ? null : () => _verify(b),
                      child: const Text('Doğrula'),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => _restore(b),
                      child: const Text('Geri Yükle'),
                    ),
                  ]),
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Yedekleme Geçmişi'),
          children: [
            for (final h in history)
              ListTile(
                dense: true,
                title: Text('${_when(h['created_at'])} · ${h['status']}'
                    ' · ${h['reason'] ?? ''}'),
                subtitle: Text('${h['error_message'] ?? h['destination']}'),
              ),
          ],
        ),
        if (message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(message, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {required this.ok, required this.icon});
  final String label, value;
  final bool ok;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 210,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(icon, color: ok ? scheme.primary : scheme.error),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  Text(value, style: const TextStyle(fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
