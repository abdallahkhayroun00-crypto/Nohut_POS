import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_catalog_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/sync_field_registry.dart';
import 'package:sqlite3/sqlite3.dart';

void main(){
  late Directory folder;
  late Database db;
  late CloudIdentityMap ids;
  setUp((){folder=Directory.systemTemp.createTempSync('nohut-catalog');db=sqlite3.open('${folder.path}/ids');ids=CloudIdentityMap(db);});
  tearDown((){db.close();folder.deleteSync(recursive:true);});
  Map<String,dynamic> product()=>{'id':1,'qrStableId':1,'name':'Synthetic falafel','price':12.34,'category':'wrap',
    'active':true,'available':true,'names':{'tr':'Synthetic falafel','en':'Synthetic falafel'},'description':{'tr':'Synthetic açıklama'}};
  test('price conversion is exact and rejects fractional kuruş',(){
    expect(exactKurus(12.34),1234);
    expect(exactKurus(0),0);
    expect(()=>exactKurus(12.345),throwsFormatException);
    expect(()=>exactKurus(double.nan),throwsFormatException);
  });
  test('repricing and renaming preserve product identity and immutable versions',(){
    final source=product();
    final first=serializeCatalog('localMenu',[source],ids);
    final id=first.first.data['product_id'];
    final version=first.last.data['product_version_id'];
    source['price']=23.45;source['name']='Synthetic renamed';
    final changed=serializeCatalog('localMenu',[source],ids);
    expect(changed.first.data['product_id'],id);
    expect(changed.last.data['product_version_id'],isNot(version));
    expect(first.last.data['price_kurus'],1234);
    expect(serializeCatalog('localMenu',[source],ids).last.data,changed.last.data);
    expect(serializeCatalog('internalMenu',[source],ids).first.data['product_id'],isNot(id));
  });
  test('categories and campaigns keep multilingual definitions and component text',(){
    final categories=serializeCatalog('qrCategories',[{'id':'wrap','name':{'tr':'Dürümler','ar':'لفائف'},'active':true,'order':1}],ids);
    expect(categories.last.data['label_ar'],'لفائف');
    final campaigns=serializeCatalog('qrCampaigns',[{'id':'synthetic-offer','title':{'tr':'Örnek Menü'},'price':25,
      'active':true,'items':[{'tr':'1 Synthetic falafel','en':'1 Synthetic falafel'}]}],ids);
    expect(campaigns.last.data['price_kurus'],2500);
    expect(campaigns.last.data['items'],isA<List>());
  });
  test('only eligible catalog facts cross the projection boundary',(){
    final source=product();
    final projected=projectForCloud({'internalMenu':[source], 'qrPublisherDraft':{'secret':'local-only'},'settings':{'secret':'local-only'}});
    expect(projected['internalMenu'],hasLength(1));
    expect(projected, isNot(contains('qrPublisherDraft')));
    expect(projected,isNot(contains('settings')));
    expect(unregisteredFieldPaths({'internalMenu':[source]}),isEmpty);
  });
}
