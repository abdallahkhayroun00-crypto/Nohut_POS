// QR Menü Yönetimi (Windows): a compact catalog workspace over an offline
// draft. The page state is derived, never assumed: changes come from a real
// diff against the GitHub catalog the draft started from, an older draft is
// merged three-way onto newer GitHub data with explicit conflict review, and
// a publish whose answer was lost is reconciled before it can be retried.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'operations_ui.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'qr_menu_draft.dart';
import 'qr_menu_reader.dart';
import 'qr_menu_sync.dart';
import 'qr_image_crops.dart';
import 'qr_publish_transport.dart';
import 'qr_publisher_client.dart';
import 'qr_publisher_service.dart';

/// How far the publishing chain was verified on the last check.
enum QrLink { unknown, checking, noToken, serviceDown, githubError, connected }

class QrMenuManagement extends StatefulWidget {
  const QrMenuManagement({super.key,
    required this.state,required this.edit,required this.store,this.sync,
    this.publisher,this.readPublicMenu,this.now,this.networkImages=true,
    this.supervisor});
  final Json state;
  final EditState edit;
  final PosStore store;
  final QrMenuAutoSync? sync;
  /// Test seams: a fake publisher, the public website reader and the clock.
  final QrPublisherClient? publisher;
  final Future<Json> Function()? readPublicMenu;
  final DateTime Function()? now;
  final bool networkImages;
  /// Finds/starts the local publisher; tests pass a scripted one.
  final QrPublisherSupervisor? supervisor;
  @override State<QrMenuManagement> createState()=>_QrMenuManagementState();
}

class _QrMenuManagementState extends State<QrMenuManagement> {
  static const _draftKeys=['qrPublisherDraft','qrPublisherDraftRevision',
    'qrPublisherDraftSourceSnapshot'];
  static const _pendingKey='qrPublisherPendingPublish';
  late final QrPublisherClient publisher;
  QrPublisherSupervisor? supervisor;
  Json? menu;
  /// The GitHub (or public website) catalog the draft started from.
  Json? sourceSnapshot;
  String? revision;
  bool busy=false,publishing=false;
  QrLink link=QrLink.unknown;
  String? linkError;
  DateTime? verifiedAt;
  /// A merge that needs the owner's choice for each conflicting field.
  QrMergeResult? merge;
  Json? mergeRemote;
  String? mergeRevision;
  /// A publish that was sent but never answered (survives a restart).
  Json? pending;
  String info='';
  bool infoError=false;
  /// Why the local publisher is down, and the one action that fixes it.
  PublisherDiagnosis? diagnosis;
  bool showDetails=false;
  String tab='Ürünler',query='',filterCategory='all';

  DateTime now()=>(widget.now??DateTime.now)();

  @override void initState(){
    super.initState();
    publisher=widget.publisher??QrPublisherClient(widget.store.filePath);
    // Production only: a test that injects a publisher scripts the machine
    // through [QrMenuManagement.supervisor] or not at all.
    supervisor=widget.supervisor??(widget.publisher==null
      ?QrPublisherSupervisor(endpoint:endpoint,client:publisher):null);
    _restore();
    if(menu!=null&&changes.isNotEmpty)info='Bu bilgisayardaki taslak geri yüklendi.';
    final p=widget.state[_pendingKey];
    if(p is Map)pending=Map<String,dynamic>.from(p);
    WidgetsBinding.instance.addPostFrameCallback((_){
      if(mounted)connect(auto:true);
    });
  }

  /// Draft as last written by this page; anything else came from a phone.
  String _seenDraft='null';
  void _restore(){
    final saved=widget.state['qrPublisherDraft'];
    final snapshot=widget.state['qrPublisherDraftSourceSnapshot'];
    final rev=widget.state['qrPublisherDraftRevision']?.toString();
    _seenDraft=jsonEncode(saved);
    if(saved is Map){
      menu=copyJson(Map<String,dynamic>.from(saved));
      sourceSnapshot=snapshot is Map?copyJson(Map<String,dynamic>.from(snapshot)):null;
      revision=rev;
    }else if(snapshot is Map&&rev!=null){
      // Last known published catalog (kept so phones can edit against it).
      menu=copyJson(Map<String,dynamic>.from(snapshot));
      sourceSnapshot=copyJson(Map<String,dynamic>.from(snapshot));
      revision=rev;
    }
  }
  @override void didUpdateWidget(covariant QrMenuManagement old){
    super.didUpdateWidget(old);
    if(busy||publishing||merge!=null)return;
    // A phone may publish too (owner decision 2026-11-27): follow its
    // pending marker and the new published revision.
    final p=widget.state[_pendingKey];
    final incomingPending=p is Map?Map<String,dynamic>.from(p):null;
    if(jsonEncode(incomingPending)!=jsonEncode(pending)){
      pending=incomingPending;
      info=incomingPending!=null
        ?'Bir telefondan yayın gönderildi; sonuç bekleniyor.'
        :'Telefondan gönderilen yayının sonucu alındı.';
      infoError=false;
    }
    if(pending!=null)return;
    final incoming=jsonEncode(widget.state['qrPublisherDraft']);
    final rev=widget.state['qrPublisherDraftRevision']?.toString();
    if(incoming==_seenDraft&&rev==revision)return;
    final hadMenu=menu!=null,oldRevision=revision;
    _restore();
    if(!hadMenu)return;
    info=rev!=null&&oldRevision!=null&&rev!=oldRevision
      ?'Telefondan yayınlandı: ${qrRevisionLabel(rev)}.'
      :'Telefondan yapılan menü değişikliği alındı.';
    infoError=false;
  }

  String get endpoint=>QrPublisherClient.configuredEndpoint(
    widget.state['settings']?['qrPublisherUrl']);
  List<Json> get products=>asMaps(menu?['products']);
  List<Json> get categories=>asMaps(menu?['categories']);
  List<Json> get campaigns=>asMaps(menu?['campaigns']);
  List<QrChange> get changes=>diffCatalog(sourceSnapshot,menu);
  QrPageState get pageState=>qrPageState(hasMenu:menu!=null,busy:busy,
    publishing:publishing,revision:revision,changes:changes.length,
    conflicts:merge!=null,pendingPublish:pending!=null);
  /// Edits are frozen while the outcome of a publish or a merge is open.
  bool get canEdit=>menu!=null&&!busy&&!publishing&&pending==null&&merge==null;

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
  void say(String text,{bool error=false}){
    if(!mounted)return;
    setState((){info=text;infoError=error;});
  }

