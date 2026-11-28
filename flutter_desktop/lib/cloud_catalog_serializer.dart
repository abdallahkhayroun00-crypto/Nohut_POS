/// Read-only replication of the existing POS/QR catalog. This never publishes
/// a QR menu or changes its draft, repository, credentials or publishing flow.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;

import 'cloud_finance_serializer.dart';
import 'sync_outbox.dart';
import 'sync_worker.dart';

int exactKurus(Object? value) {
  if (value is! num || !value.isFinite || value<0) throw const FormatException('Invalid catalog price');
  final match=RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch('$value');
  if(match==null)throw const FormatException('Catalog price has fractional kuruş');
  final result=int.parse(match[1]!)*100+int.parse((match[2]??'').padRight(2,'0'));
  if(result>9007199254740991)throw const FormatException('Unsafe catalog price');
  return result;
}

Map<String,String?> _localized(Object? raw) {
  if(raw==null)return {'tr':null,'en':null,'ar':null};
  if(raw is String)return {'tr':raw,'en':null,'ar':null};
  if(raw is! Map || raw.keys.any((k)=>!{'tr','en','ar'}.contains(k)) || raw.values.any((v)=>v!=null&&v is! String)) {
    throw const FormatException('Unsupported catalog translation');
  }
  return {for(final lang in ['tr','en','ar'])lang:raw[lang] as String?};
}

Map<String,Object?> _labels(Object? names,Object? descriptions) {
  final name=_localized(names),description=_localized(descriptions);
  return {'label_tr':name['tr']??'','label_en':name['en'],'label_ar':name['ar'],
    'description_tr':description['tr'],'description_en':description['en'],'description_ar':description['ar']};
}

List<FinanceProjectionRow> serializeCatalog(String source,Object? raw,CloudIdentityMap ids) {
  if(!{'localMenu','internalMenu','qrCategories','qrCampaigns'}.contains(source) || raw is! List || raw.any((r)=>r is! Map)) {
    throw const FormatException('Unsupported catalog collection');
  }
  final result=<FinanceProjectionRow>[];
  final seen=<String>{};
  for(final original in raw) {
    final item=Map<String,dynamic>.from(original as Map);
    final key=item['qrStableId']??item['id'];
    if((key is! String&&key is! int)||!seen.add('$key'))throw const FormatException('Invalid catalog identity');
    final base=ids.id(source,key as Object);
    if(source=='localMenu'||source=='internalMenu') {
      if(item['id'] is! int || item['name'] is! String)throw const FormatException('Invalid product');
      final display=_localized(item['displayName']);
      final definition=<String,Object?>{
        ..._labels(item['names']??item['name'],item['description']),
        'label_tr':item['name'],'price_kurus':exactKurus(item['price']),
        'category_key':item['category'],'image_path':item['image'],
        'display_name_tr':display['tr'],'display_name_en':display['en'],'display_name_ar':display['ar'],
        'active':item['active']??true,'available':item['available']??true,'internal_only':source=='internalMenu',
      };
      final version=ids.id('product_version',[base,canonicalJson(definition)]);
      result.add(FinanceProjectionRow('products',{'product_id':base,'local_id':item['id'],'source_kind':source,'current_version_id':version}));
      result.add(FinanceProjectionRow('product_versions',{'product_id':base,'product_version_id':version,
        ...definition,'content_sha256':hash.sha256.convert(utf8.encode(canonicalJson(definition))).toString()}));
    } else if(source=='qrCategories') {
      final definition=<String,Object?>{..._labels(item['name'],item['description']),
        'active':item['active']??true,'sort_order':item['order']??0};
      final version=ids.id('category_version',[base,canonicalJson(definition)]);
      result.add(FinanceProjectionRow('categories',{'category_id':base,'local_key':'$key','current_version_id':version}));
      result.add(FinanceProjectionRow('category_versions',{'category_id':base,'category_version_id':version,
        ...definition,'content_sha256':hash.sha256.convert(utf8.encode(canonicalJson(definition))).toString()}));
    } else {
      if(item['items'] is! List)throw const FormatException('Invalid campaign components');
      final definition=<String,Object?>{..._labels(item['title'],item['description']),
        'price_kurus':exactKurus(item['price']),'active':item['active']??false,
        'starts_at':item['startsAt'],'ends_at':item['endsAt'],'poster_path':item['poster'],'thumbnail_path':item['thumbnail'],
        'items':[for(final component in item['items'] as List)_localized(component)],
      };
      final version=ids.id('campaign_version',[base,canonicalJson(definition)]);
      result.add(FinanceProjectionRow('campaigns',{'campaign_id':base,'local_key':'$key','current_version_id':version}));
      result.add(FinanceProjectionRow('campaign_versions',{'campaign_id':base,'campaign_version_id':version,
        ...definition,'content_sha256':hash.sha256.convert(utf8.encode(canonicalJson(definition))).toString()}));
    }
  }
  return result;
}

class TypedCatalogTransport implements SyncTransport {
  const TypedCatalogTransport(this.identities,this.delegate);
  final CloudIdentityMap identities;
  final SyncTransport delegate;
  SyncTransaction encode(SyncTransaction tx)=>SyncTransaction(authorityEpoch:tx.authorityEpoch,
    sourceRevision:tx.sourceRevision,events:[for(final event in tx.events)_event(tx,event)]);
  SyncEvent _event(SyncTransaction tx,SyncEvent event) {
    if(!{'localMenu','internalMenu','qrCategories','qrCampaigns'}.contains(event.entityType))return event;
    if(event.op!='upsert'||event.entityId!='core'||event.createdAt==null)throw const SyncRejectedException('unsupported_catalog_event');
    final raw=jsonDecode(event.payloadJson);
    final current=raw is Map?raw['current']:raw;
    final removed=raw is Map?raw['removed']:const [];
    if(removed is! List)throw const FormatException('Invalid removed catalog rows');
    final encoded=<Map<String,Object?>>[
      for(final row in serializeCatalog(event.entityType,current,identities))row.toJson(),
    ];
    for(final removal in removed){
      if(removal is! Map||removal['row'] is! Map||removal['removedAt'] is! String)throw const FormatException('Invalid catalog removal');
      for(final row in serializeCatalog(event.entityType,[removal['row']],identities)){
        encoded.add({...row.toJson(),if({'products','categories','campaigns'}.contains(row.table))...{
          'deleted':true,'removed_at':removal['removedAt'],
        }});
      }
    }
    final payload=canonicalJson({'source_updated_at':event.createdAt,'rows':encoded});
    return SyncEvent(seq:event.seq,eventId:'${tx.authorityEpoch}:${tx.sourceRevision}:typed_catalog:${event.entityType}',
      entityType:'typed_catalog',entityId:event.entityType,op:'upsert',payloadJson:payload,
      payloadSha256:hash.sha256.convert(utf8.encode(payload)).toString(),ordinal:event.ordinal,createdAt:event.createdAt);
  }
  @override
  Future<IngestResult> ingest(SyncTransaction tx) {
    try{return delegate.ingest(encode(tx));}
    on FormatException{throw const SyncRejectedException('invalid_catalog_projection');}
  }
}
