import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'qr_menu_reader.dart';
import 'qr_menu_sync.dart';
import 'qr_publisher_client.dart';

class QrMenuManagement extends StatefulWidget {
  const QrMenuManagement({super.key,
    required this.state,required this.edit,required this.store,required this.sync});
  final Json state;
  final EditState edit;
  final PosStore store;
  final QrMenuAutoSync sync;
  @override State<QrMenuManagement> createState()=>_QrMenuManagementState();
}

class _QrMenuManagementState extends State<QrMenuManagement> {
  late final QrPublisherClient publisher;
  Json? menu;
  Json? sourceSnapshot;
  String? revision;
  bool busy=false,changed=false;
  String info='Yayınlama hizmetine bağlanarak menüyü yükleyin.';
  String tab='Ürünler',query='',filterCategory='all';
  @override void initState(){
    super.initState();
    publisher=QrPublisherClient(widget.store.filePath);
    final saved=widget.state['qrPublisherDraft'];
    if(saved is Map){
      menu=copyJson(Map<String,dynamic>.from(saved));
      final snapshot=widget.state['qrPublisherDraftSourceSnapshot'];
      if(snapshot is Map)sourceSnapshot=copyJson(Map<String,dynamic>.from(snapshot));
      revision=widget.state['qrPublisherDraftRevision']?.toString();
      changed=true;
      info='Önceki yerel taslak geri yüklendi. Yayımlanmamış değişiklikler var.';
    }
  }
  String get endpoint=>
    (widget.state['settings']?['qrPublisherUrl']??'http://127.0.0.1:8787').toString();
  List<Json> get products=>asMaps(menu?['products']);
  List<Json> get categories=>asMaps(menu?['categories']);
  List<Json> get campaigns=>asMaps(menu?['campaigns']);
  String tr(Map p,String key)=>p[key] is Map
    ?(p[key]['tr']??'').toString():'';
  Map<String,String> translations(Object? field){
    final m=field is Map?field:<String,dynamic>{};
    return {
      'tr':(m['tr']??'').toString(),
      'en':(m['en']??'').toString(),
      'ar':(m['ar']??'').toString(),
    };
  }
  /// Allow the manager to inspect and edit an offline draft even before the
  /// GitHub App local publishing service is running. Publishing stays disabled.
  Future<Json> _readPublicWebsiteDraft() async {
    final public=await QrMenuReader().readPublishedMenu();
    return <String,dynamic>{
      'schemaVersion':1,
      'source':'nohutfalafel/qr-menu',
      'currency':'TRY',
      'categories':[
        for(var i=0;i<public.categories.length;i++)
          {
            'id':public.categories[i].id,
            'name':public.categories[i].names,
            'description':public.categories[i].descriptions,
            'active':public.categories[i].active,
            'order':i,
          }
      ],
      'products':[
        for(var i=0;i<public.products.length;i++)
          {
            'id':public.products[i].id,
            'category':public.products[i].category,
            'legacyKey':public.products[i].legacyKey??public.products[i].name,
            'name':public.products[i].names,
            'displayName':public.products[i].displayNames,
            'description':public.products[i].descriptions,
            'price':public.products[i].priceTl,
            'active':public.products[i].active,
            'available':public.products[i].available,
            'image':public.products[i].image,
            'order':i,
          }
      ],
      'campaigns':[
        for(final offer in public.campaigns)
          {
            'id':offer.id,
            'active':offer.active,
            'price':offer.priceTl,
            'title':offer.title,
            'description':offer.description,
            'items':offer.items,
            'poster':offer.poster,
            'thumbnail':offer.thumbnail,
            'startsAt':offer.startsAt?.toIso8601String(),
            'endsAt':offer.endsAt?.toIso8601String(),
          }
      ],
    };
  }