  /// The public website as a read-only starting point when the publisher
  /// cannot be reached. It is not saved until the owner edits it.
  Future<Json> _readPublicWebsiteDraft() async {
    if(widget.readPublicMenu!=null)return widget.readPublicMenu!();
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

  Json _catalogOf(Map<String,dynamic> answer){
    final raw=answer['catalog'];
    if(raw is! Map)throw const FormatException('Katalog yanıtı geçersiz.');
    final data=copyJson(Map<String,dynamic>.from(raw));
    if(data['products'] is! List||data['categories'] is! List||
        data['campaigns'] is! List)throw const FormatException('Katalog eksik.');
    return data;
  }

  /// Save the draft with its base, or forget it when nothing differs.
  void _persist(){
    if(menu==null)return;
    final dirty=changes.isNotEmpty;
    final copy=copyJson(menu!),base=sourceSnapshot==null?null:copyJson(sourceSnapshot!);
    final rev=revision;
    _seenDraft=dirty?jsonEncode(copy):'null';
    widget.edit((state){
      if(!dirty&&(rev==null||base==null)){
        for(final k in _draftKeys){state.remove(k);}
        return;
      }
      // The published base and its revision stay saved even without edits,
      // so Personel/Yönetici phones can edit against the same catalog.
      if(dirty)state['qrPublisherDraft']=copy;
      else state.remove('qrPublisherDraft');
      if(rev==null)state.remove('qrPublisherDraftRevision');
      else state['qrPublisherDraftRevision']=rev;
      if(base!=null)state['qrPublisherDraftSourceSnapshot']=base;
    });
  }
  void _setPending(Json? value){
    pending=value;
    final copy=value==null?null:copyJson(value);
    widget.edit((state){
      if(copy==null)state.remove(_pendingKey);
      else state[_pendingKey]=copy;
    });
  }

  String get linkText=>switch(link){
    QrLink.unknown=>'Kontrol edilmedi',
    QrLink.checking=>'Kontrol ediliyor…',
    QrLink.noToken=>'Yayınlama anahtarı kayıtlı değil',
    QrLink.serviceDown=>'Yayınlama hizmeti çalışmıyor',
    QrLink.githubError=>'GitHub okunamadı',
    QrLink.connected=>'GitHub bağlı',
  };
  String get linkHelp{
    final at=Uri.tryParse(endpoint);
    final where=at==null?endpoint:'${at.host}:${at.port}';
    return switch(link){
      QrLink.noToken=>'Ayarlar > Entegrasyonlar > Nohut QR Publisher bölümünde '
        'yönetici anahtarını kaydedin.',
      QrLink.serviceDown=>diagnosis==null
        ?'Yayınlama hizmeti $where adresinde yanıt vermiyor.'
        :'${diagnosis!.title}. ${diagnosis!.help}',
      QrLink.githubError=>'Hizmet çalışıyor ama GitHub kataloğu okunamadı: '
        '${linkError??'bilinmeyen hata'}. GitHub App anahtarını ve depo erişimini kontrol edin.',
      _=>'',
    };
  }

  Future<PublisherDiagnosis?> _diagnose()async{
    final d=await supervisor?.diagnose();
    if(d==null||d.issue==PublisherIssue.notWindows||
      d.issue==PublisherIssue.remoteEndpoint)return null;
    // The service runs but this POS lacks the access code: the script only
    // refreshes the DPAPI vaults in that case.
    if(d.ok&&link==QrLink.noToken)return PublisherDiagnosis(PublisherIssue.stopped,
      endpoint:d.endpoint,script:d.script,node:d.node,keyFound:true,
      lastStatus:d.lastStatus,logTail:d.logTail);
    return d.ok?null:d;
  }
  bool get _repairable=>diagnosis!=null;

  /// The one action the status card offers: start, restart, choose the key,
  /// or open the Node.js download page. Never publishes anything.
  Future<void> repair()async{
    final d=diagnosis,sup=supervisor;
    if(d==null||sup==null||busy)return;
    if(d.fix==PublisherFix.installNode){
      try{
        await Process.start('explorer.exe',['https://nodejs.org/tr/download'],
          mode:ProcessStartMode.detached);
        say('Node.js LTS indirme sayfası açıldı. Kurulumdan sonra Hizmeti Başlat’a basın.');
      }catch(_){
        say('Tarayıcı açılamadı. nodejs.org adresinden Node.js LTS kurun.',error:true);
      }
      return;
    }
    setState(()=>busy=true);
    PublisherDiagnosis? after;
    try{
      after=await sup.start(allowPrompt:d.fix==PublisherFix.chooseKey);
    }catch(e){
      after=null;
      say('Yayınlama hizmeti başlatılamadı: $e',error:true);
    }finally{if(mounted)setState(()=>busy=false);}
    if(!mounted)return;
    if(after!=null&&after.ok){
      say('Yayınlama hizmeti çalışıyor.');
      await connect();
    }else if(after!=null){
      setState(()=>diagnosis=after);
      say('${after.title}. ${after.help}',error:true);
    }
  }

  /// Verify the chain (key → local service → GitHub), then bring the draft
  /// onto the latest GitHub revision. Read-only towards GitHub.
  Future<void> connect({bool auto=false})async{
    if(busy||publishing)return;
    setState((){busy=true;link=QrLink.checking;linkError=null;});
    Map<String,dynamic>? answer;
    try{
      diagnosis=null;
      if(!await publisher.hasToken()){
        link=QrLink.noToken;
        diagnosis=await _diagnose();
      }else if(!await publisher.health(endpoint)){
        link=QrLink.serviceDown;
        diagnosis=await _diagnose();
      }else{
        try{
          answer=await publisher.catalog(endpoint);
          _catalogOf(answer);
          final rev=answer['revision']?.toString()??'';
          if(rev.isEmpty)throw const FormatException('GitHub sürümü alınamadı.');
          link=QrLink.connected;
          verifiedAt=now();
        }on FormatException catch(e){
          link=QrLink.githubError;linkError=e.message;answer=null;
        }
      }
    }catch(e){
      link=QrLink.githubError;linkError='$e';answer=null;
    }
    try{
      if(answer!=null){
        final remote=_catalogOf(answer),rev=answer['revision'].toString();
        if(pending!=null)_reconcile(rev,remote);
        else _adopt(rev,remote,auto:auto);
      }else{
        if(menu==null)await _openPublicDraft();
        if(pending!=null){
          say('Önceki yayının sonucu bilinmiyor ve şu an doğrulanamıyor. '
            '$linkHelp',error:true);
        }else if(menu!=null&&revision==null){
          // An expected state, not an error: the fix sits in the status card.
          say(_repairable
            ?'Çevrimdışı taslak: düzenleyebilirsiniz; yayınlamak için önce yayınlama hizmetini düzeltin.'
            :'Çevrimdışı taslak: düzenleyebilirsiniz, yayın için bağlantı gerekli. $linkHelp');
        }else{
          say('Yayınlama bağlantısı yok. $linkHelp',error:true);
        }
      }
    }finally{if(mounted)setState(()=>busy=false);}
    if(!auto&&merge!=null&&mounted)await resolveConflicts();
  }

  Future<void> _openPublicDraft()async{
    try{
      final fallback=await _readPublicWebsiteDraft();
      menu=fallback;sourceSnapshot=copyJson(fallback);revision=null;
    }catch(e){
      say('QR web menüsü de okunamadı: $e. İnternet bağlantısını kontrol edin.',error:true);
    }
  }

  void _adopt(String rev,Json remote,{bool auto=false}){
    if(menu==null){
      menu=copyJson(remote);sourceSnapshot=copyJson(remote);revision=rev;
      _persist();
      say('GitHub kataloğu yüklendi. Düzenlemeler önce bu bilgisayarda taslak olur.');
      return;
    }
    if(revision==rev&&sourceSnapshot!=null){
      _persist();
      say(changes.isEmpty?'Menü yayındaki GitHub sürümüyle aynı.'
        :'Taslak yayındaki GitHub sürümüne bağlı. ${changes.length} değişiklik yayın bekliyor.');
      return;
    }
    final wasOffline=revision==null;
    final QrMergeResult result;
    try{
      result=mergeOfflineDraft(
        base:sourceSnapshot??{for(final l in qrCatalogLists)l:<Object?>[]},
        local:menu!,remote:remote);
    }on FormatException catch(e){
      say('Taslak GitHub sürümüyle birleştirilemedi: ${e.message}. '
        'Taslağı atıp GitHub’dan yeniden yükleyin.',error:true);
      return;
    }
    if(result.conflicts.isNotEmpty){
      merge=result;mergeRemote=remote;mergeRevision=rev;
      say('${result.conflicts.length} alan hem taslakta hem GitHub’da değişmiş. '
        'Yayından önce her biri için hangisinin kalacağını seçin.',error:true);
      return;
    }
    menu=result.merged;sourceSnapshot=copyJson(remote);revision=rev;
    _persist();
    final kept=changes.length;
    say('${wasOffline?'Çevrimdışı taslak GitHub’a bağlandı':'GitHub’da daha yeni bir sürüm vardı'}: '
      '${result.fromGitHub} GitHub değişikliği alındı, taslaktaki $kept değişiklik korundu.');
  }

  /// A publish was sent but not answered: decide from GitHub what happened.
  void _reconcile(String rev,Json remote){
    final sent=pending?['revision']?.toString();
    _setPending(null);
    if(rev==sent){
      _adopt(rev,remote);
      say('Önceki yayın GitHub’a ulaşmamış; web menüsü değişmedi. '
        'Taslak korunuyor, yeniden yayınlayabilirsiniz.',error:true);
      return;
    }
    if(menu!=null&&diffCatalog(remote,menu).isEmpty){
      menu=copyJson(remote);sourceSnapshot=copyJson(remote);revision=rev;
      _persist();
      say('Önceki yayın doğrulandı: GitHub menüsü taslakla aynı (sürüm ${qrRevisionLabel(rev)}).');
      return;
    }
    _adopt(rev,remote);
    if(merge==null)say('GitHub sürümü değişmiş ama taslakla aynı değil. '
      'Kalan farkları inceleyip yeniden yayınlayın. $info',error:true);
  }

  Future<void> resolveConflicts()async{
    final m=merge;
    if(m==null)return;
    final choice=<String,String>{};
    final apply=await showDialog<bool>(context:context,builder:(dialog)=>
      StatefulBuilder(builder:(dialog,refresh)=>AlertDialog(
        key:const ValueKey('qr-conflicts'),
        title:const Text('Taslak ve GitHub Çakışıyor'),
        content:SizedBox(width:640,child:Column(
          mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          const Text('Bu alanlar taslak oluşturulduktan sonra GitHub’da da '
            'değişti. Hiçbiri sessizce ezilmez: her biri için kalacak değeri seçin. '
            'Diğer tüm değişiklikler otomatik birleştirildi.'),
          const SizedBox(height:12),
          Flexible(child:ListView(shrinkWrap:true,children:[
            for(final c in m.conflicts)Padding(
              padding:const EdgeInsets.only(bottom:10),
              child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('${c.label.isEmpty?c.id:c.label} · ${_fieldName(c.field)}',
                  style:const TextStyle(fontWeight:FontWeight.w700)),
                const SizedBox(height:5),
                Wrap(spacing:8,runSpacing:6,children:[
                  ChoiceChip(key:ValueKey('qr-keep-local-${c.key}'),
                    label:Text('Taslak: ${c.field=='*'?'tut':c.show(c.local)}'),
                    selected:choice[c.key]=='local',
                    onSelected:(_)=>refresh(()=>choice[c.key]='local')),
                  ChoiceChip(key:ValueKey('qr-keep-remote-${c.key}'),
                    label:Text('GitHub: ${c.field=='*'?'silinmiş':c.show(c.remote)}'),
                    selected:choice[c.key]=='remote',
                    onSelected:(_)=>refresh(()=>choice[c.key]='remote')),
                ]),
              ]),
            ),
          ])),
        ])),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog,false),
            child:const Text('Sonra')),
          FilledButton(key:const ValueKey('qr-apply-merge'),
            onPressed:choice.length==m.conflicts.length
              ?()=>Navigator.pop(dialog,true):null,
            child:Text('Seçimleri Uygula (${choice.length}/${m.conflicts.length})')),
        ],
      )));
    if(apply!=true||!mounted)return;
    setState((){
      menu=m.resolve(choice);
      sourceSnapshot=copyJson(mergeRemote!);
      revision=mergeRevision;
      merge=null;mergeRemote=null;mergeRevision=null;
    });
    _persist();
    say('Çakışmalar çözüldü. ${changes.length} değişiklik yayın bekliyor.');
  }
  String _fieldName(String f)=>const {
    '*':'kayıt GitHub’da silinmiş','price':'fiyat','available':'stok',
    'active':'QR görünürlüğü','name':'isim','displayName':'görünen ad',
    'description':'açıklama','category':'kategori','image':'görsel',
    'order':'sıra','title':'başlık',
  }[f]??f;

  Future<void> discardDraft()async{
    final yes=await confirmAction(context,'Taslağı At?',
      '${changes.length} yayınlanmamış değişiklik silinecek ve menü GitHub’dan '
      'yeniden yüklenecek. Web menüsü değişmez.',confirm:'Taslağı At');
    if(!yes||!mounted)return;
    setState((){menu=null;sourceSnapshot=null;revision=null;merge=null;});
    widget.edit((state){for(final k in _draftKeys){state.remove(k);}});
    await connect();
  }

  Future<void> quickPrice(Json product)async{
    final controller=TextEditingController(text:qrPriceInput(product['price']));
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
            TextField(key:const ValueKey('qr-price-field'),controller:controller,autofocus:true,
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
    // Not disposed here: the dialog is still animating out and uses it.
    if(result==null)return;
    try{
      final price=fromCents(parseMoney(result));
      final row=(menu?['products'] as List?)?.whereType<Map>()
        .firstWhere((p)=>p['id']==product['id']);
      if(row==null)return;
      row['price']=price;
      updated();
    }catch(_){
      if(mounted)say('Geçersiz fiyat. Örnek: 140 veya 140,50.',error:true);
    }
  }

  Json? originalProduct(Object? id){
    final rows=sourceSnapshot?['products'];
    if(rows is! List)return null;
    for(final row in rows){
      if(row is Map&&row['id']==id)return Map<String,dynamic>.from(row);
    }
    return null;
  }
  bool isProductEdited(Json p){
    final original=originalProduct(p['id']);
    return original==null||jsonEncode(original)!=jsonEncode(p);
  }
  void restoreProduct(Json p){
    final original=originalProduct(p['id']);
    final rows=menu?['products'] as List?;
    if(original==null||rows==null)return;
    final index=rows.indexWhere((x)=>x is Map&&x['id']==p['id']);
    if(index<0)return;
    rows[index]=copyJson(original);
    updated();
  }
  void updated(){
    if(!mounted)return;
    setState((){});
    _persist();
    say(changes.isEmpty?'Taslak yayındaki menüyle aynı; kaydedilecek değişiklik yok.'
      :'Taslak bu bilgisayara kaydedildi (${changes.length} değişiklik). '
        'Web menüsü yayınlanana kadar değişmez.');
  }

  Widget _changeList(List<QrChange> list)=>list.isEmpty
    ?const Center(child:Padding(padding:EdgeInsets.all(24),
      child:Text('Yayındaki menüyle aynı. Değişiklik yok.')))
    :ListView.builder(
      key:const ValueKey('qr-change-list'),
      padding:const EdgeInsets.symmetric(vertical:6),
      itemCount:list.length,
      itemBuilder:(context,i)=>ListTile(
        dense:true,
        leading:Icon(list[i].list=='products'?Icons.restaurant_menu_outlined
          :list[i].list=='categories'?Icons.folder_outlined:Icons.local_offer_outlined,
          size:20),
        title:Text(list[i].label),
        subtitle:Text(list[i].detail),
      ));

  /// Change review; with [forPublish] it is the publish confirmation.
  Future<bool> review({bool forPublish=false})async{
    if(menu==null)return false;
    final list=changes;
    final visible=[...products.where((p)=>p['active']!=false)]..sort((a,b)=>
      ((a['order'] as num?)??0).compareTo((b['order'] as num?)??0));
    final ok=await showDialog<bool>(context:context,builder:(dialog)=>Dialog(
      key:ValueKey(forPublish?'qr-publish-review':'qr-preview'),
      insetPadding:const EdgeInsets.all(18),
      child:ConstrainedBox(
        constraints:const BoxConstraints(maxWidth:760,maxHeight:640),
        child:Padding(padding:const EdgeInsets.all(20),
          child:DefaultTabController(length:2,child:Column(
            crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Text(forPublish?'GitHub’a Yayınla · ${list.length} değişiklik'
              :'Önizleme',style:Theme.of(dialog).textTheme.titleLarge),
            const SizedBox(height:4),
            Text(forPublish
              ?'Bu değişiklikler nohutfalafel/qr-menu deposuna yazılacak '
                '(sürüm ${qrRevisionLabel(revision)} üzerine). GitHub Pages ardından '
                'müşteri menüsünü günceller. Sipariş geçmişi değişmez.'
              :'Yerel taslak. Web menüsü yayınlanana kadar değişmez.'),
            const SizedBox(height:8),
            const TabBar(tabs:[Tab(text:'Değişiklikler'),Tab(text:'Müşteri Görünümü')]),
            Expanded(child:TabBarView(children:[
              _changeList(list),
              ListView(children:[
                for(final c in categories.where((c)=>c['active']!=false&&c['id']!='all'))...[
                  Padding(padding:const EdgeInsets.fromLTRB(8,12,8,4),
                    child:Text(tr(c,'name'),style:const TextStyle(fontWeight:FontWeight.w800))),
                  for(final p in visible.where((p)=>p['category']==c['id']))
                    ListTile(dense:true,
                      title:Text(qrText(p['displayName']).isNotEmpty
                        ?qrText(p['displayName']):tr(p,'name')),
                      subtitle:p['available']==false?const Text('Tükendi'):null,
                      trailing:Text(qrPrice(p['price']),
                        style:const TextStyle(fontWeight:FontWeight.w700))),
                ],
              ]),
            ])),
            const SizedBox(height:10),
            Row(mainAxisAlignment:MainAxisAlignment.end,children:[
              TextButton(onPressed:()=>Navigator.pop(dialog,false),
                child:Text(forPublish?'Vazgeç':'Kapat')),
              if(forPublish)...[
                const SizedBox(width:8),
                FilledButton.icon(key:const ValueKey('qr-confirm-publish'),
                  onPressed:()=>Navigator.pop(dialog,true),
                  icon:const Icon(Icons.cloud_upload_outlined),
                  label:const Text('GitHub’a Yayınla')),
              ],
            ]),
          ])),
        ),
      ),
    ));
    return ok==true;
  }

  /// Publish only a validated, revision-bound draft with real changes over a
  /// verified connection. The attempt is recorded first so that a lost answer
  /// is reconciled against GitHub before anything is sent again.
  Future<void> publish()async{
    if(pageState!=QrPageState.dirty||link!=QrLink.connected||revision==null)return;
    final problems=validateQrCatalog(menu!);
    if(problems.isNotEmpty){
      say('Yayından önce düzeltin: ${problems.take(3).join(' · ')}',error:true);
      return;
    }
    if(!await review(forPublish:true)||!mounted)return;
    final sent=revision!,body=copyJson(menu!),count=changes.length;
    setState(()=>publishing=true);
    _persist();
    final request=QrPublishRequest(draft:body,expectedRevision:sent);
    _setPending({'revision':sent,'at':now().toUtc().toIso8601String(),'changes':count,
      'transport':'local','draftSha256':request.draftSha256});
    var rebase=false;
    try{
      // Only a validated answer is success; a 5xx or a lost answer may have
      // written, so it stays pending until “Sonucu Doğrula”.
      final out=await LocalQrPublishTransport(publisher,endpoint).publish(request);
      if(out.wrote){
        revision=out.revision;sourceSnapshot=copyJson(body);verifiedAt=now();
        _setPending(null);
        _persist();
        final commit=out.commit??'';
        say('Yayınlandı: $count değişiklik GitHub’a yazıldı'
          '${commit.isEmpty?'':' (commit ${commit.length>7?commit.substring(0,7):commit})'}. '
          'Müşteri menüsü GitHub Pages dağıtımından sonra (genellikle 1–2 dakika) güncellenir.');
      }else if(out.status==QrPublishStatus.conflict||out.status==QrPublishStatus.refused){
        _setPending(null);
        rebase=out.status==QrPublishStatus.conflict&&(out.reason??'').contains('değişti');
        say('Yayın reddedildi, web menüsü değişmedi: ${out.reason}',error:true);
      }else{
        say('Yayın sonucu bilinmiyor: ${out.reason??''} Yeniden göndermeden önce '
          '“Sonucu Doğrula” ile GitHub’ı kontrol edin.',error:true);
      }
    }catch(e){
      say('Yayın sonucu bilinmiyor ($e). Yeniden göndermeden önce '
        '“Sonucu Doğrula” ile GitHub’ı kontrol edin.',error:true);
    }finally{if(mounted)setState(()=>publishing=false);}
    if(rebase&&mounted)await connect();
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
      (original==null?'':qrPriceInput(original['price'])),
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
        // Edit drawer: slides in from the right, the catalog stays visible.
        return Dialog(
          key:const ValueKey('qr-product-drawer'),
          alignment:Alignment.centerRight,
          insetPadding:EdgeInsets.zero,
          shape:const RoundedRectangleBorder(),
          child:SizedBox(
            width:MediaQuery.sizeOf(dialog).width<620?MediaQuery.sizeOf(dialog).width:560,
            height:MediaQuery.sizeOf(dialog).height,
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
                        const Text('Türkçe ürün adı ilk sekmede düzenlenir.'),
                        const SizedBox(height:12),
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
                        key:const ValueKey('qr-product-save'),
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
    // Controllers are left to GC: the drawer still animates out with them.
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
      'price':fromCents(parseMoney(values[9])),
      'category':values[10],
    });
    // Leave optional fields absent when the drawer only shows their defaults,
    // so opening and saving a product never reports phantom changes.
    final description={'tr':values[3],'en':values[4],'ar':values[5]};
    if(item.containsKey('description')||description.values.any((v)=>v.isNotEmpty))
      item['description']=description;
    final display={'tr':values[6],'en':values[7],'ar':values[8]};
    if(item.containsKey('displayName')||
        !(values[6]==values[0]&&values[7]==values[1]&&values[8]==values[2]))
      item['displayName']=display;
    if(item.containsKey('image')||values[11].isNotEmpty)
      item['image']=values[11].isEmpty?null:values[11];
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
        ('Fiyat ₺',original==null?'':qrPriceInput(original['price'])),
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
      say('Görsel yükleme Windows üzerinde desteklenir.',error:true);
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
      say(e.message,error:true);
    }catch(_){
      say('Resim yüklenemedi. Servis bağlantısını kontrol edin.',error:true);
    }finally{if(mounted)setState(()=>busy=false);}
  }
  void toggleRow(String list,Object? id,String key,bool value){
    final rows=menu?[list] as List?;
    if(rows==null)return;
    final row=rows.whereType<Map>().where((e)=>e['id']==id);
    if(row.isEmpty)return;
    row.first[key]=value;
    updated();
  }

  ({String label,IconData icon,Color tone}) _stateBadge(QrPageState s,ColorScheme cs)=>switch(s){
    QrPageState.notLoaded=>(label:'Yüklenmedi',icon:Icons.cloud_off_outlined,tone:cs.outline),
    QrPageState.connecting=>(label:'Bağlanıyor',icon:Icons.sync,tone:cs.primary),
    QrPageState.offlineDraft=>(label:'Çevrimdışı taslak',icon:Icons.cloud_off_outlined,tone:const Color(0xFFB4632F)),
    QrPageState.clean=>(label:'Yayındakiyle aynı',icon:Icons.verified_outlined,tone:const Color(0xFF2E7D4F)),
    QrPageState.dirty=>(label:'Yayın bekliyor',icon:Icons.edit_note_outlined,tone:const Color(0xFFB07A12)),
    QrPageState.conflict=>(label:'Çakışma var',icon:Icons.call_split,tone:cs.error),
    QrPageState.publishing=>(label:'Yayınlanıyor',icon:Icons.cloud_upload_outlined,tone:cs.primary),
    QrPageState.unknownOutcome=>(label:'Sonuç bilinmiyor',icon:Icons.help_outline,tone:cs.error),
  };

  /// Exactly one primary action for each state.
  Widget _primary(QrPageState s){
    final connected=link==QrLink.connected;
    final (String label,IconData icon,VoidCallback? go)=switch(s){
      QrPageState.notLoaded=>('Menüyü Yükle',Icons.cloud_download_outlined,()=>connect()),
      QrPageState.connecting=>('Bağlanıyor…',Icons.sync,null),
      QrPageState.offlineDraft=>('Yeniden Bağlan',Icons.link,()=>connect()),
      QrPageState.clean=>('GitHub’dan Yenile',Icons.refresh,()=>connect()),
      QrPageState.dirty=>connected
        ?('Gözden Geçir ve Yayınla',Icons.cloud_upload_outlined,()=>publish())
        :('Yeniden Bağlan',Icons.link,()=>connect()),
      QrPageState.conflict=>('Çakışmaları Çöz (${merge?.conflicts.length??0})',Icons.call_split,()=>resolveConflicts()),
      QrPageState.publishing=>('Yayınlanıyor…',Icons.cloud_upload_outlined,null),
      QrPageState.unknownOutcome=>('Sonucu Doğrula',Icons.fact_check_outlined,()=>connect()),
    };
    return FilledButton.icon(key:const ValueKey('qr-primary'),
      onPressed:busy||publishing?null:go,icon:Icon(icon,size:19),label:Text(label));
  }

  Widget _more(){
    final hasDraft=widget.state['qrPublisherDraft'] is Map||changes.isNotEmpty;
    return PopupMenuButton<String>(
      key:const ValueKey('qr-more'),
      tooltip:'Diğer işlemler',
      enabled:!busy&&!publishing,
      onSelected:(v){
        switch(v){
          case 'preview':review();
          case 'check':connect();
          case 'discard':discardDraft();
          case 'sync':widget.sync?.syncNow();say('POS menüsü QR menüden eşitleniyor.');
          case 'setup':setupHelp();
        }
      },
      itemBuilder:(_)=>[
        const PopupMenuItem(value:'check',child:Text('Bağlantıyı Test Et')),
        PopupMenuItem(value:'discard',enabled:hasDraft&&pending==null,
          child:const Text('Taslağı At ve GitHub’dan Yükle')),
        if(widget.sync!=null)const PopupMenuItem(value:'sync',child:Text('POS Menüsünü Eşitle')),
        const PopupMenuItem(value:'setup',child:Text('Yayınlama Kurulumu')),
      ],
      child:const Padding(padding:EdgeInsets.all(8),child:Icon(Icons.more_horiz)),
    );
  }

  Future<void> setupHelp()=>showDialog<void>(context:context,builder:(d)=>AlertDialog(
    key:const ValueKey('qr-setup'),
    title:const Text('QR Yayınlama Kurulumu'),
    content:SizedBox(width:560,child:Text(
      '1. Yayınlama hizmeti: Nohut QR Publisher bu bilgisayarda $endpoint '
      'adresinde çalışır (start-windows.ps1 başlatır). Personel paneli 8787 '
      'portunu kullanır; yayınlama adresi olarak 8787 girilmemelidir.\n\n'
      '2. Yönetici anahtarı: Ayarlar > Entegrasyonlar > Nohut QR Publisher '
      'bölümüne kaydedilir; yalnızca bu Windows kullanıcısı okuyabilir (DPAPI).\n\n'
      '3. GitHub App özel anahtarı (.pem) yalnızca hizmettedir; POS ve telefonlar '
      'onu görmez.\n\nŞu anki durum: $linkText.'
      '${linkHelp.isEmpty?'':'\n$linkHelp'}')),
    actions:[FilledButton(onPressed:()=>Navigator.pop(d),child:const Text('Tamam'))],
  ));

  Widget _fact(String label,String value,{Key? key,Color? tone}){
    final theme=Theme.of(context);
    return Container(
      key:key,
      constraints:const BoxConstraints(minWidth:150),
      padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
      decoration:BoxDecoration(
        color:theme.colorScheme.surfaceContainerHighest.withValues(alpha:0.45),
        borderRadius:BorderRadius.circular(10)),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[
        Text(label,style:theme.textTheme.labelSmall?.copyWith(color:theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height:2),
        Text(value,style:theme.textTheme.bodyMedium?.copyWith(
          fontWeight:FontWeight.w700,color:tone)),
      ]),
    );
  }
  String _time(DateTime? t){
    if(t==null)return '—';
    final l=t.toLocal();
    String two(int n)=>n.toString().padLeft(2,'0');
    final today=now().toLocal();
    final same=l.year==today.year&&l.month==today.month&&l.day==today.day;
    return '${same?'Bugün':'${two(l.day)}.${two(l.month)}'} ${two(l.hour)}:${two(l.minute)}';
  }

  Widget _header(QrPageState s,int changeCount){
    final theme=Theme.of(context),cs=theme.colorScheme;
    final badge=_stateBadge(s,cs);
    final linkTone=link==QrLink.connected?const Color(0xFF2E7D4F)
      :link==QrLink.unknown||link==QrLink.checking?null:cs.error;
    return Card(
      key:const ValueKey('qr-status'),
      margin:EdgeInsets.zero,
      child:Padding(padding:const EdgeInsets.fromLTRB(16,12,10,12),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,
            runSpacing:8,children:[
            Row(mainAxisSize:MainAxisSize.min,children:[
              Icon(badge.icon,color:badge.tone,size:22),
              const SizedBox(width:8),
              Text(badge.label,key:const ValueKey('qr-state'),
                style:theme.textTheme.titleMedium?.copyWith(
                  fontWeight:FontWeight.w800,color:badge.tone)),
            ]),
            Row(mainAxisSize:MainAxisSize.min,children:[
              if(menu!=null)...[
                OutlinedButton.icon(key:const ValueKey('qr-preview-button'),
                  onPressed:busy||publishing?null:review,
                  icon:const Icon(Icons.visibility_outlined,size:18),
                  label:const Text('Önizle')),
                const SizedBox(width:8),
              ],
              _primary(s),const SizedBox(width:4),_more()]),
          ]),
          if(changeCount>0&&link!=QrLink.connected&&!busy)Padding(
            padding:const EdgeInsets.only(top:6),
            child:Text(key:const ValueKey('qr-publish-blocked'),
              'Yayınlanamaz: ${diagnosis?.title??linkText}. '
              'Değişiklikler bu bilgisayarda taslak olarak korunuyor.',
              style:theme.textTheme.bodySmall?.copyWith(color:const Color(0xFFB07A12),
                fontWeight:FontWeight.w600))),
          const SizedBox(height:10),
          Wrap(spacing:8,runSpacing:8,children:[
            _fact('Yayındaki sürüm',qrRevisionLabel(revision),key:const ValueKey('qr-fact-revision')),
            _fact('Son doğrulama',_time(verifiedAt),key:const ValueKey('qr-fact-verified')),
            _fact('Taslak',changeCount==0?'Değişiklik yok':'$changeCount değişiklik',
              key:const ValueKey('qr-fact-changes'),
              tone:changeCount==0?null:const Color(0xFFB07A12)),
            _fact('Bağlantı',linkText,key:const ValueKey('qr-fact-link'),tone:linkTone),
          ]),
          if(diagnosis!=null)Padding(padding:const EdgeInsets.only(top:10),
            child:_repairCard(diagnosis!)),
          if(busy||publishing)const Padding(padding:EdgeInsets.only(top:10),
            child:LinearProgressIndicator()),
          if(info.isNotEmpty)Padding(padding:const EdgeInsets.only(top:10),
            child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Icon(infoError?Icons.error_outline:Icons.info_outline,size:18,
                color:infoError?cs.error:cs.onSurfaceVariant),
              const SizedBox(width:8),
              Expanded(child:Text(info,key:const ValueKey('qr-info'),
                style:theme.textTheme.bodySmall?.copyWith(
                  color:infoError?cs.error:cs.onSurfaceVariant))),
            ])),
        ])),
    );
  }

  /// Compact, honest publisher status: what is wrong, the one fix, and the
  /// technical details only on request.
  Widget _repairCard(PublisherDiagnosis d){
    final theme=Theme.of(context);
    const tone=Color(0xFF8A5A12);
    return Container(
      key:const ValueKey('qr-repair'),
      padding:const EdgeInsets.fromLTRB(12,10,10,6),
      decoration:BoxDecoration(color:const Color(0xFFFFF7E6),
        borderRadius:BorderRadius.circular(12),
        border:Border.all(color:const Color(0xFFEAD3A0))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Wrap(spacing:12,runSpacing:8,alignment:WrapAlignment.spaceBetween,
          crossAxisAlignment:WrapCrossAlignment.center,children:[
          ConstrainedBox(constraints:const BoxConstraints(maxWidth:720),
            child:Row(mainAxisSize:MainAxisSize.min,
              crossAxisAlignment:CrossAxisAlignment.start,children:[
              const Padding(padding:EdgeInsets.only(top:1),
                child:Icon(Icons.build_circle_outlined,color:tone,size:20)),
              const SizedBox(width:8),
              Flexible(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(d.title,key:const ValueKey('qr-repair-title'),
                  style:theme.textTheme.bodyMedium?.copyWith(
                    fontWeight:FontWeight.w800,color:tone)),
                const SizedBox(height:2),
                Text(d.help,style:theme.textTheme.bodySmall),
              ])),
            ])),
          if(d.fixLabel!=null)FilledButton.tonalIcon(
            key:const ValueKey('qr-repair-action'),
            onPressed:busy||publishing?null:repair,
            icon:Icon(switch(d.fix){
              PublisherFix.chooseKey=>Icons.key_outlined,
              PublisherFix.installNode=>Icons.open_in_new,
              PublisherFix.restart=>Icons.restart_alt,
              _=>Icons.play_arrow_rounded,
            },size:18),
            label:Text(d.fixLabel!)),
        ]),
        Align(alignment:Alignment.centerLeft,child:TextButton.icon(
          key:const ValueKey('qr-repair-details'),
          style:TextButton.styleFrom(foregroundColor:tone,
            padding:const EdgeInsets.symmetric(horizontal:4),
            visualDensity:VisualDensity.compact),
          onPressed:()=>setState(()=>showDetails=!showDetails),
          icon:Icon(showDetails?Icons.expand_less:Icons.expand_more,size:18),
          label:const Text('Teknik ayrıntılar'))),
        if(showDetails)Padding(padding:const EdgeInsets.only(bottom:6),
          child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            for(final (k,v) in d.facts)Padding(
              padding:const EdgeInsets.symmetric(vertical:1.5),
              child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
                SizedBox(width:160,child:Text(k,style:theme.textTheme.bodySmall
                  ?.copyWith(color:theme.colorScheme.onSurfaceVariant))),
                Expanded(child:SelectableText(v,style:theme.textTheme.bodySmall)),
              ])),
            if(d.logTail.isNotEmpty)Container(
              margin:const EdgeInsets.only(top:6),
              padding:const EdgeInsets.all(8),
              decoration:BoxDecoration(color:Colors.white,
                borderRadius:BorderRadius.circular(8),
                border:Border.all(color:const Color(0xFFEAD3A0))),
              child:SelectableText(d.logTail.join('\n'),
                key:const ValueKey('qr-repair-log'),
                style:const TextStyle(fontFamily:'Consolas',fontSize:11.5,height:1.35))),
          ])),
      ]),
    );
  }

  Widget _thumb(Json p){
    final cs=Theme.of(context).colorScheme;
    final image=p['image']?.toString()??'';
    final ok=widget.networkImages&&image.startsWith('assets/')&&!image.contains('..')&&
      !image.toLowerCase().endsWith('.svg');
    final fallback=Container(color:cs.surfaceContainerHighest,
      child:Icon(Icons.restaurant_menu_outlined,color:cs.onSurfaceVariant,size:20));
    final crop=qrAtlasCrop(image,translations(p['name'])['tr']??'');
    Widget photo(){
      final net=Image.network('https://nohutfalafel.github.io/qr-menu/$image',
        fit:crop==null?BoxFit.cover:BoxFit.fill,
        errorBuilder:(_,__,___)=>fallback);
      if(crop==null)return net;
      // One dish out of a shared sheet, the same region the public menu shows.
      return ColoredBox(color:const Color(0xFFF7F5EE),child:FittedBox(
        fit:BoxFit.contain,
        child:SizedBox(width:crop.crop.width,height:crop.crop.height,
          child:ClipRect(child:OverflowBox(
            alignment:Alignment.topLeft,
            minWidth:0,minHeight:0,
            maxWidth:double.infinity,maxHeight:double.infinity,
            child:Transform.translate(
              offset:Offset(-crop.crop.left,-crop.crop.top),
              child:SizedBox(width:crop.canvas.width,height:crop.canvas.height,
                child:net)))))));
    }
    // A known atlas with no region for this product: never show the sheet.
    final show=ok&&(crop!=null||!isQrAtlas(image));
    return ClipRRect(key:ValueKey('qr-thumb-${p['id']}'),
      borderRadius:BorderRadius.circular(8),
      child:SizedBox(width:42,height:42,child:show?photo():fallback));
  }

  Widget _pill(String text,Color tone,{Key? key,VoidCallback? onTap,String? tooltip}){
    final pill=Container(
      padding:const EdgeInsets.symmetric(horizontal:9,vertical:4),
      decoration:BoxDecoration(color:tone.withValues(alpha:0.13),
        borderRadius:BorderRadius.circular(20)),
      child:Text(text,style:TextStyle(fontSize:11.5,fontWeight:FontWeight.w700,color:tone)));
    final body=onTap==null?pill:InkWell(key:key,borderRadius:BorderRadius.circular(20),
      onTap:onTap,child:pill);
    return tooltip==null?body:Tooltip(message:tooltip,child:body);
  }

  /// Labels aligned with [productRow]'s wide layout.
  Widget _columnHeader(){
    final style=Theme.of(context).textTheme.labelSmall?.copyWith(
      fontWeight:FontWeight.w800,letterSpacing:.4,
      color:Theme.of(context).colorScheme.onSurfaceVariant);
    return Container(
      key:const ValueKey('qr-columns'),
      color:const Color(0xFFF4F7F3),
      padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),
      child:Row(children:[
        const SizedBox(width:54),
        Expanded(flex:5,child:Text('ÜRÜN',style:style)),
        Expanded(flex:2,child:Text('KATEGORİ',style:style)),
        SizedBox(width:112,child:Text('FİYAT',textAlign:TextAlign.right,style:style)),
        const SizedBox(width:6),
        SizedBox(width:82,child:Text('STOK',textAlign:TextAlign.center,style:style)),
        SizedBox(width:48,child:Text('QR',textAlign:TextAlign.center,style:style)),
        const SizedBox(width:32),
      ]));
  }

  Widget productRow(Json p,Map<Object?,String> categoryNames,bool wide){
    final theme=Theme.of(context),cs=theme.colorScheme;
    final id=p['id'];
    final visible=p['active']!=false,available=p['available']!=false;
    final edited=isProductEdited(p),isNew=originalProduct(id)==null;
    const green=Color(0xFF2E7D4F),orange=Color(0xFFB4632F);
    return InkWell(
      key:ValueKey('qr-row-$id'),
      onTap:canEdit?()=>productEditor(p):null,
      child:Padding(padding:const EdgeInsets.symmetric(horizontal:12,vertical:7),
        child:Row(children:[
          _thumb(p),
          const SizedBox(width:12),
          Expanded(flex:5,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(children:[
              Flexible(child:Text(tr(p,'name'),maxLines:1,overflow:TextOverflow.ellipsis,
                style:theme.textTheme.bodyLarge?.copyWith(fontWeight:FontWeight.w700))),
              if(edited)...[
                const SizedBox(width:6),
                _pill(isNew?'Yeni':'Taslak',const Color(0xFFB07A12)),
              ],
            ]),
            Text(wide?translations(p['name'])['en']!:categoryNames[p['category']]??'${p['category']}',
              maxLines:1,overflow:TextOverflow.ellipsis,
              style:theme.textTheme.bodySmall?.copyWith(color:cs.onSurfaceVariant)),
          ])),
          if(wide)Expanded(flex:2,child:Text(categoryNames[p['category']]??'${p['category']}',
            maxLines:1,overflow:TextOverflow.ellipsis,style:theme.textTheme.bodySmall)),
          SizedBox(width:wide?112:96,child:Align(alignment:Alignment.centerRight,
            child:TextButton(key:ValueKey('qr-price-$id'),
              onPressed:canEdit?()=>quickPrice(p):null,
              child:Text(qrPrice(p['price']),style:const TextStyle(fontWeight:FontWeight.w800))))),
          const SizedBox(width:6),
          SizedBox(width:wide?82:72,child:_pill(available?'Stokta':'Tükendi',available?green:orange,
            key:ValueKey('qr-stock-$id'),tooltip:available?'Tükendi yap':'Stokta yap',
            onTap:canEdit?()=>toggleRow('products',id,'available',!available):null)),
          IconButton(key:ValueKey('qr-visible-$id'),
            tooltip:visible?'QR’den Gizle':'QR’de Göster',
            onPressed:canEdit?()=>toggleRow('products',id,'active',!visible):null,
            icon:Icon(visible?Icons.visibility_outlined:Icons.visibility_off_outlined,
              color:visible?green:cs.outline,size:20)),
          PopupMenuButton<String>(
            key:ValueKey('qr-row-more-$id'),
            enabled:canEdit,
            tooltip:'Ürün işlemleri',
            onSelected:(v)async{
              switch(v){
                case 'edit':productEditor(p);
                case 'price':quickPrice(p);
                case 'image':pickImage(p);
                case 'undo':
                  final ok=await confirmAction(context,'Ürün Değişikliklerini Geri Al',
                    'Bu ürün yayındaki haline döner. Diğer değişiklikler korunur.',
                    confirm:'Geri Al');
                  if(ok&&mounted)restoreProduct(p);
              }
            },
            itemBuilder:(_)=>[
              const PopupMenuItem(value:'edit',child:Text('Düzenle')),
              const PopupMenuItem(value:'price',child:Text('Fiyatı Değiştir')),
              const PopupMenuItem(value:'image',child:Text('Görsel Yükle')),
              if(edited&&!isNew)const PopupMenuItem(value:'undo',child:Text('Değişikliği Geri Al')),
            ],
            child:const Padding(padding:EdgeInsets.all(6),child:Icon(Icons.more_vert,size:20)),
          ),
        ])),
    );
  }

  Widget _list(List<Widget> rows,{String empty='Kayıt yok.'})=>Card(
    margin:EdgeInsets.zero,
    clipBehavior:Clip.antiAlias,
    child:rows.isEmpty
      ?Padding(padding:const EdgeInsets.all(24),child:Text(empty))
      :Column(children:[
        for(var i=0;i<rows.length;i++)...[
          if(i>0)const Divider(height:1),
          rows[i],
        ],
      ]));

  @override Widget build(BuildContext context){
    final theme=Theme.of(context);
    final s=pageState,changeCount=changes.length;
    final search=query.trim().toLowerCase();
    final catOrder={for(final c in categories)c['id']:(c['order'] as num?)??0};
    final categoryNames={for(final c in categories)c['id']:tr(c,'name')};
    final filtered=products.where((p){
      final hit=search.isEmpty||
        translations(p['name']).values.any((v)=>v.toLowerCase().contains(search))||
        translations(p['displayName']).values.any((v)=>v.toLowerCase().contains(search));
      return hit&&(filterCategory=='all'||p['category']==filterCategory);
    }).toList()..sort((a,b){
      final c=(catOrder[a['category']]??0).compareTo(catOrder[b['category']]??0);
      return c!=0?c:((a['order'] as num?)??0).compareTo((b['order'] as num?)??0);
    });
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      // The page title is already in the window header; no second heading.
      _header(s,changeCount),
      const SizedBox(height:14),
      if(menu==null)
        _list(const [],empty:'Menü henüz yüklenmedi. “Menüyü Yükle” yayınlama hizmetine '
          'bağlanır; hizmet yoksa yayındaki QR menü çevrimdışı taslak olarak açılır.')
      else ...[
        Wrap(spacing:8,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
          SegmentedButton<String>(
            key:const ValueKey('qr-tabs'),
            showSelectedIcon:false,
            segments:[
              ButtonSegment(value:'Ürünler',label:Text('Ürünler · ${products.length}')),
              ButtonSegment(value:'Kategoriler',label:Text('Kategoriler · ${categories.length}')),
              ButtonSegment(value:'Kampanyalar',label:Text('Kampanyalar · ${campaigns.length}')),
            ],
            selected:{tab},
            onSelectionChanged:(v)=>setState(()=>tab=v.first)),
        ]),
        const SizedBox(height:10),
        if(tab=='Ürünler')...[
          LayoutBuilder(builder:(context,c){
            final searchBox=TextField(
              key:const ValueKey('qr-search'),
              decoration:const InputDecoration(isDense:true,
                hintText:'Ürün ara · Türkçe / English / العربية',
                prefixIcon:Icon(Icons.search),border:OutlineInputBorder()),
              onChanged:(v)=>setState(()=>query=v));
            final filter=DropdownButton<String>(
              key:const ValueKey('qr-filter'),
              value:categories.any((c)=>c['id']==filterCategory)?filterCategory:'all',
              underline:const SizedBox.shrink(),
              items:[
                if(!categories.any((c)=>c['id']=='all'))
                  const DropdownMenuItem(value:'all',child:Text('Tüm kategoriler')),
                for(final c in categories)DropdownMenuItem(value:'${c['id']}',
                  child:Text(c['id']=='all'?'Tüm kategoriler':tr(c,'name'))),
              ],
              onChanged:(v)=>setState(()=>filterCategory=v??'all'));
            final add=FilledButton.tonalIcon(key:const ValueKey('qr-new-product'),
              onPressed:canEdit?()=>productEditor():null,
              icon:const Icon(Icons.add),label:const Text('Yeni Ürün'));
            return c.maxWidth<640
              ?Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                searchBox,const SizedBox(height:8),
                Row(children:[Expanded(child:filter),add]),
              ])
              :Row(children:[Expanded(child:searchBox),const SizedBox(width:12),
                filter,const SizedBox(width:12),add]);
          }),
          const SizedBox(height:8),
          Text('${filtered.length} ürün · satıra tıklayınca düzenleme paneli açılır',
            style:theme.textTheme.bodySmall),
          const SizedBox(height:6),
          LayoutBuilder(builder:(context,c){
            final wide=c.maxWidth>=820;
            return _list([
              if(wide&&filtered.isNotEmpty)_columnHeader(),
              for(final p in filtered)productRow(p,categoryNames,wide)],
              empty:'Bu filtreyle eşleşen ürün yok.');
          }),
        ]else if(tab=='Kategoriler')...[
          Align(alignment:Alignment.centerLeft,child:FilledButton.tonalIcon(
            key:const ValueKey('qr-new-category'),
            onPressed:canEdit?()=>categoryEditor():null,
            icon:const Icon(Icons.add),label:const Text('Kategori Ekle'))),
          const SizedBox(height:8),
          _list([
            for(final c in [...categories]..sort((a,b)=>
                ((a['order'] as num?)??0).compareTo((b['order'] as num?)??0)))
              ListTile(
                key:ValueKey('qr-category-${c['id']}'),
                dense:true,
                title:Text(tr(c,'name'),style:const TextStyle(fontWeight:FontWeight.w700)),
                subtitle:Text('${c['id']} · ${translations(c['name'])['en']} · '
                  '${products.where((p)=>p['category']==c['id']).length} ürün'),
                trailing:Wrap(crossAxisAlignment:WrapCrossAlignment.center,children:[
                  Tooltip(message:'QR menüde görünür',child:Switch(
                    value:c['active']!=false,
                    onChanged:c['id']=='all'||!canEdit?null:
                      (v)=>toggleRow('categories',c['id'],'active',v))),
                  IconButton(tooltip:'Yukarı Taşı',icon:const Icon(Icons.arrow_upward,size:20),
                    onPressed:c['id']=='all'||!canEdit?null:()=>moveCategory('${c['id']}',-1)),
                  IconButton(tooltip:'Aşağı Taşı',icon:const Icon(Icons.arrow_downward,size:20),
                    onPressed:c['id']=='all'||!canEdit?null:()=>moveCategory('${c['id']}',1)),
                  IconButton(tooltip:'Düzenle',icon:const Icon(Icons.edit_outlined,size:20),
                    onPressed:canEdit?()=>categoryEditor(c):null),
                ])),
          ]),
        ]else ...[
          Align(alignment:Alignment.centerLeft,child:FilledButton.tonalIcon(
            key:const ValueKey('qr-new-campaign'),
            onPressed:canEdit?()=>campaignEditor():null,
            icon:const Icon(Icons.add),label:const Text('Kampanya Ekle'))),
          const SizedBox(height:8),
          _list([
            for(final c in campaigns)ListTile(
              key:ValueKey('qr-campaign-${c['id']}'),
              dense:true,
              title:Text(tr(c,'title'),style:const TextStyle(fontWeight:FontWeight.w700)),
              subtitle:Text('${qrPrice(c['price'])} · ${translations(c['title'])['en']}'),
              trailing:Wrap(crossAxisAlignment:WrapCrossAlignment.center,children:[
                Text(c['active']==true?'Aktif':'Pasif',style:theme.textTheme.bodySmall),
                Switch(value:c['active']==true,onChanged:!canEdit?null:
                  (v)=>toggleRow('campaigns',c['id'],'active',v)),
                IconButton(tooltip:'Kampanyayı Düzenle',icon:const Icon(Icons.edit_outlined,size:20),
                  onPressed:canEdit?()=>campaignEditor(c):null),
              ])),
          ],empty:'Kampanya yok.'),
        ],
        const SizedBox(height:10),
        Text('Düzenlemeler otomatik olarak bu bilgisayarda taslağa kaydedilir. '
          'QR’den Gizle ürünü silmez; Tükendi ürünü görünür bırakır. '
          'Eski siparişler ve fiyatları değişmez.',style:theme.textTheme.bodySmall),
      ],
    ]);
  }
}
