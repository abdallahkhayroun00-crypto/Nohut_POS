import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nohut_core/management_sections.dart';
import 'package:nohut_core/report_period.dart';

import 'expense_drafts.dart';
import 'home.dart';
import 'manager_finance.dart';
import 'owner_api.dart';
import 'pos_api.dart';
import 'style.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NohutOwnerApp());
}

class NohutOwnerApp extends StatefulWidget {
  const NohutOwnerApp({super.key});
  @override
  State<NohutOwnerApp> createState() => _NohutOwnerAppState();
}

class _NohutOwnerAppState extends State<NohutOwnerApp> with WidgetsBindingObserver {
  final api = OwnerApi();
  late final controller = PersonelController(api,StaffNotifications());
  bool ready=false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }
  Future<void> _start() async {
    try { await controller.start(); }
    catch (_) { /* Pairing screen remains available. */ }
    finally { if(mounted) setState(()=>ready=true); }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if(state==AppLifecycleState.resumed && api.paired) unawaited(controller.refresh());
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context)=>MaterialApp(
    title:'Nohut Yönetim',debugShowCheckedModeBanner:false,theme:NohutStyle.theme,
    home: !ready ? const Scaffold(body:Center(child:CircularProgressIndicator())) :
      api.paired ? OwnerHome(controller:controller,api:api,onUnpair:()=>setState((){})) :
      _OwnerPair(api:api,onPaired:() async {
        if(mounted) setState((){});
        await controller.refresh();
      }),
  );
}

class _OwnerPair extends StatefulWidget {
  const _OwnerPair({required this.api,required this.onPaired});
  final OwnerApi api;
  final Future<void> Function() onPaired;
  @override
  State<_OwnerPair> createState()=>_OwnerPairState();
}
class _OwnerPairState extends State<_OwnerPair> {
  final code=TextEditingController();
  bool busy=false,scanning=false;
  String? error;
  @override
  void dispose(){code.dispose();super.dispose();}
  Future<void> pair(String raw) async {
    if(busy)return;
    setState((){busy=true;scanning=false;error=null;});
    try {
      await widget.api.enroll(raw);
      if(mounted) await widget.onPaired();
    } catch (_) {
      if(mounted)setState(()=>error='Yönetim eşleştirmesi doğrulanamadı. Windows ve Wi-Fi bağlantısını kontrol edin.');
    } finally {
      if(mounted)setState(()=>busy=false);
    }
  }
  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Nohut Yönetim')),
    body:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:530),
      child:ListView(padding:const EdgeInsets.all(24),children:[
        const NohutBrandHeader(subtitle:'İşletme paneli'),
        const SizedBox(height:20),
        const Text(managementOwnerName,style:TextStyle(fontSize:27,fontFamily:'Bree')),
        const Text('Yalnızca yönetici cihazı. Windows > Ayarlar > Yönetim APK Eşleştir.'),
        const SizedBox(height:18),
        if(scanning) SizedBox(height:280,child:MobileScanner(onDetect:(capture){
          final raw=capture.barcodes.firstOrNull?.rawValue;
          if(raw!=null && !busy) unawaited(pair(raw));
        })),
        OutlinedButton.icon(onPressed:busy?null:()=>setState(()=>scanning=!scanning),
          icon:const Icon(Icons.qr_code_scanner),label:Text(scanning?'Kamerayı kapat':'Yönetim QR okut')),
        TextField(controller:code,obscureText:true,decoration:const InputDecoration(labelText:'Yönetim eşleştirme kodu')),
        const SizedBox(height:10),
        FilledButton(onPressed:busy?null:()=>pair(code.text),child:const Text('Güvenli Bağlan')),
        if(busy) const LinearProgressIndicator(),
        if(error!=null)Text(error!),
      ]))),
  );
}

class OwnerHome extends StatefulWidget {
  const OwnerHome({super.key,required this.controller,required this.api,required this.onUnpair});
  final PersonelController controller;
  final OwnerApi api;
  final VoidCallback onUnpair;
  @override
  State<OwnerHome> createState()=>_OwnerHomeState();
}