  Future<void> load({bool force=false})async{
    if(busy)return;
    if(changed&&!force){
      final yes=await confirmAction(context,'Yerel Taslağı Değiştir?',
        'Yayımlanmamış yerel düzenlemeler güncel GitHub verisiyle değiştirilecek.',
        confirm:'Taslağı Değiştir');
      if(!yes||!mounted)return;
    }
    setState(()=>busy=true);
    try{
      final remote=await publisher.catalog(endpoint);
      final raw=remote['catalog'];
      if(raw is! Map)throw const FormatException('Katalog yanıtı geçersiz.');
      final data=copyJson(Map<String,dynamic>.from(raw));
      if(data['products'] is! List||data['categories'] is! List||
         data['campaigns'] is! List)throw const FormatException('Katalog eksik.');
      if(!mounted)return;
      setState((){
        menu=data;sourceSnapshot=copyJson(data);
        revision=remote['revision']?.toString();
        changed=false;
        info='GitHub kataloğu okundu. Kaydet ve Yayınla birbirinden ayrıdır.';
      });
      widget.edit((state){
        state.remove('qrPublisherDraft');
        state.remove('qrPublisherDraftRevision');
        state.remove('qrPublisherDraftSourceSnapshot');
      });
    }catch(e){
      // Never overwrite an existing draft when GitHub is unavailable.
      if(menu!=null){
        if(mounted)setState(()=>info='GitHub menüsü yüklenemedi; yerel taslağınız '
          'korundu. Yayınlama bağlantısını kontrol edin. Hata: $e');
        return;
      }
      // Display public content as a local, editable draft. Never claim that
      // the GitHub revision is known or publishing is available offline.
      try{
        final fallback=await _readPublicWebsiteDraft();
        if(!mounted)return;
        setState((){
          menu=fallback;sourceSnapshot=copyJson(fallback);
          revision=null;changed=true;
          info='Resmî QR web menüsü taslak olarak açıldı. Ürünleri ve TR/EN/AR '
            'çevirileri düzenleyebilirsiniz. GitHub yayını için önce '
            'Ayarlar > Entegrasyonlar > Nohut QR Publisher bağlantısını açın. '
            'Bağlandıktan sonra taslağınızı gözden geçirip güncel sürüme '
            'uyarlayın; bu taslak otomatik yayınlanmaz.';
        });
        widget.edit((state){
          state['qrPublisherDraft']=copyJson(fallback);
          state['qrPublisherDraftSourceSnapshot']=copyJson(fallback);
          state.remove('qrPublisherDraftRevision');
        });
      }catch(e){
        if(mounted)setState(()=>info=
          'QR web menüsü de yüklenemedi: '+e.toString()+
          '. Ağ bağlantısını ve Menü > Şimdi Eşitle durumunu kontrol edin.');
      }
    }finally{if(mounted)setState(()=>busy=false);}
  }
  /// Attach an offline draft to the latest GitHub revision without
  /// dropping local edits. Remote-only records are preserved.
  Future<void> linkOfflineDraft()async{
    if(menu==null||revision!=null||busy)return;
    setState(()=>busy=true);
    try{
      final response=await publisher.catalog(endpoint);
      final remoteRaw=response['catalog'];
      final remoteRevision=response['revision']?.toString();
      if(remoteRaw is! Map||remoteRevision==null||remoteRevision.isEmpty)
        throw const FormatException('GitHub kataloğu veya sürümü alınamadı.');
      final latest=copyJson(Map<String,dynamic>.from(remoteRaw));
      if(latest['products'] is! List||latest['categories'] is! List||
          latest['campaigns'] is! List)
        throw const FormatException('GitHub kataloğu eksik.');
      final draft=copyJson(menu!);
      var remoteAdded=0;
      for(final field in ['categories','products','campaigns']){
        final localRows=draft[field] as List;
        for(final record in latest[field] as List){
          if(record is! Map)continue;
          final id=record['id'];
          final existing=localRows.whereType<Map>().where((r)=>r['id']==id);
          if(existing.isEmpty){
            localRows.add(copyJson(Map<String,dynamic>.from(record)));
            remoteAdded++;
          }else if(field=='products' &&
              existing.first['legacyKey']!=record['legacyKey']){
            throw FormatException('GitHub ürün kimliği değişmiş: $id');
          }
        }
      }
      if(!mounted)return;
      final confirmed=await confirmAction(context,
        'Yerel Taslağı GitHub’a Bağla',
        'Mevcut taslak silinmeyecek. GitHub’daki $remoteAdded yeni kayıt '
        'taslağa eklenecek. Ortak ürünlerde sizin yerel düzenlemeleriniz '
        'öncelikli olacak; bu nedenle fiyat ve stok değişikliklerini '
        'önizlemede kontrol edin. Henüz webde yayın yapılmayacak.',
        confirm:'Taslağı Bağla');
      if(!confirmed||!mounted)return;
      setState((){
        menu=draft;
        sourceSnapshot=latest;
        revision=remoteRevision;
        changed=true;
        info='Taslak GitHub sürümüne bağlandı. $remoteAdded yeni kayıt '
          'korundu. Önizleyin, ardından GitHub’a Yayınla seçin.';
      });
      saveDraft();
    }on FormatException catch(e){
      if(mounted)setState(()=>info='Taslak değişmedi: ${e.message}');
    }catch(_){
      if(mounted)setState(()=>info='GitHub bağlantısı kurulamadı; '
        'yerel taslak korundu. Ayarlar > Entegrasyonlar bölümünü kontrol edin.');
    }finally{if(mounted)setState(()=>busy=false);}
  }

  Future<void> quickPrice(Json product)async{
    final controller=TextEditingController(text:(product['price']??0).toString());
    final result=await showDialog<String>(context:context,builder:(dialog)=>
      AlertDialog(
        title:Text('${tr(product,'name')} · Fiyat'),
        content:SizedBox(width:330,child:Column(
          mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.start,
          children:[
            const Text('Yeni fiyat yalnızca taslağa kaydedilir. '
              'GitHub’a Yayınla sonrası QR menüde değişir.'),
            const SizedBox(height:14),
            TextField(controller:controller,autofocus:true,
              keyboardType:const TextInputType.numberWithOptions(decimal:true),
              decoration:const InputDecoration(
                labelText:'Satış fiyatı',prefixText:'₺ ',
                border:OutlineInputBorder())),
          ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog),
            child:const Text('Vazgeç')),
          FilledButton(onPressed:()=>Navigator.pop(dialog,controller.text.trim()),
            child:const Text('Fiyatı Kaydet')),
        ],
      ));
    controller.dispose();
    if(result==null)return;
    try{
      final price=fromCents(parseMoney(result));
      final row=(menu?['products'] as List?)?.whereType<Map>()
        .firstWhere((p)=>p['id']==product['id']);
      if(row==null)return;
      row['price']=price;
      updated();
    }catch(_){
      if(mounted)setState(()=>info='Geçersiz fiyat. Örnek: 140 veya 140,50.');
    }
  }

  Json? originalProduct(int id){
    final rows=sourceSnapshot?['products'];
    if(rows is! List)return null;
    for(final row in rows){
      if(row is Map&&row['id']==id)
        return Map<String,dynamic>.from(row);
    }
    return null;
  }
  bool isProductEdited(Json p){
    final original=originalProduct(p['id'] as int);
    return original==null||jsonEncode(original)!=jsonEncode(p);
  }
  List<String> describeChanges(){
    if(menu==null||sourceSnapshot==null)return [];
    final result=<String>[];
    for(final p in products){
      final old=originalProduct(p['id'] as int);
      final name=tr(p,'name');
      if(old==null){
        result.add('Yeni ürün: $name');
        continue;
      }
      if(old['price']!=p['price'])
        result.add('$name: fiyat ${old['price']} → ${p['price']} ₺');
      if(old['available']!=p['available'])
        result.add('$name: ${p['available']==false?'Tükendi':'Stokta Var'}');
      if(old['active']!=p['active'])
        result.add('$name: ${p['active']==false?'QR’den gizlendi':'QR’de gösteriliyor'}');
      if(old['category']!=p['category'])
        result.add('$name: kategori değiştirildi');
      if(jsonEncode(old['name'])!=jsonEncode(p['name'])||
          jsonEncode(old['displayName'])!=jsonEncode(p['displayName'])||
          jsonEncode(old['description'])!=jsonEncode(p['description']))
        result.add('$name: isim / çeviri / açıklama güncellendi');
      if(old['image']!=p['image'])
        result.add('$name: görsel değişti');
    }
    for(final field in ['categories','campaigns']){
      final previous=sourceSnapshot![field];
      final current=menu![field];
      if(previous is! List||current is! List)continue;
      for(final c in current){
        if(c is! Map)continue;
        final before=previous.whereType<Map>().where((o)=>o['id']==c['id']);
        if(before.isEmpty||jsonEncode(before.first)!=jsonEncode(c))
          result.add('${field=='categories'?'Kategori':'Kampanya'} değişti: ${c['id']}');
      }
    }
    return result;
  }
  void restoreProduct(Json p){
    final original=originalProduct(p['id'] as int);
    if(original==null)return;
    final rows=menu?['products'] as List?;
    if(rows==null)return;
    final index=rows.indexWhere((x)=>x is Map&&x['id']==p['id']);
    if(index<0)return;
    rows[index]=copyJson(original);
    updated();
  }

