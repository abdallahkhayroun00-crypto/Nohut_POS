import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/sales_reports.dart';

void main() {
  test('report presets use Istanbul business days', () {
    // 22:30 UTC on 30 Nov is already 1 Dec in Istanbul.
    final now = DateTime.utc(2026, 11, 30, 22, 30);
    expect(reportPreset('Bugün', now), (from: '2026-12-01', to: '2026-12-01'));
    expect(reportPreset('Dün', now), (from: '2026-11-30', to: '2026-11-30'));
    expect(reportPreset('Son 7 Gün', now), (from: '2026-11-25', to: '2026-12-01'));
    expect(reportPreset('Son 30 Gün', now), (from: '2026-11-02', to: '2026-12-01'));
    expect(reportPreset('Bu Ay', now), (from: '2026-12-01', to: '2026-12-01'));
    expect(reportPreset('Tüm Tarihler', now), (from: '', to: ''));
  });

  test('CSV files are suggested outside the program folder', () {
    final folder = reportExportFolder();
    expect(Directory(folder).existsSync(), isTrue);
    expect(folder, isNot(Directory.current.path));
  });
}
