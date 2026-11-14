import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/qr_menu_reader.dart';

import 'qr_catalog_fixtures.dart';

void main() {
  test('reads stable-ID catalog, live prices and offers from three HTTPS files',
      () async {
    final requests=<Uri>[];
    final data=await QrCatalogFixture.reader(
      requests:requests,
      pricesOverride:QrCatalogFixture.priceJson(falafelPrice:150),
    ).readPublishedMenu();

    expect(requests.map((x)=>x.path),[
      '/qr-menu/cms/catalog-v1.json',
      '/qr-menu/cms/menu-prices.json',
      '/qr-menu/cms/campaigns.json',
    ]);
    expect(requests.every((x)=>x.scheme=='https'),isTrue);
    expect(data.products,hasLength(53));
    expect(data.categories,hasLength(9));
    expect(data.products.map((p)=>p.id).toSet(),hasLength(53));
    final falafel=data.products.singleWhere((p)=>p.id==0);
    expect(falafel.name,'Falafel Dürüm');
    expect(falafel.priceTl,150.0);
    expect(falafel.names['ar'],isNotEmpty);
    expect(falafel.displayNames['en'],isNotEmpty);
    expect(falafel.descriptions['tr'],'Türkçe ürün açıklaması');
    expect(falafel.image,'assets/wrap-cutouts/wraps-transparent.webp');
    expect(data.products.singleWhere((p)=>p.id==51).name,'Vegan Dürüm');
    expect(data.products.singleWhere((p)=>p.id==52).name,'Layali Lübnan');
    expect(data.campaigns.single.title['ar'],isNotEmpty);
    expect(data.retrievedAtUtc.isUtc,isTrue);
  });

  test('campaign expiry respects timezone offsets',()async{
    final offer=(await QrCatalogFixture.reader(
      campaignsOverride:QrCatalogFixture.campaignJson.replaceFirst(
        '"endsAt":null','"endsAt":"2026-12-01T00:00:00+03:00"'),
    ).readPublishedMenu()).campaigns.single;
    expect(offer.isVisibleAt(DateTime.utc(2026,11,14)),isTrue);
    expect(offer.isVisibleAt(DateTime.utc(2026,11,30,21)),isFalse);
  });

  test('rejects CMS item added before stable ID exists',()async{
    final extra=jsonDecode(QrCatalogFixture.priceJson()) as Map;
    (extra['wrap'] as List).add({'name':'Unknown Wrap','price':100});
    await expectLater(
      QrCatalogFixture.reader(pricesOverride:jsonEncode(extra)).readPublishedMenu(),
      throwsFormatException,
    );
  });

  test('rejects CMS item removed before catalog regeneration',()async{
    await expectLater(
      QrCatalogFixture.reader(
        pricesOverride:QrCatalogFixture.priceJson(omitLast:true),
      ).readPublishedMenu(),
      throwsFormatException,
    );
  });

  test('rejects duplicate permanent ID',()async{
    await expectLater(
      QrCatalogFixture.reader(
        catalogOverride:QrCatalogFixture.catalog(duplicateId:0),
      ).readPublishedMenu(),
      throwsFormatException,
    );
  });

  test('rejects invalid product image path',()async{
    await expectLater(
      QrCatalogFixture.reader(
        catalogOverride:QrCatalogFixture.catalog(invalidImage:'../private.jpg'),
      ).readPublishedMenu(),
      throwsFormatException,
    );
  });

  test('rejects non-HTTPS base URL',()async{
    final reader=QrMenuReader(
      baseUrl:Uri.parse('http://localhost:9999/'),
      fetcher:(_)=>Future.value('{}'),
    );
    await expectLater(reader.readPublishedMenu(),throwsFormatException);
  });

  test('rejects malformed JSON without returning partial catalog',()async{
    await expectLater(
      QrCatalogFixture.reader(pricesOverride:'not-json').readPublishedMenu(),
      throwsA(anything),
    );
  });

  test('rejects duplicate product name even with distinct IDs',()async{
    final catalog=QrCatalogFixture.catalog();
    final products=catalog['products'] as List;
    (products.last as Map)['name']=(products.first as Map)['name'];
    await expectLater(
      QrCatalogFixture.reader(catalogOverride:catalog).readPublishedMenu(),
      throwsFormatException,
    );
  });
}