  void saveDraft(){
    if(menu==null)return;
    final copy=copyJson(menu!);
    final ok=widget.edit((state){
      state['qrPublisherDraft']=copy;
      state['qrPublisherDraftRevision']=revision;
      if(sourceSnapshot!=null)
        state['qrPublisherDraftSourceSnapshot']=copyJson(sourceSnapshot!);
    });
    if(mounted)setState((){
      changed=ok;
      info=ok?'Taslak yalnızca bu bilgisayarda kaydedildi. Web henüz değişmedi.':
        'Yerel taslak kaydedilemedi.';
    });
  }
  void updated(){
    if(mounted)setState(()=>changed=true);
    saveDraft();
  }
  Future<void> preview()async{
    if(menu==null)return;
    final changes=describeChanges();
    await showDialog<void>(
      context:context,
      builder:(dialog)=>Dialog(
        insetPadding:const EdgeInsets.all(18),
        child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:780,maxHeight:650),
          child:Padding(
            padding:const EdgeInsets.all(20),
            child:DefaultTabController(length:2,child:Column(
              crossAxisAlignment:CrossAxisAlignment.stretch,
              children:[
                Text('QR Menü · Yayın Önizlemesi',
                  style:Theme.of(dialog).textTheme.titleLarge),
                const SizedBox(height:5),
                const Text('Bu ekran yerel taslağı gösterir. '
                  'GitHub Pages henüz değişmedi.'),
                const SizedBox(height:10),
                const TabBar(tabs:[
                  Tab(text:'Değişiklikleri İncele'),
                  Tab(text:'Tüm Ürünler'),
                ]),
                Expanded(child:TabBarView(children:[
                  changes.isEmpty
                    ?const Center(child:Text(
                      'Karşılaştırılacak değişiklik yok. '
                      'Yeni / bağlı olmayan taslakta tüm ürünleri kontrol edin.'))
                    :ListView.builder(
                      padding:const EdgeInsets.symmetric(vertical:8),
                      itemCount:changes.length,
                      itemBuilder:(context,i)=>ListTile(
                        leading:const Icon(Icons.change_circle_outlined,
                          color:NohutBrand.green),
                        title:Text(changes[i]),
                      )),
                  ListView.builder(
                    padding:const EdgeInsets.symmetric(vertical:8),
                    itemCount:products.length,
                    itemBuilder:(context,i){
                      final p=products[i];
                      return ListTile(
                        title:Text(tr(p,'name')),
                        subtitle:Text('${translations(p['name'])['en']} · '
                          '${p['category']} · '
                          '${p['active']==false?'Gizli':p['available']==false?'Tükendi':'Stokta'}'),
                        trailing:Text('₺${p['price']}',
                          style:const TextStyle(fontWeight:FontWeight.w700)),
                      );
                    }),
                ])),
                const SizedBox(height:10),
                Align(alignment:Alignment.centerRight,
                  child:FilledButton(
                    onPressed:()=>Navigator.pop(dialog),
                    child:const Text('Kapat'))),
              ],
            )),
          ),
        ),
      ),
    );
  }

  void moveCategory(String id,int amount){
    if(menu==null||id=='all')return;
    final source=menu!['categories'] as List;
    final sorted=<Map>[
      for(final item in source) if(item is Map)item,
    ]..sort((a,b)=>(a['order'] as int? ?? 0).compareTo(
      b['order'] as int? ?? 0));
    final from=sorted.indexWhere((item)=>item['id']==id);
    final target=from+amount;
    if(from<1||target<1||target>=sorted.length)return;
    final moving=sorted.removeAt(from);
    sorted.insert(target,moving);
    for(var index=0;index<sorted.length;index++){
      sorted[index]['order']=index;
    }
    updated();
  }

  Future<void> publish()async{
    if(menu==null||revision==null||busy)return;
    final differences=describeChanges();
    final summary=differences.take(6).join('\n');
    final approved=await confirmAction(context,'QR Menü · Gerçek Yayınlama',
      '${differences.length} değişiklik kontrol edildi.\n$summary\n\n'
      'Ürün, kategori, stok, çeviri ve kampanya değişiklikleri '
      'nohutfalafel/qr-menu ana dalına yazılacak. GitHub Pages sonra güncellenecek. '
      'Sipariş geçmişi değişmez.',
      confirm:'GitHub’a Yayınla');
    if(!approved||!mounted)return;
    setState(()=>busy=true);
    try{
      final answer=await publisher.publish(endpoint,revision!,copyJson(menu!));
      if(!mounted)return;
      setState((){
        revision=answer['revision']?.toString();
        sourceSnapshot=copyJson(menu!);
        changed=false;
        info='GitHub commit oluşturuldu: '+(answer['commit']??'').toString()+
          '. Pages dağıtımı henüz doğrulanmadı.';
      });
      widget.edit((state){
        state.remove('qrPublisherDraft');
        state.remove('qrPublisherDraftRevision');
        state.remove('qrPublisherDraftSourceSnapshot');
      });
    }on FormatException catch(e){
      if(mounted)setState(()=>info=e.message);
    }catch(_){
      if(mounted)setState(()=>info=
        'Yayınlama sonucu doğrulanamadı. Tekrar göndermeden GitHub geçmişini kontrol edin.');
    }finally{if(mounted)setState(()=>busy=false);}
  }

  Future<void> productEditor([Json? original])async{
    if(menu==null)return;
    final allCats=categories.where((c)=>c['id']!='all').toList();
    if(allCats.isEmpty)return;
    final originalCategory=original?['category']?.toString();
    var selectedCategory=allCats.any((c)=>c['id']==originalCategory)
      ?originalCategory!:allCats.first['id'].toString();
    final starting=[
      tr(original??{},'name'),
      translations(original?['name'])['en']!,
      translations(original?['name'])['ar']!,
      translations(original?['description'])['tr']!,
      translations(original?['description'])['en']!,
      translations(original?['description'])['ar']!,
      translations(original?['displayName'])['tr']!,
      translations(original?['displayName'])['en']!,
      translations(original?['displayName'])['ar']!,
      (original?['price']??'0').toString(),
      (original?['image']??'').toString(),
    ];
    final controls=[for(final item in starting)TextEditingController(text:item)];
    String error='';
    final values=await showDialog<List<String>>(
      context:context,
      builder:(dialog)=>StatefulBuilder(builder:(dialog,refresh){
        Widget field(int index,String label,{int lines=1})=>Padding(
          padding:const EdgeInsets.only(bottom:13),
          child:TextField(
            controller:controls[index],
            textDirection:[2,5,8].contains(index)
              ?TextDirection.rtl:TextDirection.ltr,
            maxLines:lines,
            keyboardType:index==9
              ?const TextInputType.numberWithOptions(decimal:true)
              :TextInputType.text,
            decoration:InputDecoration(
              border:const OutlineInputBorder(),
              labelText:label,
              isDense:true,
            ),
          ),
        );
        Widget fields(List<Widget> children)=>SingleChildScrollView(
          padding:const EdgeInsets.symmetric(horizontal:4,vertical:14),
          child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,
            children:children),
        );
        return Dialog(
          insetPadding:const EdgeInsets.all(20),
          child:ConstrainedBox(
            constraints:const BoxConstraints(maxWidth:720,maxHeight:710),
            child:Padding(
              padding:const EdgeInsets.all(22),
              child:DefaultTabController(
                length:3,
                child:Column(mainAxisSize:MainAxisSize.min,
                  crossAxisAlignment:CrossAxisAlignment.stretch,
                  children:[
                    Text(original==null?'Yeni Ürün Ekle':'Ürünü Düzenle',
                      style:Theme.of(dialog).textTheme.titleLarge),
                    const SizedBox(height:5),
                    const Text('Temel bilgiler, çeviriler ve açıklamalar '
                      'ayrı bölümlerde. Kaydet yalnızca yerel taslağı değiştirir.'),
                    const SizedBox(height:14),
                    const TabBar(tabs:[
                      Tab(text:'Ürün ve Fiyat'),
                      Tab(text:'İsimler · TR/EN/AR'),
                      Tab(text:'Açıklamalar'),
                    ]),
                    const SizedBox(height:8),
                    Flexible(child:TabBarView(children:[
                      fields([
                        field(0,'Ürün Adı · Türkçe'),
                        field(9,'Fiyat · ₺'),
                        Padding(
                          padding:const EdgeInsets.only(bottom:13),
                          child:DropdownButtonFormField<String>(
                            value:selectedCategory,
                            decoration:const InputDecoration(
                              labelText:'Kategori',border:OutlineInputBorder()),
                            items:[
                              for(final c in allCats)
                                DropdownMenuItem(
                                  value:c['id'].toString(),
                                  child:Text(tr(c,'name')),
                                ),
                            ],
                            onChanged:(v){
                              if(v!=null)refresh(()=>selectedCategory=v);
                            },
                          ),
                        ),
                        field(10,'Görsel Yolu · assets/...'),
                        const Text('Yeni görseli ürün listesindeki fotoğraf '
                          'butonundan seçebilirsiniz. GitHub bağlantısı gerekir.',
                          style:TextStyle(fontSize:12)),
                      ]),
                      fields([
                        field(0,'Türkçe · Ürün adı'),
                        field(1,'English · Product name'),
                        field(2,'العربية · اسم المنتج'),
                        const SizedBox(height:3),
                        const Text('Menüde gösterilecek kısa adlar (boş '
                          'bırakılırsa ürün adı kullanılır):'),
                        const SizedBox(height:9),
                        field(6,'Türkçe · Görünür ad'),
                        field(7,'English · Display name'),
                        field(8,'العربية · الاسم المعروض'),
                      ]),
                      fields([
                        field(3,'Türkçe · Açıklama',lines:3),
                        field(4,'English · Description',lines:3),
                        field(5,'العربية · الوصف',lines:3),
                      ]),
                    ])),
                    if(error.isNotEmpty)Padding(
                      padding:const EdgeInsets.only(top:8),
                      child:Text(error,style:TextStyle(
                        color:Theme.of(dialog).colorScheme.error)),
                    ),
                    const Divider(height:22),
                    Row(mainAxisAlignment:MainAxisAlignment.end,children:[
                      TextButton(onPressed:()=>Navigator.pop(dialog),
                        child:const Text('Vazgeç')),
                      const SizedBox(width:10),
                      FilledButton.icon(
                        icon:const Icon(Icons.save_outlined),
                        label:const Text('Taslağa Kaydet'),
                        onPressed:(){
                          final v=[for(final c in controls)c.text.trim()];
                          for(var i=0;i<3;i++){
                            if(v[6+i].isEmpty)v[6+i]=v[i];
                          }
                          String? problem;
                          if(v.take(3).any((x)=>x.isEmpty))
                            problem='TR / EN / AR ürün adlarını girin.';
                          else if(v.any((x)=>x.length>2500))
                            problem='Metin çok uzun.';
                          else if(products.any((p)=>
                            p['id']!=original?['id']&&
                            tr(p,'name').trim().toLowerCase()==
                              v[0].toLowerCase()))
                            problem='Bu Türkçe ürün adı zaten mevcut.';
                          if(problem==null){
                            try{parseMoney(v[9]);}
                            catch(_){problem='Geçerli bir fiyat girin.';}
                          }
                          if(problem==null&&v[10].isNotEmpty&&
                            (!RegExp(r'^assets/[a-zA-Z0-9_./-]+\.(png|jpg|jpeg|webp|svg)$')
                              .hasMatch(v[10])||v[10].contains('..')))
                            problem='Görsel yolu geçersiz (assets/...).';
                          if(problem!=null){
                            refresh(()=>error=problem!);
                            return;
                          }
                          Navigator.pop(dialog,[...v.take(10),selectedCategory,v[10]]);
                        },
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
    for(final c in controls){c.dispose();}
    if(values==null||!mounted)return;
    final rows=menu!['products'] as List;
    final newId=rows.fold<int>(0,(max,e)=>
      (e is Map&&e['id'] is int&&(e['id'] as int)>=max)
        ?(e['id'] as int)+1:max);
    final item=original==null?<String,dynamic>{
      'id':newId,'legacyKey':'pos-id-'+newId.toString(),
      'active':true,'available':true,'order':rows.length,
    }:Map<String,dynamic>.from(original);
    item.addAll({
      'name':{'tr':values[0],'en':values[1],'ar':values[2]},
      'description':{'tr':values[3],'en':values[4],'ar':values[5]},
      'displayName':{'tr':values[6],'en':values[7],'ar':values[8]},
      'price':fromCents(parseMoney(values[9])),
      'category':values[10],
      'image':values[11].isEmpty?null:values[11],
    });
    if(original==null)rows.add(item);
    else{
      final i=rows.indexWhere((r)=>r is Map&&r['id']==original['id']);
      if(i<0)return;
      rows[i]=item;
    }
    updated();
  }

  Future<void> categoryEditor([Json? original])async{
    if(menu==null)return;
    final values=await askFields(context,
      original==null?'Yeni Kategori':'Kategori Düzenle',
      [
        ('Kategori Kodu (ID)',original?['id']?.toString()??''),
        ('Türkçe',translations(original?['name'])['tr']!),
        ('English',translations(original?['name'])['en']!),
        ('العربية',translations(original?['name'])['ar']!),
        ('Türkçe Açıklama',translations(original?['description'])['tr']!),
        ('English · Description',translations(original?['description'])['en']!),
        ('العربية · الوصف',translations(original?['description'])['ar']!),
      ],
      validate:(v){
        if(!RegExp(r'^[a-z][a-z0-9-]{0,49}$').hasMatch(v[0]))
          return 'ID: küçük Latin harfleri / rakamlar.';
        if(original!=null&&v[0]!=original['id'])return 'Mevcut kategori ID değişemez.';
        if(v.skip(1).take(3).any((x)=>x.isEmpty))return 'TR / EN / AR gerekli.';
        if(original==null&&categories.any((x)=>x['id']==v[0]))
          return 'Kategori kodu zaten kullanılıyor.';
        return null;
      });
    if(values==null)return;
    final rows=menu!['categories'] as List;
    final item=original==null?<String,dynamic>{
      'id':values[0],'active':true,'order':rows.length,
    }:Map<String,dynamic>.from(original);
    item.addAll({
      'name':{'tr':values[1],'en':values[2],'ar':values[3]},
      'description':{'tr':values[4],'en':values[5],'ar':values[6]},
    });
    if(original==null)rows.add(item);
    else rows[rows.indexWhere((r)=>r is Map&&r['id']==original['id'])]=item;
    updated();
  }
  Future<void> campaignEditor([Json? original])async{
    if(menu==null)return;
    final v=await askFields(context,
      original==null?'Yeni Kampanya':'Kampanya Düzenle',
      [
        ('ID',original?['id']?.toString()??''),
        ('Başlık · Türkçe',translations(original?['title'])['tr']!),
        ('Title · English',translations(original?['title'])['en']!),
        ('العنوان · العربية',translations(original?['title'])['ar']!),
        ('Açıklama · Türkçe',translations(original?['description'])['tr']!),
        ('Description · English',translations(original?['description'])['en']!),
        ('الوصف · العربية',translations(original?['description'])['ar']!),
        ('Fiyat ₺',(original?['price']??'0').toString()),
        ('Poster · assets/..',(original?['poster']??'').toString()),
        ('Thumbnail · assets/..',(original?['thumbnail']??'').toString()),
      ],validate:(list){
        if(!RegExp(r'^[a-z0-9-]{1,70}$').hasMatch(list[0]))
          return 'Geçersiz kampanya ID.';
        if(list.skip(1).take(3).any((x)=>x.isEmpty))return 'Çeviri gerekli.';
        if(original!=null&&list[0]!=original['id'])return 'Kampanya ID değişemez.';
        try{parseMoney(list[7]);}catch(_){return 'Fiyatı kontrol edin.';}
        for(final path in [list[8],list[9]]){
          if(!RegExp(r'^assets/[A-Za-z0-9_./-]+\.(png|jpg|jpeg|webp)$')
            .hasMatch(path)||path.contains('..'))return 'Poster / Thumbnail yolu geçersiz.';
        }
        return null;
      });
    if(v==null)return;
    final rows=menu!['campaigns'] as List;
    final c=original==null?<String,dynamic>{
      'active':false,'items':[],
    }:Map<String,dynamic>.from(original);
    c.addAll({
      'id':v[0],
      'title':{'tr':v[1],'en':v[2],'ar':v[3]},
      'description':{'tr':v[4],'en':v[5],'ar':v[6]},
      'price':fromCents(parseMoney(v[7])),
      'poster':v[8],'thumbnail':v[9],
    });
    if(original==null)rows.add(c);
    else rows[rows.indexWhere((r)=>r is Map&&r['id']==original['id'])]=c;
    updated();
  }
  void toggle(String list,int id,String key,bool value){
    final rows=menu?[list] as List?;
    if(rows==null)return;
    final row=rows.cast<Map>().firstWhere((e)=>e['id']==id);
    row[key]=value;
    updated();
  }
  void toggleString(String list,String id,String key,bool value){
    final rows=menu?[list] as List?;
    if(rows==null)return;
    final row=rows.cast<Map>().firstWhere((e)=>e['id']==id);
    row[key]=value;
    updated();
  }
  Future<void> pickImage(Json product)async{
    if(!Platform.isWindows){
      setState(()=>info='Görsel yükleme Windows üzerinde desteklenir.');
      return;
    }
    const script=r'Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.OpenFileDialog; $d.Filter="Images (*.png;*.jpg;*.jpeg;*.webp)|*.png;*.jpg;*.jpeg;*.webp"; if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){ [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($d.FileName)) }';
    final encoded=base64Encode([for(final ch in script.codeUnits)...[ch&255,ch>>8]]);
    setState(()=>busy=true);
    try{
      final selected=await Process.run('powershell.exe',
        ['-STA','-NoProfile','-NonInteractive','-EncodedCommand',encoded])
        .timeout(const Duration(seconds:90));
      if(selected.exitCode!=0)throw const FormatException('Windows dosya seçimi başarısız.');
      final path=selected.stdout.toString().trim();
      if(path.isEmpty)return;
      final filename=utf8.decode(base64Decode(path));
      final file=File(filename),bytes=await file.readAsBytes();
      final lower=filename.toLowerCase();
      final mime=lower.endsWith('.png')?'image/png':
        lower.endsWith('.webp')?'image/webp':'image/jpeg';
      if(bytes.length>6000000)throw const FormatException('Görsel en fazla 6 MB.');
      final result=await publisher.uploadImage(endpoint,mime,bytes);
      final newPath=result['path']?.toString()??'';
      if(newPath.isEmpty)throw const FormatException('Görsel yolu alınamadı.');
      final rows=menu!['products'] as List;
      final index=rows.indexWhere((r)=>r is Map&&r['id']==product['id']);
      if(index<0)return;
      (rows[index] as Map)['image']=newPath;
      updated();
      if(mounted)setState(()=>info='Görsel GitHub’a yüklendi. '
        'Menüde görünmesi için değişiklikleri ayrıca Yayınla.');
    }on FormatException catch(e){
      if(mounted)setState(()=>info=e.message);
    }catch(_){
      if(mounted)setState(()=>info='Resim yüklenemedi. Servis bağlantısını kontrol edin.');
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Widget productCard(Json p){
    final visible=p['active']!=false;
    final available=p['available']!=false;
    final image=p['image']?.toString()??'';
    final hasImage=image.startsWith('assets/')&&!image.contains('..')&&
      !image.toLowerCase().endsWith('.svg');
    final theme=Theme.of(context);
    final names=translations(p['name']);
    final category=categories.where((c)=>c['id']==p['category']).toList();
    final categoryName=category.isEmpty?p['category'].toString()
      :tr(category.first,'name');
    return Card(
      elevation:0,
      margin:const EdgeInsets.only(bottom:10),
      color:theme.colorScheme.surface,
      shape:RoundedRectangleBorder(
        borderRadius:BorderRadius.circular(16),
        side:BorderSide(color:theme.dividerColor.withOpacity(0.28))),
      child:Padding(
        padding:const EdgeInsets.all(14),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Row(crossAxisAlignment:CrossAxisAlignment.center,children:[
            ClipRRect(
              borderRadius:BorderRadius.circular(12),
              child:SizedBox(width:68,height:68,
                child:hasImage?Image.network(
                  'https://nohutfalafel.github.io/qr-menu/$image',
                  fit:BoxFit.cover,
                  errorBuilder:(_,__,___)=>Container(
                    color:const Color(0xFFF1F2E9),
                    child:const Icon(Icons.restaurant_menu_outlined,
                      color:NohutBrand.green,size:28),
                  ),
                ):Container(
                  color:const Color(0xFFF1F2E9),
                  child:const Icon(Icons.restaurant_menu_outlined,
                    color:NohutBrand.green,size:28),
                ),
              ),
            ),
            const SizedBox(width:14),
            Expanded(child:Column(
              crossAxisAlignment:CrossAxisAlignment.start,
              children:[
                Text(names['tr']!,
                  maxLines:1,overflow:TextOverflow.ellipsis,
                  style:theme.textTheme.titleMedium?.copyWith(
                    fontWeight:FontWeight.w700,
                    color:const Color(0xFF173F32))),
                const SizedBox(height:3),
                Text('$categoryName · ${names['en']}',
                  maxLines:1,overflow:TextOverflow.ellipsis,
                  style:theme.textTheme.bodySmall),
                const SizedBox(height:7),
                Wrap(spacing:6,runSpacing:5,children:[
                  _statusPill(
                    visible?'QR’de Görünür':'QR’de Gizli',
                    visible?const Color(0xFFE7F4EC):const Color(0xFFF1EDE8),
                    visible?const Color(0xFF28613D):const Color(0xFF726558)),
                  _statusPill(
                    available?'Stokta Var':'Tükendi',
                    available?const Color(0xFFE9F2EB):const Color(0xFFFFF0E7),
                    available?const Color(0xFF28613D):const Color(0xFFAB4B26)),
                ]),
              ],
            )),
            const SizedBox(width:10),
            Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
              Text('₺${p['price']}',
                style:theme.textTheme.titleLarge?.copyWith(
                  color:const Color(0xFF173F32),fontWeight:FontWeight.w800)),
              const SizedBox(height:4),
              Text('#${p['id']}',style:theme.textTheme.labelSmall),
            ]),
          ]),
          const SizedBox(height:10),
          Divider(color:theme.dividerColor.withOpacity(0.3),height:1),
          const SizedBox(height:10),
          Wrap(spacing:7,runSpacing:7,children:[
            if(isProductEdited(p)&&originalProduct(p['id'] as int)!=null)
              OutlinedButton.icon(
                onPressed:busy?null:()async{
                  final ok=await confirmAction(context,
                    'Ürün Değişikliklerini Geri Al',
                    'Bu ürünün taslaktaki değişiklikleri geri alınacak. '
                    'Diğer ürünlerin değişiklikleri korunacak.',
                    confirm:'Ürünü Geri Al');
                  if(ok&&mounted)restoreProduct(p);
                },
                icon:const Icon(Icons.undo_outlined,size:18),
                label:const Text('Geri Al')),

            OutlinedButton.icon(
              onPressed:busy?null:()=>quickPrice(p),
              icon:const Icon(Icons.payments_outlined,size:18),
              label:const Text('Fiyatı Değiştir')),
            OutlinedButton.icon(
              onPressed:busy?null:()=>productEditor(p),
              icon:const Icon(Icons.edit_note_outlined,size:19),
              label:const Text('Ürünü Düzenle')),
            OutlinedButton.icon(
              onPressed:busy?null:()=>pickImage(p),
              icon:const Icon(Icons.add_photo_alternate_outlined,size:18),
              label:const Text('Görsel')),
            OutlinedButton.icon(
              onPressed:busy?null:()=>toggle('products',p['id'] as int,'available',!available),
              icon:Icon(available?Icons.remove_shopping_cart_outlined:
                Icons.check_circle_outline,size:18),
              label:Text(available?'Tükendi Yap':'Stokta Var Yap')),
            TextButton.icon(
              onPressed:busy?null:()=>toggle('products',p['id'] as int,'active',!visible),
              icon:Icon(visible?Icons.visibility_off_outlined:
                Icons.visibility_outlined,size:18),
              label:Text(visible?'QR’den Gizle':'QR’de Göster')),
          ]),
        ]),
      ),
    );
  }

  Widget _statusPill(String label,Color background,Color foreground)=>
    Container(
      padding:const EdgeInsets.symmetric(horizontal:10,vertical:5),
      decoration:BoxDecoration(
        color:background,borderRadius:BorderRadius.circular(30)),
      child:Text(label,style:TextStyle(
        fontSize:11,fontWeight:FontWeight.w700,color:foreground)),
    );

  @override Widget build(BuildContext context){
    final search=query.trim().toLowerCase();
    final filtered=products.where((p){
      final names=translations(p['name']);
      final matchesSearch=search.isEmpty||
        names.values.any((value)=>value.toLowerCase().contains(search))||
        translations(p['displayName']).values.any(
          (value)=>value.toLowerCase().contains(search));
      return matchesSearch&&(filterCategory=='all'||
        p['category']==filterCategory);
    }).toList()..sort((a,b)=>
      ((a['order'] as num?)?.toInt()??0)
        .compareTo((b['order'] as num?)?.toInt()??0));
    final theme=Theme.of(context);
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      panelTitle('QR Menü Yönetimi'),
      const SizedBox(height:4),
      Text('Menü, fiyat, stok ve çevirileri düzenleyin. '
        'Önce taslak kaydedilir; yalnızca Yayınla web sitesini değiştirir.',
        style:theme.textTheme.bodyMedium),
      const SizedBox(height:15),
      Card(
        elevation:0,
        color:const Color(0xFFF0F5F0),
        shape:RoundedRectangleBorder(
          borderRadius:BorderRadius.circular(18),
          side:const BorderSide(color:Color(0xFFD9E5DD))),
        child:Padding(
          padding:const EdgeInsets.all(18),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(children:[
              const Icon(Icons.cloud_sync_outlined,color:NohutBrand.green,size:28),
              const SizedBox(width:12),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Dijital Menü · Yayın Kontrolü',
                  style:theme.textTheme.titleMedium?.copyWith(
                    color:const Color(0xFF173F32),fontWeight:FontWeight.bold)),
                Text(menu==null?'Önce menüyü yükleyin.'
                  :revision==null?'Yerel taslak · GitHub bağlantısı gerekli'
                  :changed?'Yayımlanmamış değişiklikler var'
                  :'GitHub sürümüyle bağlantı kuruldu',
                  style:theme.textTheme.bodySmall),
              ])),
              if(menu!=null)_statusPill(
                revision==null?'Çevrimdışı Taslak'
                  :changed?'Yayın Bekliyor':'GitHub Bağlı',
                revision==null?const Color(0xFFFFEBDD)
                  :changed?const Color(0xFFFFEFC8):const Color(0xFFDCEEE3),
                revision==null?const Color(0xFF99512B)
                  :const Color(0xFF276144)),
            ]),
            const SizedBox(height:14),
            Wrap(spacing:9,runSpacing:9,children:[
              OutlinedButton.icon(
                onPressed:busy?null:load,
                icon:const Icon(Icons.cloud_download_outlined),
                label:const Text('GitHub’dan Yükle')),
              if(menu!=null&&revision==null)
                FilledButton.tonalIcon(
                  onPressed:busy?null:linkOfflineDraft,
                  icon:const Icon(Icons.link),
                  label:const Text('Taslağı GitHub’a Bağla')),
              OutlinedButton.icon(
                onPressed:menu==null||busy?null:saveDraft,
                icon:const Icon(Icons.save_outlined),
                label:const Text('Taslağı Kaydet')),
              OutlinedButton.icon(
                onPressed:menu==null||busy?null:preview,
                icon:const Icon(Icons.visibility_outlined),
                label:const Text('Önizle')),
              FilledButton.icon(
                onPressed:menu==null||busy||!changed||revision==null
                  ?null:publish,
                icon:const Icon(Icons.cloud_upload_outlined),
                label:const Text('GitHub’a Yayınla')),
              OutlinedButton.icon(
                onPressed:busy?null:()=>widget.sync.syncNow(),
                icon:const Icon(Icons.sync),
                label:const Text('POS’u Eşitle')),
            ]),
            if(busy)const Padding(
              padding:EdgeInsets.only(top:10),child:LinearProgressIndicator()),
            const SizedBox(height:11),
            Text(info,style:const TextStyle(
              fontSize:12.5,color:Color(0xFF315548))),
            if(menu!=null)...[
              const SizedBox(height:9),
              if(sourceSnapshot!=null)Text(
                '${describeChanges().length} taslak değişikliği',
                style:const TextStyle(
                  color:Color(0xFF79501C),fontWeight:FontWeight.w700)),
              const SizedBox(height:5),
              Wrap(spacing:12,runSpacing:5,children:[
                Text('${products.length} ürün',
                  style:const TextStyle(fontWeight:FontWeight.w600)),
                Text('${categories.length} kategori',
                  style:const TextStyle(fontWeight:FontWeight.w600)),
                Text('${campaigns.length} kampanya',
                  style:const TextStyle(fontWeight:FontWeight.w600)),
              ]),
            ],
          ]),
        ),
      ),
      if(menu==null)
        const Card(child:Padding(padding:EdgeInsets.all(24),
          child:Text('GitHub’dan Yükle ile menüyü açın. '
            'Çevrimdışı taslak oluşturabilirsiniz; yayınlamak için '
            'Ayarlar > Entegrasyonlar bağlantısı gerekir.')))
      else ...[
        const SizedBox(height:15),
        Wrap(spacing:8,runSpacing:8,children:[
          for(final name in ['Ürünler','Kategoriler','Kampanyalar'])
            ChoiceChip(label:Text(name),selected:tab==name,
              onSelected:(_)=>setState(()=>tab=name)),
        ]),
        const SizedBox(height:12),
        if(tab=='Ürünler')...[
          LayoutBuilder(builder:(context,c){
            final searchBox=TextField(
              decoration:const InputDecoration(
                hintText:'Ürün ara · Türkçe / English / العربية',
                prefixIcon:Icon(Icons.search),
                border:OutlineInputBorder()),
              onChanged:(value)=>setState(()=>query=value),
            );
            final add=FilledButton.icon(
              onPressed:busy?null:()=>productEditor(),
              icon:const Icon(Icons.add),
              label:const Text('Yeni Ürün Ekle'));
            return c.maxWidth<700
              ?Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                searchBox,const SizedBox(height:9),
                Align(alignment:Alignment.centerLeft,child:add),
              ])
              :Row(children:[
                Expanded(child:searchBox),
                const SizedBox(width:10),
                add,
              ]);
          }),
          const SizedBox(height:12),
          SingleChildScrollView(scrollDirection:Axis.horizontal,
            child:Row(children:[
              for(final c in categories)
                Padding(padding:const EdgeInsets.only(right:7),
                  child:ChoiceChip(
                    label:Text(tr(c,'name')),
                    selected:filterCategory==c['id'],
                    onSelected:(_)=>setState(()=>
                      filterCategory=c['id'].toString()),
                  )),
            ])),
          const SizedBox(height:12),
          Text('${filtered.length} ürün gösteriliyor',
            style:theme.textTheme.bodySmall),
          const SizedBox(height:8),
          if(filtered.isEmpty)
            const Card(child:Padding(padding:EdgeInsets.all(24),
              child:Text('Bu filtreyle eşleşen ürün yok.')))
          else
            for(final p in filtered)productCard(p),
        ]else if(tab=='Kategoriler')...[
          Align(alignment:Alignment.centerLeft,
            child:FilledButton.icon(onPressed:busy?null:()=>categoryEditor(),
              icon:const Icon(Icons.add),label:const Text('Kategori Ekle'))),
          const SizedBox(height:10),
          for(final c in categories)
            Card(
              elevation:0,
              child:ListTile(
                title:Text(tr(c,'name'),style:const TextStyle(
                  fontWeight:FontWeight.bold)),
                subtitle:Text('${c['id']} · ${translations(c['name'])['en']}'),
                trailing:Wrap(crossAxisAlignment:WrapCrossAlignment.center,children:[
                  Tooltip(message:'QR menüde görünür',
                    child:Switch(value:c['active']!=false,
                      onChanged:c['id']=='all'||busy?null:(value)=>
                        toggleString('categories',c['id'].toString(),'active',value))),
                  IconButton(
                    onPressed:c['id']=='all'||busy?null:
                      ()=>moveCategory(c['id'].toString(),-1),
                    tooltip:'Yukarı Taşı',icon:const Icon(Icons.arrow_upward)),
                  IconButton(
                    onPressed:c['id']=='all'||busy?null:
                      ()=>moveCategory(c['id'].toString(),1),
                    tooltip:'Aşağı Taşı',icon:const Icon(Icons.arrow_downward)),
                  IconButton(onPressed:busy?null:()=>categoryEditor(c),
                    tooltip:'Düzenle',icon:const Icon(Icons.edit_outlined)),
                ]),
              ),
            ),
        ]else if(tab=='Kampanyalar')...[
          Align(alignment:Alignment.centerLeft,
            child:FilledButton.icon(
              onPressed:busy?null:()=>campaignEditor(),
              icon:const Icon(Icons.add),label:const Text('Kampanya Ekle'))),
          const SizedBox(height:10),
          for(final c in campaigns)
            Card(
              elevation:0,
              child:ListTile(
                title:Text(tr(c,'title'),style:const TextStyle(
                  fontWeight:FontWeight.bold)),
                subtitle:Text('₺${c['price']} · ${translations(c['title'])['en']}'),
                trailing:Wrap(crossAxisAlignment:WrapCrossAlignment.center,children:[
                  _statusPill(c['active']==true?'Aktif':'Pasif',
                    c['active']==true?const Color(0xFFE7F4EC):
                      const Color(0xFFFFF0E7),
                    c['active']==true?const Color(0xFF28613D):
                      const Color(0xFFAB4B26)),
                  Switch(value:c['active']==true,onChanged:busy?null:(value)=>
                    toggleString('campaigns',c['id'].toString(),'active',value)),
                  IconButton(onPressed:busy?null:()=>campaignEditor(c),
                    tooltip:'Kampanyayı Düzenle',
                    icon:const Icon(Icons.edit_outlined)),
                ]),
              ),
            ),
        ],
        const SizedBox(height:12),
        const Text('Tüm düzenlemeler önce bu PC’de taslağa kaydedilir. '
          'QR’den Gizle ürünü silmez; Tükendi Yap ürünü görünür bırakır. '
          'Eski sipariş kayıtları ve fiyatları değişmez.',
          style:TextStyle(fontSize:12)),
      ],
    ]);
  }
}
