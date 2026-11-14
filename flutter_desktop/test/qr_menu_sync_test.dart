import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/qr_menu_reader.dart';
import 'package:nohut_falafel_desktop/qr_menu_sync.dart';

import 'qr_catalog_fixtures.dart';

void main(){
  test('upgrades the original 51 products without changing IDs or old sales',
      ()async{
    final local=QrCatalogFixture.localState();
    final oldOrders=jsonEncode(local['orders']);
    final remote=await QrCatalogFixture.snapshot(falafelPrice:150);
    final result=reconcilePublishedMenu(local,remote);

    expect(result.changed,isTrue);
    expect(result.added,2);
    expect(result.repriced,1);
    expect(result.unlisted,0);
    final products=(local['localMenu'] as List).cast<Map>();
    expect(products,hasLength(53));
    expect(products.map((p)=>p['id']).toSet(),hasLength(53));
    expect(products.singleWhere((p)=>p['id']==0)['name'],'Falafel Dürüm');
    expect(products.singleWhere((p)=>p['id']==0)['price'],150.0);
    expect(products.singleWhere((p)=>p['id']==51)['name'],'Vegan Dürüm');
    expect(products.singleWhere((p)=>p['id']==52)['name'],'Layali Lübnan');
    expect(products.singleWhere((p)=>p['id']==0)['description']['tr'],
      'Türkçe ürün açıklaması');
    expect(products.singleWhere((p)=>p['id']==0)['image'],
      'assets/wrap-cutouts/wraps-transparent.webp');
    expect(jsonEncode(local['orders']),oldOrders);
    expect((local['qrCategories'] as List),hasLength(9));
    expect((local['qrCampaigns'] as List),hasLength(1));
  });

  test('same remote catalog is idempotent and never writes extra changes',
      ()async{
    final local=QrCatalogFixture.localState();
    final remote=await QrCatalogFixture.snapshot();
    final initial=reconcilePublishedMenu(local,remote);
    final before=jsonEncode(local);
    final second=reconcilePublishedMenu(local,remote);
    expect(initial.changed,isTrue);
    expect(second.changed,isFalse);
    expect(second.added,0);
    expect(second.repriced,0);
    expect(jsonEncode(local),before);
  });

  test('a metadata-only translation edit is treated as a change',()async{
    final local=QrCatalogFixture.localState();
    final remote=await QrCatalogFixture.snapshot();
    reconcilePublishedMenu(local,remote);
    final newProducts=[
      for(final p in remote.products)
        if(p.id==0)
          PublishedProductPrice(
            id:p.id,category:p.category,name:p.name,priceTl:p.priceTl,
            names:p.names,displayNames:{...p.displayNames,'ar':'فلافل جديدة'},
            descriptions:p.descriptions,image:p.image,
          )
        else p,
    ];
    final changed=PublishedQrMenu(
      products:newProducts,categories:remote.categories,
      campaigns:remote.campaigns,retrievedAtUtc:remote.retrievedAtUtc,
    );
    final res=reconcilePublishedMenu(local,changed);
    expect(res.changed,isTrue);
    expect(res.repriced,0);
    expect((local['localMenu'] as List).first['displayName']['ar'],'فلافل جديدة');
  });

  test('renaming a previously-synced product preserves its stable ID',()async{
    final local=QrCatalogFixture.localState();
    final remote=await QrCatalogFixture.snapshot();
    reconcilePublishedMenu(local,remote);
    final historical=jsonEncode(local['orders']);
    final renamed=PublishedQrMenu(
      products:[
        for(final p in remote.products)
          if(p.id==0)
            PublishedProductPrice(
              id:p.id,category:p.category,name:'Falafel Yeni Dürüm',
              priceTl:p.priceTl,names:{...p.names,'tr':'Falafel Yeni Dürüm'},
              displayNames:p.displayNames,descriptions:p.descriptions,image:p.image,
            )
          else p
      ],
      categories:remote.categories,campaigns:remote.campaigns,
      retrievedAtUtc:remote.retrievedAtUtc,
    );
    expect(reconcilePublishedMenu(local,renamed).changed,isTrue);
    final item=(local['localMenu'] as List).cast<Map>()
      .singleWhere((p)=>p['id']==0);
    expect(item['name'],'Falafel Yeni Dürüm');
    expect(jsonEncode(local['orders']),historical);
  });

  test('rejects ID category collisions before changing any records',()async{
    final local=QrCatalogFixture.localState();
    final remote=await QrCatalogFixture.snapshot();
    final before=jsonEncode(local);
    final bad=PublishedQrMenu(
      products:[
        for(final p in remote.products)
          if(p.id==0)
            PublishedProductPrice(
              id:p.id,category:'drink',name:p.name,priceTl:p.priceTl,
              names:p.names,displayNames:p.displayNames,
              descriptions:p.descriptions,image:p.image,
            )
          else p,
      ],
      categories:remote.categories,campaigns:remote.campaigns,
      retrievedAtUtc:remote.retrievedAtUtc,
    );
    expect(()=>reconcilePublishedMenu(local,bad),throwsFormatException);
    expect(jsonEncode(local),before);
  });

  test('rejects a catalog product ID colliding with a custom local item',
      ()async{
    final local=QrCatalogFixture.localState();
    (local['localMenu'] as List).add(
      {'id':51,'name':'Custom Item','category':'meze','price':180});
    final before=jsonEncode(local);
    final remote=await QrCatalogFixture.snapshot();
    expect(()=>reconcilePublishedMenu(local,remote),throwsFormatException);
    expect(jsonEncode(local),before);
  });

  test('rejects suspiciously short catalog before mutating local prices',
      ()async{
    final local=QrCatalogFixture.localState(),before=jsonEncode(local);
    final full=await QrCatalogFixture.snapshot();
    final bad=PublishedQrMenu(
      products:full.products.take(1).toList(),categories:full.categories,
      campaigns:full.campaigns,retrievedAtUtc:full.retrievedAtUtc,
    );
    expect(()=>reconcilePublishedMenu(local,bad),throwsFormatException);
    expect(jsonEncode(local),before);
  });

  test('SQLite sync persists metadata once and leaves sales unchanged',
      ()async{
    final dir=Directory.systemTemp.createTempSync('qr-stable-sync-');
    final store=PosStore(databaseFile:dir.path+'/nohut.sqlite3');
    addTearDown((){
      store.dispose();
      dir.deleteSync(recursive:true);
    });
    expect(store.replace(QrCatalogFixture.localState(),0).ok,isTrue);
    final oldOrders=jsonEncode(store.read().data['orders']);
    final sync=QrMenuAutoSync(store,reader:QrCatalogFixture.reader());
    addTearDown(sync.dispose);
    final rev=store.read().revision;
    await sync.syncNow();
    expect(sync.lastError,isNull);
    expect(store.read().revision,rev+1);
    expect((store.read().data['localMenu'] as List),hasLength(53));
    expect(jsonEncode(store.read().data['orders']),oldOrders);
    await sync.syncNow();
    expect(store.read().revision,rev+1);
  });

  test('disabled switch prevents network access or SQLite changes',
      ()async{
    final dir=Directory.systemTemp.createTempSync('qr-stable-disabled-');
    final store=PosStore(databaseFile:dir.path+'/nohut.sqlite3');
    addTearDown((){
      store.dispose();
      dir.deleteSync(recursive:true);
    });
    expect(store.replace(QrCatalogFixture.localState(enabled:false),0).ok,isTrue);
    final before=store.read();
    final sync=QrMenuAutoSync(store,reader:QrCatalogFixture.reader(offline:true));
    addTearDown(sync.dispose);
    await sync.syncNow();
    expect(store.read().revision,before.revision);
    expect(sync.lastError,isNull);
    expect(sync.lastCheckedAtUtc,isNull);
  });

  test('offline failure reports error and keeps last local catalog',
      ()async{
    final dir=Directory.systemTemp.createTempSync('qr-stable-offline-');
    final store=PosStore(databaseFile:dir.path+'/nohut.sqlite3');
    addTearDown((){
      store.dispose();
      dir.deleteSync(recursive:true);
    });
    expect(store.replace(QrCatalogFixture.localState(),0).ok,isTrue);
    final before=store.read();
    final sync=QrMenuAutoSync(store,reader:QrCatalogFixture.reader(offline:true));
    addTearDown(sync.dispose);
    await sync.syncNow();
    expect(sync.lastError,isNotNull);
    expect(store.read().revision,before.revision);
    expect(jsonEncode(store.read().data),jsonEncode(before.data));
  });
}
