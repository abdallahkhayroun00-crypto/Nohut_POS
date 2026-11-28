import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

void createFinanceSyncHistory(Database db) => db.execute('''
  CREATE TABLE IF NOT EXISTS finance_sync_reversals(
    template_id INTEGER NOT NULL,month TEXT NOT NULL,body TEXT NOT NULL,
    PRIMARY KEY(template_id,month)
  )
''');

/// The existing UI permits undoing a fixed-expense payment. Capture that
/// explicit transition in the SAME local transaction as the outbox, keeping
/// the original paid amount/time rather than treating absence as deletion.
Map<String,dynamic> captureFinanceReversals(Database db, Object? previous,
    Map<String,dynamic> financeAfter, String at) {
  createFinanceSyncHistory(db);
  final before = previous is Map && previous['fixedPayments'] is List
      ? previous['fixedPayments'] as List : const [];
  final after = financeAfter['fixedPayments'] is List ? financeAfter['fixedPayments'] as List : const [];
  String key(Map p) => jsonEncode([p['templateId'],p['month']]);
  final active = {for (final p in after.whereType<Map>()) key(p)};
  for (final p in before.whereType<Map>()) {
    if (!active.contains(key(p))) {
      db.execute('INSERT OR REPLACE INTO finance_sync_reversals(template_id,month,body) VALUES(?,?,?)',
        [p['templateId'],p['month'],jsonEncode({for (final k in ['templateId','month','amountCents','paidAt']) k:p[k], 'reversedAt':at})]);
    }
  }
  for (final p in after.whereType<Map>()) {
    db.execute('DELETE FROM finance_sync_reversals WHERE template_id=? AND month=?',[p['templateId'],p['month']]);
  }
  return {...financeAfter,'_fixedPaymentReversals':[
    for (final r in db.select('SELECT body FROM finance_sync_reversals ORDER BY template_id,month'))
      jsonDecode(r['body'] as String),
  ]};
}