class _OwnerHomeState extends State<OwnerHome> {
  static const icons=<IconData>[
    Icons.dashboard_outlined,Icons.table_restaurant_outlined,Icons.delivery_dining_outlined,
    Icons.star_outline,Icons.storefront_outlined,Icons.menu_book_outlined,
    Icons.account_balance_wallet_outlined,Icons.point_of_sale_outlined,
    Icons.bar_chart_outlined,Icons.account_balance_wallet_outlined,
    Icons.trending_up_outlined,Icons.settings_outlined,
  ];
  String section='dashboard';
  String day=ReportPeriod.day(ReportPeriod.today());
  Json? data,google;
  bool loading=false,offline=true,googleBusy=false;
  String? error,googleError;
  Timer? timer;
  OwnerApi get api=>widget.api;
  ExpenseDraftStore get finance=>api.finance!;
  @override
  void initState(){
    super.initState();
    unawaited(refresh());
    timer=Timer.periodic(const Duration(seconds:30),(_){
      if(!loading && widget.controller.online)unawaited(refresh());
    });
  }
  @override
  void dispose(){timer?.cancel();super.dispose();}
  Future<void> refresh() async {
    if(loading)return;
    final selected=day;
    setState((){loading=true;error=null;});
    try {
      final cached=await api.cachedOverview(selected);
      if(!mounted)return;
      if(day==selected)setState((){data=cached??data;offline=true;});
      final fresh=await api.overview(selected);
      if(mounted && day==selected)setState((){data=fresh;offline=false;});
    } catch(_){
      if(mounted)setState((){offline=true;error='Windows bağlantısı yok. Varsa son yerel kopya gösterilir.';});
    } finally {if(mounted)setState(()=>loading=false);}
  }
  Future<void> pickDay() async {
    final d=await showDatePicker(context:context,initialDate:ReportPeriod.parse(day),
      firstDate:DateTime(2000),lastDate:ReportPeriod.today());
    if(d==null||!mounted)return;
    setState((){day=ReportPeriod.day(d);data=null;});
    await refresh();
  }
  Future<void> loadGoogle([String? token]) async {
    if(googleBusy)return;
    setState((){googleBusy=true;googleError=null;});
    try {
      final fresh=await api.request({'operation':'ownerGoogle',if(token!=null)'pageToken':token});
      if(mounted)setState(()=>google=fresh);
    } catch(_){
      if(mounted)setState(()=>googleError='Google bilgileri alınamadı. Windows bağlantısını ve Google yetkisini kontrol edin.');
    } finally{if(mounted)setState(()=>googleBusy=false);}
  }
  Future<void> reply(Json review) async {
    final c=TextEditingController();
    final value=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Google yorumuna yanıt'),
      content:TextField(controller:c,maxLines:5,maxLength:1000),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Vazgeç')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,c.text.trim()),child:const Text('Google’da Yayınla')),
      ]));
    await Future<void>.delayed(const Duration(milliseconds:250));c.dispose();
    if(!mounted||value==null||value.isEmpty)return;
    try {
      await api.request({'operation':'ownerGoogleReply','reviewId':review['reviewId'],
        'comment':value,'confirmed':true});
      await loadGoogle();
    } catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Yanıt doğrulanamadı.')));}
  }
  Widget menu(bool drawer)=>ColoredBox(color:NohutStyle.green,child:SafeArea(child:Column(children:[
    Padding(padding:const EdgeInsets.all(14),child:Row(children:[
      Image.asset('assets/nohut-logo.webp',width:42,height:42),
      const SizedBox(width:10),
      const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Nohut Falafel',style:TextStyle(color:Colors.white,fontFamily:'Bree',fontSize:19)),
        Text('İŞLETME PANELİ',style:TextStyle(color:Colors.white70,fontSize:11)),
      ])),
    ])),
    Expanded(child:ListView(children:[
      for(var i=0;i<managementSections.length;i++)
        ListTile(key:ValueKey('owner-nav-'+managementSections[i].$1),
          selected:section==managementSections[i].$1,selectedTileColor:Colors.white24,
          leading:Icon(icons[i],color:Colors.white),
          title:Text(managementSections[i].$2,style:const TextStyle(color:Colors.white,fontSize:14)),
          onTap:(){
            if(drawer)Navigator.pop(context);
            setState(()=>section=managementSections[i].$1);
            if(section=='google'||section=='reviews')unawaited(loadGoogle());
          }),
    ])),
    const Padding(padding:EdgeInsets.all(12),child:Text(managementOwnerName,style:TextStyle(color:Colors.white70))),
  ])));
  String amount(Object? v)=>v is int?money(v):'—';
  List<Json> entries(String key)=>rows(data?[key]);
  Widget title(String text)=>Padding(padding:const EdgeInsets.only(top:14,bottom:6),
    child:Text(text,style:const TextStyle(fontFamily:'Bree',fontSize:21)));
  Widget line(String label,String subtitle,[String? trailing])=>Card(child:ListTile(
    title:Text(label),subtitle:Text(subtitle),trailing:trailing==null?null:Text(trailing)));
  Widget notice(String text)=>Padding(padding:const EdgeInsets.all(8),child:Text(text));
  String orderName(Json o)=>o['source']=='Masa'?'Masa '+o['table'].toString():
    (o['source']??'').toString()+' #'+(o['dailyNumber']??o['orderNumber']??o['id']??'').toString();
  List<Widget> orderList(String key)=>[
    if(entries(key).isEmpty)notice('Kayıt yok veya henüz eşitlenmedi.'),
    for(final o in entries(key))line(orderName(o),
      (o['status']??o['serviceStatus']??'').toString()+' · '+(o['owner']??'').toString(),
      amount(o['totalCents'])),
  ];
  List<Widget> stats()=>[
    title('Personel performansı'),
    for(final p in entries('staff'))line((p['name']??'').toString(),
      'Masa: '+p['tableOrders'].toString()+' · Gel-Al: '+p['pickupOrders'].toString()+
      ' · Ek: '+p['extraBatches'].toString(),amount(p['ownedCents'])),
    title('Saatlik yoğunluk'),
    for(var h=0;h<rowsHours.length;h++)Row(children:[
      SizedBox(width:42,child:Text(h.toString().padLeft(2,'0')+':00')),
      Expanded(child:LinearProgressIndicator(value:rowsHours[h]/maxHour)),
      SizedBox(width:28,child:Text(rowsHours[h].toString(),textAlign:TextAlign.end)),
    ]),
  ];
  List<int> get rowsHours=>data?['hourly'] is List?(data!['hourly'] as List).whereType<int>().toList():[];
  int get maxHour=>rowsHours.fold<int>(1,(a,b)=>a>b?a:b);
  List<Widget> googleContent()=>[
    OutlinedButton.icon(onPressed:googleBusy?null:()=>loadGoogle(),icon:const Icon(Icons.refresh),label:const Text('Google Yenile')),
    if(googleBusy)const LinearProgressIndicator(),
    if(googleError!=null)notice(googleError!),
    if(google?['connected']==false)notice('Google İşletme Profili Windows üzerinde bağlı değil.'),
    if(google?['connected']==true)...[
      line((google?['profile'] as Map?)?['title']?.toString()??'Google İşletme Profili',
        'Ortalama: '+google!['averageRating'].toString()+' · Yorum: '+google!['totalReviewCount'].toString()),
      for(final r in rows(google?['reviews']))Card(child:ListTile(
        title:Text((r['starRating']??'').toString()),
        subtitle:Text((r['comment']??'').toString()+'\n'+
          ((r['reviewReply'] as Map?)?['comment']??'').toString()),
        trailing:TextButton(onPressed:offline?null:()=>reply(r),child:const Text('Yanıtla')))),
      if(google?['nextPageToken'] is String)
        TextButton(onPressed:googleBusy?null:()=>loadGoogle(google!['nextPageToken'] as String),child:const Text('Sonraki yorumlar')),
    ],
    notice('Google bağlantı ayarları, performans, gönderiler ve medya yönetimi Windows üzerinden yapılır.'),
  ];
  List<Widget> body(){
    switch(section){
      case 'dashboard':return [
        title('Günlük'),
        line('Toplam yerel tahsilat','Nakit + kart',data==null?'—':amount((data?['cashCents'] as int? ??0)+(data?['cardCents'] as int? ??0))),
        line('Nakit','Net tahsilat',amount(data?['cashCents'])),
        line('Kart','Net tahsilat',amount(data?['cardCents'])),
        line('Sipariş','Kayıtlı sipariş',data?['orderCount']?.toString()),
        title('Son siparişler'),...orderList('orders'),
      ];
      case 'tables':return [
        FilledButton.icon(onPressed:widget.controller.online?()=>Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>StaffHome(controller:widget.controller,onUnpair:(){},ownerMode:true))):null,
          icon:const Icon(Icons.table_restaurant),label:const Text('Masa Planı · Sipariş İşlemleri')),
        title('Kayıtlı siparişler'),...orderList('orders'),
      ];
      case 'online':return [...orderList('online'),notice('Platform API ayarları ve desteklenen sipariş durumları Windows üzerinden yönetilir.')];
      case 'reviews':return [
        title('Google yorumları'),...googleContent(),
        title('Trendyol Go · Son Windows önbelleği'),
        for(final r in entries('reviews'))line((r['rating']??r['score']??'').toString(),(r['comment']??'').toString()),
        notice('Trendyol yorum yanıtı ve Yemeksepeti partner işlemleri henüz Windows üzerinden yapılır.'),
      ];
      case 'google':return googleContent();
      case 'qr-menu':return [
        title('Windows POS menüsü'),...[
          for(final p in entries('menu'))line((p['name']??'').toString(),(p['category']??'').toString(),
            p['price'] is num?money(asCents(p['price'])):'—'),
        ],
        notice('QR menü taslağı, düzenleme ve yayınlama henüz Windows üzerinden yapılır.'),
      ];
      case 'open-accounts':return [
        for(final o in entries('openAccounts'))line(orderName(o),'Kalan ödeme',amount(o['dueCents'])),
        if(entries('openAccounts').isEmpty)notice('Açık hesap kaydı yok veya henüz eşitlenmedi.'),
        notice('Ödeme ve müşteri hesabı birleştirme Windows üzerinden yapılır.'),
      ];
      case 'payments':return [
        line('Nakit net','Seçilen gün',amount(data?['cashCents'])),
        line('Kart net','Seçilen gün',amount(data?['cardCents'])),
        notice('Tahsilat, iade, kasa hareketleri, fiş ve banka terminali Windows üzerinden yapılır.'),
      ];
      case 'reports':return [
        FilledButton.icon(onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Raporlar · PDF')),body:ManagerFinancePage(store:finance)))),
          icon:const Icon(Icons.picture_as_pdf),label:const Text('Tam Yönetim Raporu · Tek PDF')),
        ...stats(),
      ];
      case 'finance':return [
        FilledButton.icon(onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Finans')),body:ManagerFinancePage(store:finance)))),
          icon:const Icon(Icons.account_balance_wallet),label:const Text('Finans · Maaşlar · Giderler')),
        OutlinedButton.icon(onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Hızlı Günlük Gider')),body:ExpenseDraftPage(store:finance,ownerMode:true)))),
          icon:const Icon(Icons.add),label:const Text('Hızlı Günlük Gider')),
      ];
      case 'market-prices':return [
        for(final p in entries('market'))line((p['title']??'').toString(),
          (p['market']??'').toString()+' · '+(p['lastCheckedAt']??'').toString(),amount(p['priceCents'])),
        notice('Takip edilen fiyatlar Windows kaydından gelir. Yeni takip ve canlı market araması henüz Windows üzerinden yapılır.'),
      ];
      case 'settings':return [
        line(managementOwnerName,'Yetkili yönetici · Personel seçimi yok'),
        line('Windows bağlantısı',api.host??'—'),
        OutlinedButton.icon(onPressed:()=>finance.sync(force:true),icon:const Icon(Icons.sync),label:const Text('Finansı Yenile')),
        title('Personel kayıtları · Windows'),
        for(final p in entries('employees'))line((p['name']??'').toString(),(p['role']??'').toString()),
        notice('Yazıcı, terminal, API anahtarları ve personel ayarları Windows üzerinde kalır.'),
        TextButton(onPressed:()async{
          final yes=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
            title:const Text('Yönetim bağlantısı kaldırılsın mı?'),
            content:const Text('Yerel onaylı kopyalar silinir. Bekleyen finans işlemleri korunur.'),
            actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Vazgeç')),
              FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Bağlantıyı kaldır'))]));
          if(yes==true&&mounted){await api.forget();widget.onUnpair();}
        },child:const Text('Yönetim Bağlantısını Unut')),
      ];
      default:return [];
    }
  }
  @override
  Widget build(BuildContext context){
    final wide=MediaQuery.sizeOf(context).width>=900;
    return Scaffold(
      appBar:AppBar(title:Text(managementSections.firstWhere((p)=>p.$1==section).$2),
        actions:[IconButton(tooltip:'Yenile',onPressed:loading?null:()async{
          await widget.controller.refresh();await refresh();
        },icon:const Icon(Icons.refresh))]),
      drawer:wide?null:Drawer(child:menu(true)),
      body:Row(children:[
        if(wide)SizedBox(width:244,child:menu(false)),
        Expanded(child:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:1100),
          child:ListView(padding:const EdgeInsets.all(12),children:[
            Text(managementOwnerName+' · '+(offline?'Çevrimdışı kopya / bağlantı bekleniyor':'Windows bağlı')),
            if(loading)const LinearProgressIndicator(),
            if(error!=null)notice(error!),
            OutlinedButton.icon(onPressed:loading?null:pickDay,icon:const Icon(Icons.calendar_today),label:Text(day)),
            ...body(),
          ])))),
      ]),
    );
  }
}
