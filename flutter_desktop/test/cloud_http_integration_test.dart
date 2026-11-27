// Real Dart serializer -> HTTP RPC boundary -> PostgreSQL -> Windows command
// -> confirmed app status. The bridge is synthetic/local-only, never deployed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_finance_serializer.dart';
import 'package:nohut_falafel_desktop/cloud_catalog_serializer.dart';
import 'package:nohut_falafel_desktop/finance_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/remote_commands.dart';
import 'package:nohut_falafel_desktop/supabase_agent_transport.dart';
import 'package:nohut_falafel_desktop/sync_outbox.dart';
import 'package:nohut_falafel_desktop/sync_worker.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final base=Platform.environment['NOHUT_TEST_RPC_URL'];
  test('full synthetic HTTP/database sync and command recovery', () async {
    final url=Uri.parse(base!);
    expect(url.scheme,'http');
    expect(url.host,'127.0.0.1');
    final client=HttpClient();
    Future<Map<String,dynamic>> call(String path, [Map<String,Object?> args=const {},bool app=false]) async {
      final request=await client.postUrl(url.replace(path:path));
      request.headers.contentType=ContentType.json;
      if(app)request.headers.set('Authorization','Bearer synthetic-user-jwt');
      request.write(jsonEncode(args));
      final response=await request.close();
      final body=await utf8.decoder.bind(response).join();
      expect(response.statusCode,200,reason:body);
      return Map<String,dynamic>.from(jsonDecode(body) as Map);
    }
    final setup=await call('/test/setup');
    final folder=Directory.systemTemp.createTempSync('nohut-http-integration');
    final store=PosStore(databaseFile:'${folder.path}/pos.sqlite3');
    final db=sqlite3.open(store.filePath);
    final transport=SupabaseAgentTransport(AgentCredentials(url:url,
      publishableKey:'sb_publishable_synthetic_test_key',token:setup['token'] as String,
      restaurantId:setup['restaurantId'] as String,authorityEpoch:setup['authorityEpoch'] as String),
      allowLoopbackHttpForTests:true);
    var now=DateTime.now().toUtc();
    final identities=CloudIdentityMap(db);
    final sync=SyncWorker(db,TypedFinanceTransport(identities,TypedCatalogTransport(identities,transport)),clock:()=>now);
    try {
      final initial=emptyPosState()..['employees']=[{'id':1,'name':'Synthetic Initial','role':'Yönetici','active':true}];
      expect(store.replace(initial,store.read().revision).ok,true);
      setSyncState(db,'authority_epoch',(setup['authorityEpoch'] as String).replaceAll('-',''));
      enableOutbox(db);
      store.command('synthetic_finance_delta',{},(s){
        (s['employees'] as List).first['name']='Synthetic Employee';
        saveOtherExpense(s,day:'2026-10-01',category:'Diğer',name:'Synthetic expense',amountCents:12345,paymentMethod:'Nakit');
        s['localMenu']=[{'id':1,'name':'Synthetic falafel','price':12.34,'category':'wrap','active':true,'available':true}];
        s['qrCategories']=[{'id':'wrap','name':{'tr':'Dürümler','ar':'لفائف'},'active':true,'order':1}];
        s['qrCampaigns']=[{'id':'synthetic-offer','title':{'tr':'Örnek Menü'},'price':25,'active':true,'items':[{'tr':'1 Synthetic falafel'}]}];
        return {'ok':true};
      });
      expect(groupPending(db).single.events,hasLength(5));
      await call('/test/lose-next-ingest-ack');
      expect(await sync.flush(),0);
      expect(pendingOutbox(db),hasLength(5));
      final committed=await call('/test/inspect');
      expect(committed['expenses'],1);
      expect(committed['expense_kurus'],'12345');
      expect(committed['transactions'],1);
      now=now.add(const Duration(minutes:1));
      expect(await sync.flush(),5);
      expect(pendingOutbox(db),isEmpty);
      expect((await call('/test/inspect'))['transactions'],1,reason:'lost ACK must not duplicate finance');
      store.command('synthetic_catalog_reprice',{},(s){
        (s['localMenu'] as List).first['price']=23.45;
        (s['localMenu'] as List).first['name']='Synthetic renamed falafel';
        return {'ok':true};
      });
      expect(await sync.flush(),1);
      final catalog=await call('/test/inspect');
      expect(catalog['product_versions'],2);
      expect(catalog['product_prices'],[1234,2345],reason:'catalog edits must retain old prices');
      store.command('synthetic_catalog_remove',{},(s){s['localMenu']=<dynamic>[];return {'ok':true};});
      expect(await sync.flush(),1);
      final removed=await call('/test/inspect');
      expect(removed['active_products'],0);
      expect(removed['product_versions'],2);
      store.command('synthetic_catalog_return',{},(s){
        s['localMenu']=[{'id':1,'name':'Synthetic renamed falafel','price':23.45,'category':'wrap','active':true,'available':true}];
        return {'ok':true};
      });
      expect(await sync.flush(),1);
      expect((await call('/test/inspect'))['active_products'],1);

      const requestId='90000000-0000-4000-8000-000000000001';
      final context=<String,Object?>{'p_device_id':setup['deviceId'],'p_client':'yonetici','p_permission_version':1,'p_request_id':requestId};
      expect((await call('/rest/v1/rpc/nohut_enqueue_command',{
        ...context,'p_action':'clock_in_out','p_payload':{'action':'clockIn'},
      },true))['status'],'accepted');
      expect((await call('/rest/v1/rpc/nohut_command_status',context,true))['state'],'pending');
      final worker=RemoteCommandWorker(store,transport);
      expect(await worker.runOnce(),1,reason:'${worker.lastError}');
      expect((store.read().data['shifts'] as List),hasLength(1));
      expect((await call('/rest/v1/rpc/nohut_command_status',context,true))['state'],'confirmed');
      expect(await worker.runOnce(),0);
      expect((store.read().data['shifts'] as List),hasLength(1));
      expect(await sync.flush(),greaterThan(0));
      expect(pendingOutbox(db),isEmpty);
    } finally {
      sync.dispose();transport.close();db.close();store.dispose();
      client.close(force:true);folder.deleteSync(recursive:true);
    }
  },skip:base==null,timeout:const Timeout(Duration(minutes:2)));
}
