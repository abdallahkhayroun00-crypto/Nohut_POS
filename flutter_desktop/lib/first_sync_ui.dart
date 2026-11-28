/// Ayarlar › Bulut & Senkronizasyon › İlk Senkronizasyon (Windows only).
///
/// Four honest steps, each gated by the previous one:
/// 1. Bulut bağlantısı — a scoped Windows agent must be enrolled.
/// 2. Anlık görüntü — identities are prepared and the snapshot is built
///    with the live-sync serializers; counts and refused records are shown.
/// 3. Dondur — the owner freezes it (manifest fixed, outbox on).
/// 4. Yedek + Başlat — a fresh encrypted backup (written and verified) is
///    taken AFTER freezing, so it covers the snapshot; then the upload runs
///    and can be resumed or cancelled. Nothing is sent before step 4.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;
import 'package:sqlite3/sqlite3.dart' show Database;

import 'backup_service.dart';
import 'initial_sync.dart';
import 'initial_sync_snapshot.dart';
import 'initial_sync_transport.dart';
import 'supabase_agent_transport.dart';
import 'windows_vault.dart';
import 'pos_store.dart';
import 'sync_outbox.dart';

const firstSyncCategoryNames = <String, String>{
  'employees': 'Çalışanlar',
  'typed_catalog': 'Menü ve kategoriler',
  'shiftPlans': 'Vardiya planları',
  'shifts': 'Mesai kayıtları',
  'timesheetWeeks': 'Haftalık mesailer',
  'typed_order': 'Siparişler',
  'typed_platform': 'Online platform siparişleri',
  'typed_print': 'Fiş kayıtları',
  'typed_finance': 'Giderler ve finans',
  'typed_ledger': 'Kasa ve ödemeler',
  'workforceSummaries': 'Personel özetleri',
  'qrMenuState': 'QR menü durumu',
  'dailyReports': 'Gün sonu raporları',
  'notifications': 'Bildirimler',
};

const _sourceNames = <String, String>{
  'trendyolGoOrders': 'Trendyol Go siparişi',
  'orders': 'Sipariş',
  'deletedOrders': 'Silinmiş sipariş',
};

