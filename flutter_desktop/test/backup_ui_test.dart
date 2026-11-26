import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/backup_container.dart';
import 'package:nohut_falafel_desktop/backup_service.dart';
import 'package:nohut_falafel_desktop/backup_ui.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';

void main() {
  testWidgets('Yedekleme: no key → disabled; key → Şimdi Yedekle works',
      (t) async {
    final dir = Directory.systemTemp.createTempSync('nohut-bkui');
    final store = PosStore(databaseFile: '${dir.path}/nohut-pos.sqlite3');
    final keys = MemoryRecoveryKeyStore();
    final service = BackupService(store, keyStore: keys,
        container: BackupContainer(
            kdf: const BackupKdf(memoryKiB: 19456, iterations: 1),
            random: Random(1)));
    final restore = RestoreManager(store.filePath);
    Future<void> mount() => t.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(
            child: BackupPanel(
                key: UniqueKey(), service: service, restore: restore)))));
    try {
      await mount();
      await t.pumpAndSettle();
      expect(find.text('Kurtarma Anahtarı Oluştur'), findsOneWidget);
      final button = t.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Şimdi Yedekle'));
      expect(button.onPressed, isNull);

      await t.runAsync(() => keys.save(RecoveryKey.generate(Random(2))));
      await mount();
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();
      expect(find.text('Kurtarma Anahtarı Oluştur'), findsNothing);
      final result = await t.runAsync(() => service.runNow());
      expect(result!.ok, true, reason: result.message);
      await mount();
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();
      expect(find.text('Doğrula'), findsOneWidget);
      expect(find.text('Geri Yükle'), findsOneWidget);
      expect(t.takeException(), isNull);
    } finally {
      service.dispose();
      store.dispose();
      dir.deleteSync(recursive: true);
    }
  });
}
