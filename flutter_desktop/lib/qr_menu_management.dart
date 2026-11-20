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
  String? revision;
  bool busy=false,changed=false;
  String info='Yayınlama hizmetine bağlanarak menüyü yükleyin.';
  String tab='Ürünler',query='';
  @override void initState(){
    super.initState();
    publisher=QrPublisherClient(widget.store.filePath);
    final saved=widget.state['qrPublisherDraft'];
    if(saved is Map){
      menu=copyJson(Map<String,dynamic>.from(saved));
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
        menu=data;revision=remote['revision']?.toString();
        changed=false;
        info='GitHub kataloğu okundu. Kaydet ve Yayınla birbirinden ayrıdır.';
      });
      widget.edit((state){
        state.remove('qrPublisherDraft');
        state.remove('qrPublisherDraftRevision');
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
          menu=fallback;revision=null;changed=true;
          info='Resmî QR web menüsü taslak olarak açıldı. Ürünleri ve TR/EN/AR '
            'çevirileri düzenleyebilirsiniz. GitHub yayını için önce '
            'Ayarlar > Entegrasyonlar > Nohut QR Publisher bağlantısını açın. '
            'Bağlandıktan sonra taslağınızı gözden geçirip güncel sürüme '
            'uyarlayın; bu taslak otomatik yayınlanmaz.';
        });
        widget.edit((state){
          state['qrPublisherDraft']=copyJson(fallback);
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

  void saveDraft(){
    if(menu==null)return;
    final copy=copyJson(menu!);
    final ok=widget.edit((state){
      state['qrPublisherDraft']=copy;
      state['qrPublisherDraftRevision']=revision;
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
  Future<void> preview() async {
    if(menu==null)return;
    await showDialog<void>(
      context:context,
      builder:(dialog)=>AlertDialog(
        title:const Text('QR Menü · Taslak Önizleme'),
        content:SizedBox(width:720,height:560,
          child:ListView(children:[
            const Text('Bu önizleme POS taslağındaki tüm ürün adlarını, '
              'fiyatlarını, stok ve görünürlük durumunu gösterir. '
              'GitHub Pages henüz değişmedi.'),
            const SizedBox(height:10),
            for(final p in products)
              Card(child:Padding(
                padding:const EdgeInsets.all(12),
                child:Column(
                  crossAxisAlignment:CrossAxisAlignment.start,
                  children:[
                    Text(translations(p['name'])['tr']!,
                      style:const TextStyle(fontWeight:FontWeight.bold)),
                    Text('TR: '+translations(p['description'])['tr']!),
                    Text('EN: '+translations(p['name'])['en']!+
                      ' · '+translations(p['description'])['en']!),
                    Directionality(
                      textDirection:TextDirection.rtl,
                      child:Text(translations(p['name'])['ar']!+
                        ' · '+translations(p['description'])['ar']!)),
                    Text('₺'+p['price'].toString()+' · '+
                      (p['active']==false?'GİZLİ':p['available']==false?
                        'TÜKENDİ':'STOKTA')+' · '+p['category'].toString()),
                  ],
                ),
              )),
          ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog),
            child:const Text('Kapat')),
        ],
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
    final approved=await confirmAction(context,'QR Menü · Gerçek Yayınlama',
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
        changed=false;
        info='GitHub commit oluşturuldu: '+(answer['commit']??'').toString()+
          '. Pages dağıtımı henüz doğrulanmadı.';
      });
      widget.edit((state){
        state.remove('qrPublisherDraft');
        state.remove('qrPublisherDraftRevision');
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
  @override Widget build(BuildContext context){
    final filtered=products.where((p)=>
      (p['name'] as Map?)?['tr'].toString().toLowerCase()
        .contains(query.toLowerCase())==true).toList();
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      panelTitle('QR Menü Yönetimi'),
      const Text('Nohut QR Menu · TR / EN / AR · Ürünler, stok, fiyat, kategoriler, '
        'kampanyalar ve GitHub yayınlama. Değişiklikler önce yerel taslağa kaydedilir.'),
      const SizedBox(height:13),
      Card(child:Padding(padding:const EdgeInsets.all(15),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Wrap(spacing:9,runSpacing:9,children:[
            OutlinedButton.icon(onPressed:busy?null:load,
              icon:const Icon(Icons.cloud_download_outlined),
              label:const Text('GitHub’dan Menü Yükle')),
            OutlinedButton.icon(onPressed:menu==null||busy?null:saveDraft,
              icon:const Icon(Icons.save_outlined),
              label:const Text('Taslak Kaydet')),
            OutlinedButton.icon(onPressed:menu==null?null:preview,
              icon:const Icon(Icons.visibility_outlined),
              label:const Text('Taslağı Önizle')),
            FilledButton.icon(onPressed:menu==null||busy||!changed||revision==null?null:publish,
              icon:const Icon(Icons.publish_outlined),
              label:const Text('GitHub’a Yayınla')),
            OutlinedButton.icon(onPressed:busy?null:()=>widget.sync.syncNow(),
              icon:const Icon(Icons.sync),
              label:const Text('POS Menüsünü Eşitle')),
          ]),
          if(busy)const LinearProgressIndicator(),
          const SizedBox(height:8),
          Text(info,style:const TextStyle(color:NohutBrand.green)),
          if(menu!=null)Text('Ürün: '+products.length.toString()+
            ' · Kategori: '+categories.length.toString()+
            ' · Kampanya: '+campaigns.length.toString()+
            (changed?' · YAYINLANMAMIŞ TASLAK':' · Güncel taslak')),
        ]))),
      if(menu==null)
        const Card(child:Padding(padding:EdgeInsets.all(20),
          child:Text('GitHub’dan Menü Yükle ile önce yayınlama hizmetini deneyin; '
            'hizmet kapalıysa POS resmî web menüsünü düzenlenebilir taslak '
            'olarak yüklemeyi dener. Yayın için Entegrasyonlar gerekli.')))
      else ...[
        const SizedBox(height:12),
        Wrap(spacing:8,children:[
          for(final name in ['Ürünler','Kategoriler','Kampanyalar','Çeviriler'])
            ChoiceChip(label:Text(name),selected:tab==name,
              onSelected:(_)=>setState(()=>tab=name)),
        ]),
        const SizedBox(height:12),
        if(tab=='Ürünler'||tab=='Çeviriler') ...[
          Row(children:[
            Expanded(child:TextField(
              decoration:const InputDecoration(
                labelText:'Ürün ara · TR / EN / AR',prefixIcon:Icon(Icons.search)),
              onChanged:(v)=>setState(()=>query=v),
            )),
            const SizedBox(width:10),
            FilledButton.icon(
              onPressed:()=>productEditor(),
              icon:const Icon(Icons.add),label:const Text('Yeni Ürün Ekle')),
          ]),
          const SizedBox(height:10),
          for(final p in filtered)
            Card(child:ListTile(
              title:Text(tr(p,'name')+' · '+p['price'].toString()+' ₺'),
              subtitle:Text((translations(p['name'])['en']??'')+
                ' · '+(translations(p['name'])['ar']??'')+
                ' · '+p['category'].toString()+
                (p['available']==false?' · STOKTA YOK':' · Stokta')),
              leading:IconButton(onPressed:()=>pickImage(p),
                icon:const Icon(Icons.add_photo_alternate_outlined),
                tooltip:'Resim Yükle'),
              trailing:Wrap(spacing:6,children:[
                Column(mainAxisSize:MainAxisSize.min,children:[
                  const Text('Aktif',style:TextStyle(fontSize:10)),
                  Switch(value:p['active']!=false,
                    onChanged:(v)=>toggle('products',p['id'] as int,'active',v)),
                ]),
                Column(mainAxisSize:MainAxisSize.min,children:[
                  const Text('Stokta',style:TextStyle(fontSize:10)),
                  Switch(value:p['available']!=false,
                    onChanged:(v)=>toggle('products',p['id'] as int,'available',v)),
                ]),
                IconButton(
                  onPressed:()=>productEditor(p),
                  tooltip:'TR / EN / AR · Düzenle',
                  icon:const Icon(Icons.edit_outlined)),
                IconButton(
                  onPressed:()async{
                    if(await confirmAction(context,'Ürünü Arşivle',
                      'Ürün geçmişi için ID korunacak; QR menüde gizlenecek.',
                      confirm:'Pasif Yap')){
                      toggle('products',p['id'] as int,'active',false);
                    }
                  },
                  tooltip:'Arşivle',icon:const Icon(Icons.archive_outlined)),
              ]),
            )),
        ]else if(tab=='Kategoriler') ...[
          Align(alignment:Alignment.centerLeft,
            child:FilledButton.icon(onPressed:()=>categoryEditor(),
              icon:const Icon(Icons.add),label:const Text('Kategori Ekle'))),
          for(final c in categories)
            Card(child:ListTile(
              title:Text(tr(c,'name')+' · '+c['id'].toString()),
              subtitle:Text(translations(c['name'])['en']!+
                ' · '+translations(c['name'])['ar']!),
              trailing:Wrap(children:[
                Switch(value:c['active']!=false,
                  onChanged:c['id']=='all'?null:
                    (v)=>toggleString('categories',c['id'].toString(),'active',v)),
                IconButton(onPressed:c['id']=='all'?null:
                  ()=>moveCategory(c['id'].toString(),-1),
                  tooltip:'Yukarı Taşı',icon:const Icon(Icons.arrow_upward)),
                IconButton(onPressed:c['id']=='all'?null:
                  ()=>moveCategory(c['id'].toString(),1),
                  tooltip:'Aşağı Taşı',icon:const Icon(Icons.arrow_downward)),
                IconButton(onPressed:()=>categoryEditor(c),
                  icon:const Icon(Icons.edit_outlined)),
              ]),
            )),
        ]else if(tab=='Kampanyalar') ...[
          Align(alignment:Alignment.centerLeft,
            child:FilledButton.icon(onPressed:()=>campaignEditor(),
              icon:const Icon(Icons.add),label:const Text('Kampanya Ekle'))),
          for(final c in campaigns)
            Card(child:ListTile(
              title:Text(tr(c,'title')+' · '+c['price'].toString()+' ₺'),
              subtitle:Text(translations(c['title'])['en']!+
                ' · '+translations(c['title'])['ar']!),
              trailing:Wrap(children:[
                Switch(value:c['active']==true,
                  onChanged:(v)=>toggleString(
                    'campaigns',c['id'].toString(),'active',v)),
                IconButton(onPressed:()=>campaignEditor(c),
                  icon:const Icon(Icons.edit_outlined)),
              ]),
            )),
        ],
        const SizedBox(height:10),
        const Text('Not: Sil işlemi arşivleme şeklindedir; ürün ID ve geçmiş '
          'siparişler silinmez. Çeviriler TR / EN / AR olarak ayrı kaydedilir.',
          style:TextStyle(fontSize:12)),
      ],
    ]);
  }
}