class FirstSyncController extends ChangeNotifier {
  FirstSyncController({
    required this.db,
    required this.store,
    required this.backup,
    required this.transport,
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()) {
    createInitialSyncTables(db);
    plan = currentInitialSyncPlan(db);
  }

  /// Production wiring: the store's own database connection (no second
  /// handle that would keep the file open) and the scoped agent credentials
  /// from this Windows user's DPAPI vault.
  factory FirstSyncController.forStore(PosStore store, BackupService backups) =>
      FirstSyncController(
        db: store.authDatabase,
        store: store,
        backup: () => backups.runNow(reason: 'first_sync'),
        transport: () async {
          if (!Platform.isWindows) return null;
          final credentials = await AgentCredentials.load(WindowsVault(agentVaultFile(store.filePath)));
          return credentials == null ? null
              : AgentInitialSyncTransport.over(SupabaseAgentTransport(credentials));
        },
      );

  static File agentVaultFile(String databasePath) => File(paths.join(
      Platform.environment['APPDATA'] ?? paths.dirname(databasePath),
      'NohutFalafel', 'cloud-agent.dpapi'));

  final Database db;
  final PosStore store;
  final Future<BackupRunResult> Function() backup;

  /// Null while no Windows agent is enrolled.
  final Future<InitialSyncTransport?> Function() transport;
  final DateTime Function() _clock;

  SnapshotBuild? build;
  int? builtRevision;
  InitialSyncPlan? plan;
  bool busy = false, connected = false;
  String message = '';
  int uploaded = 0, total = 0;

  bool get planOpen => plan != null && (plan!.status == 'planned' || plan!.status == 'uploading');
  bool get active => plan?.status == 'active';

  Future<T?> _guard<T>(Future<T> Function() action) async {
    if (busy) return null;
    busy = true;
    notifyListeners();
    try {
      return await action();
    } on InitialSyncException catch (e) {
      message = e.message;
    } on FormatException catch (e) {
      message = 'Hazırlık tamamlanamadı: ${e.message}';
    } finally {
      busy = false;
      plan = currentInitialSyncPlan(db);
      notifyListeners();
    }
    return null;
  }

  Future<void> checkConnection() => _guard(() async {
    connected = await transport() != null;
    message = connected ? '' : 'Bu bilgisayar henüz buluta kayıtlı değil.';
  });

  /// Step 2: identities, then a snapshot of the current revision.
  Future<void> prepare() => _guard(() async {
    store.prepareCloudOrderIdentities();
    final snap = store.read();
    build = buildSnapshotCategories(db, state: snap.data, revision: snap.revision,
        sourceUpdatedAt: snap.updatedAt,
        authorityEpoch: syncStateValue(db, 'authority_epoch') ?? 'unplanned',
        now: _clock());
    builtRevision = snap.revision;
    message = '';
  });

  /// Step 3: freeze. Refuses (stale) if the POS changed since [prepare].
  Future<void> freeze() => _guard(() async {
    final b = build, rev = builtRevision;
    if (b == null || rev == null) return;
    try {
      planInitialSync(db, snapshotRevision: rev, categories: b.categories, clock: _clock);
    } on InitialSyncException catch (e) {
      if (e.code == 'stale_snapshot') {
        build = null;
        builtRevision = null;
      }
      rethrow;
    }
    message = 'Anlık görüntü donduruldu. Şimdi yedek alıp başlatabilirsiniz.';
  });

  /// Step 4: backup (first time) and upload; also used to resume.
  Future<void> start() => _guard(() async {
    final t = await transport();
    if (t == null) {
      connected = false;
      message = 'Bu bilgisayar henüz buluta kayıtlı değil.';
      return;
    }
    connected = true;
    VerifiedBackup? proof;
    if (plan?.backupId == null) {
      final r = await backup();
      final m = r.manifest;
      if (!r.ok || m == null) {
        message = 'Yedek alınamadı, senkronizasyon başlamadı: ${r.message}';
        return;
      }
      proof = VerifiedBackup(backupId: m.backupId, revision: m.revision);
    }
    final p = await InitialSyncRunner(db, t, clock: _clock).run(backup: proof,
        onProgress: (u, n) {
      uploaded = u;
      total = n;
      notifyListeners();
    });
    uploaded = p.uploaded == 0 ? uploaded : p.uploaded;
    total = p.total == 0 ? total : p.total;
    message = switch (p.outcome) {
      InitialSyncOutcome.active => 'İlk senkronizasyon tamamlandı. Değişiklikler artık buluta gidiyor.',
      _ => p.message,
    };
  });

  Future<void> cancel() => _guard(() async {
    final t = await transport();
    if (t == null) {
      message = 'Bulut bağlantısı yok; iptal buluta iletilemedi.';
      return;
    }
    await InitialSyncRunner(db, t, clock: _clock).abort();
    build = null;
    builtRevision = null;
    message = active ? 'Senkronizasyon bulutta zaten tamamlanmıştı.' : 'İlk senkronizasyon iptal edildi.';
  });
}

class FirstSyncPanel extends StatefulWidget {
  const FirstSyncPanel({super.key, required this.controller});
  final FirstSyncController controller;
  @override
  State<FirstSyncPanel> createState() => _FirstSyncPanelState();
}

class _FirstSyncPanelState extends State<FirstSyncPanel> {
  FirstSyncController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    c.checkConnection();
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Widget _step(int n, String title, String hint, {required bool done, required bool current,
      List<Widget> children = const []}) {
    final scheme = Theme.of(context).colorScheme;
    final color = done ? scheme.primary : current ? scheme.secondary : scheme.outline;
    return Card(
      key: ValueKey('first-sync-step-$n'),
      child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 13, backgroundColor: color,
            child: done ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
                : Text('$n', style: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.w800, fontSize: 13))),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
        ]),
        Padding(padding: const EdgeInsets.only(left: 36, top: 4),
          child: Text(hint, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))),
        if (children.isNotEmpty)
          Padding(padding: const EdgeInsets.only(left: 36, top: 10), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children)),
      ])),
    );
  }

  Widget _summary(SnapshotBuild b) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final cat in b.categories)
          Chip(key: ValueKey('first-sync-cat-${cat.name}'), visualDensity: VisualDensity.compact,
            label: Text('${firstSyncCategoryNames[cat.name] ?? cat.name}: ${cat.events.length}')),
      ]),
      if (b.rejected.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          key: const ValueKey('first-sync-rejected'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Buluta gönderilemeyecek kayıtlar',
              style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onErrorContainer)),
            const SizedBox(height: 4),
            for (final e in b.rejected.entries)
              Text('${_sourceNames[e.key] ?? e.key}: ${e.value.length} kayıt '
                  '(örn. ${e.value.keys.first} — ${e.value.values.first})',
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 13)),
            const SizedBox(height: 4),
            Text('Bu kayıtlar bilgisayarda olduğu gibi kalır; yalnızca bulutta görünmez.',
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 12.5)),
          ]),
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final b = c.build;
    final frozen = c.planOpen || c.active;
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _step(1, 'Bulut bağlantısı',
        c.connected ? 'Bu bilgisayar buluta kayıtlı.' : 'Önce bu bilgisayarı sahibin hesabıyla buluta kaydedin.',
        done: c.connected, current: !c.connected),
      _step(2, 'Anlık görüntü',
        'Siparişler, menü, personel ve kasa kayıtları canlı senkronizasyonla aynı biçimde hazırlanır. Hiçbir şey gönderilmez.',
        done: b != null || frozen, current: c.connected && b == null && !frozen, children: [
          if (b != null && !frozen) _summary(b),
          if (!frozen)
            Padding(padding: const EdgeInsets.only(top: 8), child: OutlinedButton.icon(
              key: const ValueKey('first-sync-prepare'),
              onPressed: c.busy ? null : c.prepare,
              icon: const Icon(Icons.inventory_2_outlined),
              label: Text(b == null ? 'Hazırla' : 'Yeniden hazırla'))),
        ]),
      _step(3, 'Dondur',
        'Bu andaki veriler sabitlenir. Sonraki her değişiklik, tamamlandıktan sonra ayrıca gönderilir.',
        done: frozen, current: b != null && !frozen, children: [
          if (b != null && !frozen)
            FilledButton.icon(
              key: const ValueKey('first-sync-freeze'),
              onPressed: c.busy ? null : c.freeze,
              icon: const Icon(Icons.lock_clock_outlined),
              label: Text('${b.eventCount} kaydı dondur')),
        ]),
      _step(4, 'Yedek al ve gönder',
        'Önce şifreli yedek alınıp doğrulanır. Gönderim yarıda kalırsa kaldığı yerden devam eder.',
        done: c.active, current: c.planOpen, children: [
          if (c.planOpen || c.active) ...[
            if (c.total > 0)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(key: const ValueKey('first-sync-progress'),
                  value: c.total == 0 ? null : c.uploaded / c.total, minHeight: 6,
                  borderRadius: BorderRadius.circular(3)),
                const SizedBox(height: 4),
                Text('${c.uploaded} / ${c.total} parti', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
              ])),
            if (c.planOpen)
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  key: const ValueKey('first-sync-start'),
                  onPressed: c.busy || !c.connected ? null : c.start,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: Text(c.plan?.status == 'uploading' ? 'Devam et' : 'Yedek al ve başlat')),
                TextButton(
                  key: const ValueKey('first-sync-cancel'),
                  onPressed: c.busy ? null : c.cancel,
                  child: const Text('İptal et')),
              ]),
          ],
        ]),
      if (c.busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
      if (c.message.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(c.message,
          key: const ValueKey('first-sync-message'),
          style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface))),
      if (c.plan?.lastError != null && c.planOpen)
        Text('Son hata: ${c.plan!.lastError}', style: TextStyle(color: scheme.error, fontSize: 12.5)),
    ]);
  }
}
