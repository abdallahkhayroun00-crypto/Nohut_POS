import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/product_customization.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'campaign_menu_test.dart' show fixture, draft;
import 'manager_audit_test.dart' as helpers;

void main() {
 testWidgets('desktop composer orders the first campaign category with its full recipe',(t) async {
  final s=fixture();s['settings']={'qrAutoSync':false,'autoPrint':false};
  s['qrCampaigns']=[(s['qrCampaigns'] as List).first];
  final file=await helpers.mountManager(t,s);
  await helpers.click(t,'Sipariş Al');
  expect(t.widget<ChoiceChip>(find.byType(ChoiceChip).first).label,isA<Text>().having((w)=>w.data,'label','Kampanyalar'));
  await helpers.click(t,'Kampanyalar');
  await helpers.click(t,'Not / Malzeme');expect(find.descendant(of:find.byType(AlertDialog).last,matching:find.byType(ListTile)),findsNWidgets(4));
  await helpers.click(t,'Kaydet');
  await t.tap(find.byType(DropdownButtonFormField<int>));await t.pumpAndSettle();
  await t.tap(find.textContaining('Masa 1').last);await t.pumpAndSettle();
  await helpers.click(t,'Siparişi Kaydet');
  final db=PosStore(databaseFile:file);
  final o=asMaps(db.read().data['orders']).single;
  final line=asMaps(asMaps(o['batches']).single['lines']).single;
  expect(orderTotalCents(o),30000);expect(asMaps(line['components']),hasLength(4));
  expect(line['campaignId'],'two');db.dispose();expect(t.takeException(),isNull);
 });
 testWidgets('desktop combo customizes one wrap without changing the other or disposing dialog controllers early',(t) async {
  t.view.physicalSize=const Size(1400,1200);t.view.devicePixelRatio=1;
  addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetDevicePixelRatio);
  Json? result;
  await t.pumpWidget(MaterialApp(home:Scaffold(body:Builder(builder:(ctx)=>TextButton(onPressed:() async {result=await customizeLineDialog(ctx,draft(fixture()));},child:const Text('Open'))))));
  await t.tap(find.text('Open'));await t.pumpAndSettle();
  expect(find.byType(ListTile),findsNWidgets(4));
  await t.tap(find.byType(ListTile).first);await t.pumpAndSettle();
  expect(t.widgetList<TextField>(find.byType(TextField)).where((f)=>f.enabled==false).length,1);
  await t.tap(find.widgetWithText(FilterChip,'Domates').last);
  await t.enterText(find.byKey(const ValueKey('customization-note')).last,'Ek falafel');
  final adjustment=find.byWidgetPredicate((w)=>w is TextField && w.decoration?.labelText?.startsWith('Her adet')==true).last;
  await t.enterText(adjustment,'10');await t.tap(find.text('Kaydet').last);await t.pumpAndSettle();
  await t.tap(find.text('Kaydet'));await t.pumpAndSettle();
  expect(result?['price'],310);expect(asMaps(result?['components']).first['removed'],contains('Domates'));
  expect(asMaps(result?['components'])[1]['removed'],isEmpty);expect(result?['qty'],1);expect(t.takeException(),isNull);
 });
}
