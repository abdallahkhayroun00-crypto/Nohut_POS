import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

const catalogSyncSources={'localMenu','internalMenu','qrCategories','qrCampaigns'};

/// Preserve explicit source removals separately from the live menu. No QR
/// publisher mutation is involved. Runs inside the POS/outbox transaction.
Map<String,Object?> captureCatalogRemovals(Database db,String source,Object? previous,Object? current,String at){
  db.execute('CREATE TABLE IF NOT EXISTS catalog_sync_removals('
    'source TEXT NOT NULL,source_key TEXT NOT NULL,row_json TEXT NOT NULL,removed_at TEXT NOT NULL,'
    'PRIMARY KEY(source,source_key))');
  List<Map> rows(Object? v){
    if(v==null)return [];
    if(v is! List||v.any((r)=>r is! Map))throw const FormatException('Invalid catalog history');
    return v.cast<Map>();
  }
  String key(Map row){
    final id=row['qrStableId']??row['id'];
    if(id is! String&&id is! int)throw const FormatException('Missing catalog identity');
    return jsonEncode(id);
  }
  final active=rows(current),old=rows(previous);
  final keys=active.map(key).toSet();
  if(keys.length!=active.length)throw const FormatException('Duplicate catalog identity');
  for(final row in old){
    if(!keys.contains(key(row)))db.execute('INSERT OR IGNORE INTO catalog_sync_removals(source,source_key,row_json,removed_at) VALUES(?,?,?,?)',
      [source,key(row),jsonEncode(row),at]);
  }
  for(final row in active){db.execute('DELETE FROM catalog_sync_removals WHERE source=? AND source_key=?',[source,key(row)]);}
  return {'current':active,'removed':[
    for(final row in db.select('SELECT row_json,removed_at FROM catalog_sync_removals WHERE source=? ORDER BY source_key',[source]))
      {'row':jsonDecode(row['row_json'] as String),'removedAt':row['removed_at']},
  ]};
}
