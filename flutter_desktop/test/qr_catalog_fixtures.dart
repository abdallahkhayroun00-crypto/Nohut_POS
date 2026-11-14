import 'dart:convert';
import 'dart:io';

import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/qr_menu_reader.dart';

/// Exercises the real 51-item bundled POS ID allocation, plus the two new
/// published 51/52 identities. All network calls are stubbed.
class QrCatalogFixture {
  static List<Map<String,dynamic>> get legacyMenu {
    final source=jsonDecode(File('assets/menu.json').readAsStringSync()) as Map;
    return [for(final p in (source['products'] as List))
      Map<String,dynamic>.from(p as Map)];
  }

  static List<Map<String,dynamic>> get allProducts {
    final data=legacyMenu;
    if(data.length!=51 || data.first['id']!=0 ||
        data.last['id']!=50 || data.first['name']!='Falafel Dürüm') {
      throw StateError('Bundled POS fixture changed. Review stable IDs.');
    }
    data.addAll([
      {'id':51,'category':'wrap','name':'Vegan Dürüm','price':140},
      {'id':52,'category':'dessert','name':'Layali Lübnan','price':150},
    ]);
    return data;
  }

  static Map<String,String> locale(String tr) => {
    'tr':tr,'en':'EN '+tr,'ar':'عربي '+tr,
  };

  static List<Map<String,dynamic>> get categories {
    return [
      for(final c in const [
        ['all','Tümü'],['wrap','Dürümler'],['plate','Porsiyonlar'],
        ['fatte','Fatte'],['meze','Mezeler'],['side','Diğer'],
        ['salad','Salatalar'],['dessert','Tatlı'],['drink','İçecekler'],
      ])
        {'id':c[0],'name':locale(c[1]),'description':locale('Açıklama')},
    ];
  }

  static Map<String,dynamic> catalog({int? duplicateId,String? invalidImage}) {
    return {
      'schemaVersion':1,
      'source':'nohutfalafel/qr-menu',
      'currency':'TRY',
      'categories':categories,
      'products':[
        for(final p in allProducts)
          {
            'id': p['name']=='Vegan Dürüm' && duplicateId!=null
                ? duplicateId : p['id'],
            'category':p['category'],
            'name':locale(p['name'] as String),
            'displayName':locale(p['name'] as String),
            'description':locale('Türkçe ürün açıklaması'),
            'price':p['price'],
            'image': p['name']=='Falafel Dürüm'
                ? (invalidImage??'assets/wrap-cutouts/wraps-transparent.webp')
                :null,
          },
      ],
      'campaigns':[],
    };
  }

  static String priceJson({double? falafelPrice,bool omitLast=false}) {
    final result=<String,List<Map<String,dynamic>>>{};
    final products=allProducts;
    for(final p in omitLast?products.take(52):products){
      final name=p['name'] as String;
      result.putIfAbsent(p['category'] as String,()=>[])
        .add({'name':name,'price':name=='Falafel Dürüm' && falafelPrice!=null
            ? falafelPrice:p['price']});
    }
    return jsonEncode(result);
  }

  static String get campaignJson => jsonEncode([
    {
      'id':'falafel-menu-250','active':true,'price':250,
      'title':locale('Falafel Menü'),
      'description':locale('Dört lezzet'),
      'items':[locale('Falafel Dürüm')],
      'poster':'assets/campaigns/falafel-menu-250.webp',
      'thumbnail':'assets/campaigns/falafel-menu-250-thumb.webp',
      'startsAt':null,'endsAt':null,
    },
  ]);

  static QrMenuReader reader({
    Map<String,dynamic>? catalogOverride,
    String? pricesOverride,
    String? campaignsOverride,
    bool offline=false,
    List<Uri>? requests,
  }) {
    return QrMenuReader(fetcher:(uri)async{
      requests?.add(uri);
      if(offline)throw const SocketException('offline');
      if(uri.path.endsWith('/cms/catalog-v1.json')) {
        return jsonEncode(catalogOverride??catalog());
      }
      if(uri.path.endsWith('/cms/menu-prices.json')) {
        return pricesOverride??priceJson();
      }
      if(uri.path.endsWith('/cms/campaigns.json')) {
        return campaignsOverride??campaignJson;
      }
      throw StateError('Unexpected endpoint: '+uri.toString());
    });
  }

  static Future<PublishedQrMenu> snapshot({double? falafelPrice}) =>
      reader(pricesOverride:priceJson(falafelPrice:falafelPrice)).readPublishedMenu();

  static Json localState({bool enabled=true}) {
    final state=emptyPosState();
    state['localMenu']=legacyMenu;
    state['settings']={'qrAutoSync':enabled};
    // The snapshot of an existing sale MUST be immutable across future prices.
    state['orders']=[
      {
        'id':1200,'source':'Gel-Al','closed':true,'cancelled':false,
        'batches':[{
          'id':1,'lines':[{
            'productId':0,'name':'Falafel Dürüm','price':140,
            'qty':1,'removed':[],'note':'',
          }]
        }],
        'payments':[{'method':'Nakit','amount':140,'refunds':[]}],
      },
    ];
    state['nextId']=1201;
    return state;
  }
}
