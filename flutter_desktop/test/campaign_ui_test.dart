import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/product_customization.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'campaign_menu_test.dart' show fixture, draft;

void main() {
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
