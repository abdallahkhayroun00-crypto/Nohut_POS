import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nohut_core/management_sections.dart';
import 'package:nohut_core/report_period.dart';

import 'expense_drafts.dart';
import 'home.dart';
import 'manager_finance.dart';
import 'owner_api.dart';
import 'menu_admin_page.dart';
import 'owner_payroll.dart';
import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart' show WorkFormat;

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
    title:'Nohut Yönetim',debugShowCheckedModeBanner:false,theme:NohutStyle.theme,darkTheme:NohutStyle.darkTheme,
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
        const Text('İşletme sahibi girişi',style:TextStyle(fontSize:27,fontFamily:'Bree')),
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
  Json? data,google,payroll;
  String? payrollError;
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
      unawaited(loadPayroll());
    } catch(_){
      if(mounted)setState((){offline=true;error='Windows bağlantısı yok. Varsa son yerel kopya gösterilir.';});
    } finally {if(mounted)setState(()=>loading=false);}
  }
  /// The weekly payroll panel (§24.6) on Ana Sayfa: last week's Windows
  /// rows, read-only here; payments are recorded on the payroll page.
  Future<void> loadPayroll() async {
    try {
      final p=await api.request({'operation':'ownerPayroll'});
      if(mounted)setState((){payroll=p;payrollError=null;});
    } catch(_){
      if(mounted)setState(()=>payrollError='Maaş durumu alınamadı.');
    }
  }
  void openPayroll()=>Navigator.of(context).push(MaterialPageRoute<void>(
    builder:(_)=>OwnerPayrollPage(request:api.request))).then((_)=>loadPayroll());
  Widget payrollPanel(){
    final nc=context.nohut;
    final people=rows(payroll?['rows']).where((r)=>r['financialStatus']!='Çalışma kaydı yok').toList();
    final open=people.where((r)=>r['financialStatus']!='Ödendi').toList();
    final overdue=open.where((r)=>r['overdue']==true).length;
    final missing=people.where((r)=>r['rate']==null).length;
    final known=open.every((r)=>r['remainingCents'] is int);
    final left=open.fold<int>(0,(n,r)=>n+((r['remainingCents'] as int?)??0));
    final week=payroll?['weekStart'];
    return Card(key:const ValueKey('dash-payroll'),child:InkWell(onTap:openPayroll,borderRadius:BorderRadius.circular(18),child:Padding(
      padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[
          Icon(Icons.payments_outlined,color:nc.heading),const SizedBox(width:8),
          Expanded(child:Text(week is String?'Hafta ${WorkFormat.day(week)}':'Haftalık Maaş Ödemeleri',
            style:const TextStyle(fontWeight:FontWeight.w700,fontSize:15.5))),
          const Icon(Icons.chevron_right),
        ]),
        const SizedBox(height:8),
        if(payroll==null)Text(payrollError??'Yükleniyor…',style:TextStyle(color:nc.muted))
        else if(people.isEmpty)Text('Bu hafta için çalışma kaydı yok.',style:TextStyle(color:nc.muted))
        else Wrap(spacing:8,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
          Text(open.isEmpty?'Tüm ödemeler kaydedildi':known?'Kalan ${money(left)}':'Kalan: ücreti eksik kişiler var',
            style:TextStyle(fontWeight:FontWeight.w800,fontSize:18,color:nc.heading)),
          if(open.isNotEmpty)NohutPill('${open.length} kişi bekliyor',tone:NohutTone.warning),
          if(overdue>0)NohutPill('$overdue gecikti',tone:NohutTone.danger),
          if(missing>0)NohutPill('$missing ücret belirlenmedi',tone:NohutTone.neutral),
        ]),
      ]))));
  }
  Widget teamPanel(){
    final nc=context.nohut;
    final team=data?['team'] is Map?data!['team'] as Map:const {};
    final planned=rows(team['planned']);
    final worked=rows(team['worked']);
    return Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(data==null?'—':'Planlı ${planned.length} kişi · Çalışılan ${WorkFormat.hours(team['actualMinutes'])}',
        style:const TextStyle(fontWeight:FontWeight.w700,fontSize:15.5)),
      const SizedBox(height:6),
      if(data!=null&&planned.isEmpty)Text('Bu gün için planlı vardiya yok.',style:TextStyle(color:nc.muted)),
      for(final p in planned)Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Row(children:[
        Icon(Icons.schedule,size:17,color:nc.muted),const SizedBox(width:8),
        Expanded(child:Text('${p['employeeName']??''}',overflow:TextOverflow.ellipsis)),
        Text('${p['start']}–${p['end']}${p['endsNextDay']==true?' (+1)':''}',style:const TextStyle(fontWeight:FontWeight.w600)),
      ])),
      if(worked.isNotEmpty)...[
        const Divider(height:18),
        for(final w in worked)Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Row(children:[
          Icon(Icons.timer_outlined,size:17,color:nc.muted),const SizedBox(width:8),
          Expanded(child:Text('${w['name']??''}',overflow:TextOverflow.ellipsis)),
          Text(WorkFormat.hours(w['minutes']),style:const TextStyle(fontWeight:FontWeight.w600)),
        ])),
      ],
      const SizedBox(height:4),
      Text('Çalışılan saat personelin kendi Mesai kayıtlarından gelir.',style:TextStyle(color:nc.muted,fontSize:12.5)),
    ])));
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
  static const _groups=<(String,List<String>)>[
    ('Operasyon',['dashboard','tables','online','open-accounts','payments']),
    ('Müşteri',['reviews','google','qr-menu']),
    ('Yönetim',['staff','reports','finance','market-prices','settings']),
  ];
  /// §24.3 bottom bar on phones: Ana Sayfa / Satışlar / Finans / Personel /
  /// Daha Fazla (the full section list in the drawer).
  static const _bar=<(String,String,IconData)>[
    ('dashboard','Ana Sayfa',Icons.home_outlined),
    ('tables','Satışlar',Icons.point_of_sale_outlined),
    ('finance','Finans',Icons.account_balance_wallet_outlined),
    ('staff','Personel',Icons.badge_outlined),
  ];
  final scaffoldKey=GlobalKey<ScaffoldState>();
  String sectionLabel(String id)=>switch(id){
    'dashboard'=>'Ana Sayfa','staff'=>'Personel',
    _=>managementSections.where((p)=>p.$1==id).map((p)=>p.$2).firstOrNull??id};
  void go(String id){
    setState(()=>section=id);
    if(id=='google'||id=='reviews')unawaited(loadGoogle());
    if(id=='staff'&&payroll==null)unawaited(loadPayroll());
  }
  Widget menu(bool drawer){
    final nc=context.nohut,scheme=Theme.of(context).colorScheme;
    Widget item(String id,String label,IconData icon){
      final selected=section==id;
      return Padding(padding:const EdgeInsets.symmetric(horizontal:10,vertical:1),child:ListTile(
        key:ValueKey('owner-nav-'+id),dense:true,selected:selected,
        selectedTileColor:scheme.secondaryContainer,selectedColor:scheme.onSecondaryContainer,
        shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)),
        leading:Icon(icon,color:selected?scheme.onSecondaryContainer:nc.muted),
        title:Text(label,style:TextStyle(fontSize:14.5,
          fontWeight:selected?FontWeight.w700:FontWeight.w500,color:selected?scheme.onSecondaryContainer:nc.ink)),
        onTap:(){
          if(drawer)Navigator.pop(context);
          go(id);
        }));
    }
    // Material, not ColoredBox: the selected tile and ink must paint on it.
    return Material(color:nc.card,child:SafeArea(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Container(margin:const EdgeInsets.all(12),padding:const EdgeInsets.all(14),
        decoration:BoxDecoration(color:nc.brandPanel,borderRadius:BorderRadius.circular(20)),
        child:Row(children:[
          Container(decoration:BoxDecoration(shape:BoxShape.circle,border:Border.all(color:NohutStyle.gold,width:1.5)),
            child:ClipOval(child:Image.asset('assets/nohut-logo.webp',width:44,height:44))),
          const SizedBox(width:12),
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('Nohut Falafel',style:TextStyle(color:Colors.white,fontFamily:'Bree',fontSize:19)),
            Text(api.ownerName??'İşletme sahibi',maxLines:1,overflow:TextOverflow.ellipsis,
              style:const TextStyle(color:Color(0xffe2c47e),fontSize:13,fontWeight:FontWeight.w600)),
          ])),
        ])),
      Expanded(child:ListView(padding:const EdgeInsets.only(bottom:12),children:[
        for(final (label,ids) in _groups)...[
          Padding(padding:const EdgeInsets.fromLTRB(24,14,24,6),child:Text(label.toUpperCase(),
            style:TextStyle(fontSize:11.5,letterSpacing:1.1,fontWeight:FontWeight.w700,color:nc.muted))),
          for(final id in ids)
            if(id=='staff')item('staff','Personel',Icons.badge_outlined)
            else if(managementSections.indexWhere((x)=>x.$1==id)>=0)
              item(id,sectionLabel(id),icons[managementSections.indexWhere((x)=>x.$1==id)]),
        ],
      ])),
      Padding(padding:const EdgeInsets.fromLTRB(16,4,16,14),child:Row(children:[
        Icon(offline?Icons.cloud_off_outlined:Icons.lan_outlined,size:16,color:offline?nc.warning:nc.success),
        const SizedBox(width:6),
        Expanded(child:Text(offline?'Çevrimdışı kopya':'Windows bağlı',style:TextStyle(color:nc.muted,fontSize:13))),
      ])),
    ])));
  }
  String amount(Object? v)=>v is int?money(v):'—';
  List<Json> entries(String key)=>rows(data?[key]);
  Widget title(String text)=>NohutSection(text);
  Widget line(String label,String subtitle,[String? trailing])=>Card(child:ListTile(
    title:Text(label,style:const TextStyle(fontWeight:FontWeight.w600)),subtitle:Text(subtitle),
    trailing:trailing==null?null:Text(trailing,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:15))));
  Widget notice(String text)=>Padding(padding:const EdgeInsets.symmetric(vertical:10,horizontal:4),child:Row(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      Icon(Icons.info_outline,size:17,color:context.nohut.muted),const SizedBox(width:8),
      Expanded(child:Text(text,style:TextStyle(color:context.nohut.muted,fontSize:13.5))),
    ]));
  IconData sourceIcon(Json o)=>switch('${o['source']}'){
    'Masa'=>Icons.table_restaurant_outlined,'Gel-Al'=>Icons.takeout_dining_outlined,_=>Icons.delivery_dining_outlined};
  Widget orderTile(Json o)=>Card(child:ListTile(
    leading:CircleAvatar(backgroundColor:Theme.of(context).colorScheme.secondaryContainer,
      foregroundColor:Theme.of(context).colorScheme.onSecondaryContainer,child:Icon(sourceIcon(o),size:20)),
    title:Text(orderName(o),style:const TextStyle(fontWeight:FontWeight.w700)),
    subtitle:Text([if('${o['status']??o['serviceStatus']??''}'.isNotEmpty)'${o['status']??o['serviceStatus']}',
      if('${o['owner']??''}'.isNotEmpty)'${o['owner']}'].join(' · ')),
    trailing:Text(amount(o['totalCents']),style:const TextStyle(fontWeight:FontWeight.w700,fontSize:15))));
  String orderName(Json o)=>o['source']=='Masa'?'Masa '+o['table'].toString():
    (o['source']??'').toString()+' #'+(o['dailyNumber']??o['orderNumber']??o['id']??'').toString();
  List<Widget> orderList(String key)=>[
    if(entries(key).isEmpty)const Card(child:NohutEmpty(icon:Icons.receipt_long_outlined,message:'Kayıt yok veya henüz eşitlenmedi.')),
    for(final o in entries(key))orderTile(o),
  ];
  List<Widget> stats()=>[
    title('Personel performansı'),
    for(final p in entries('staff'))line((p['name']??'').toString(),
      'Masa: '+p['tableOrders'].toString()+' · Gel-Al: '+p['pickupOrders'].toString()+
      ' · Ek: '+p['extraBatches'].toString(),amount(p['ownedCents'])),
    title('Saatlik yoğunluk'),
    hourly(),
  ];
  List<int> get rowsHours=>data?['hourly'] is List?(data!['hourly'] as List).whereType<int>().toList():[];
  int get maxHour=>rowsHours.fold<int>(1,(a,b)=>a>b?a:b);
  static const _months=['Oca','Şub','Mar','Nis','May','Haz','Tem','Ağu','Eyl','Eki','Kas','Ara'];
  String dayLabel(String d){final x=ReportPeriod.parse(d);return '${x.day} ${_months[x.month-1]} ${x.year}';}
  /// Orders per hour from the Windows record; an empty day says so instead
  /// of drawing a flat chart.
  Widget hourly(){
    final h=rowsHours;
    if(h.isEmpty||h.every((v)=>v==0)){
      return const Card(child:NohutEmpty(icon:Icons.bar_chart_outlined,message:'Bu gün için saatlik sipariş kaydı yok.'));
    }
    final first=h.indexWhere((v)=>v>0),last=h.lastIndexWhere((v)=>v>0);
    final from=(first-1).clamp(0,23),to=(last+1).clamp(0,23);
    final peak=h.indexOf(maxHour);
    final nc=context.nohut,scheme=Theme.of(context).colorScheme;
    return Card(child:Padding(padding:const EdgeInsets.fromLTRB(14,14,14,10),child:Column(
      crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('En yoğun saat ${peak.toString().padLeft(2,'0')}:00 · $maxHour sipariş',
          style:TextStyle(color:nc.muted,fontSize:13,fontWeight:FontWeight.w600)),
        const SizedBox(height:12),
        SizedBox(height:120,child:Row(crossAxisAlignment:CrossAxisAlignment.end,children:[
          for(var i=from;i<=to;i++)Expanded(child:Padding(padding:const EdgeInsets.symmetric(horizontal:2),
            child:Column(mainAxisAlignment:MainAxisAlignment.end,children:[
              Flexible(child:FractionallySizedBox(heightFactor:h[i]==0?0.02:h[i]/maxHour,child:Container(
                decoration:BoxDecoration(color:i==peak?scheme.secondary:scheme.primary.withValues(alpha:.75),
                  borderRadius:const BorderRadius.vertical(top:Radius.circular(6)))))),
              const SizedBox(height:4),
              Text(i.toString().padLeft(2,'0'),style:TextStyle(fontSize:10.5,color:nc.muted)),
            ]))),
        ])),
      ])));
  }
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
      case 'dashboard':
        final cash=data?['cashCents'],card=data?['cardCents'];
        return [
        NohutMetric(label:'Toplam yerel tahsilat',emphasis:true,icon:Icons.account_balance_wallet_outlined,
          value:cash is int&&card is int?money(cash+card):'—',caption:'Nakit + kart · Windows POS kaydı'),
        const SizedBox(height:10),
        NohutMetricGrid(minTileWidth:150,children:[
          NohutMetric(label:'Nakit',value:amount(cash),icon:Icons.payments_outlined),
          NohutMetric(label:'Kart',value:amount(card),icon:Icons.credit_card),
          NohutMetric(label:'Sipariş',value:data?['orderCount']?.toString()??'—',icon:Icons.receipt_long_outlined),
          NohutMetric(label:'Açık hesap',value:data==null?'—':'${entries('openAccounts').length}',icon:Icons.pending_actions_outlined),
          NohutMetric(label:'Aktif masa',value:data?['activeTables'] is int?'${data!['activeTables']} / 5':'—',icon:Icons.table_restaurant_outlined),
        ]),
        title('Haftalık Maaş Ödemeleri'),
        payrollPanel(),
        title(day==ReportPeriod.day(ReportPeriod.today())?'Bugün ekip':'Ekip · ${dayLabel(day)}'),
        teamPanel(),
        title('Saatlik yoğunluk'),
        hourly(),
        NohutSection('Son siparişler',action:TextButton(onPressed:()=>setState(()=>section='tables'),child:const Text('Tümü'))),
        ...orderList('orders').take(6),
      ];
      case 'tables':return [
        FilledButton.icon(onPressed:widget.controller.online?()=>Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>StaffHome(controller:widget.controller,onUnpair:(){},ownerMode:true,ownerName:api.ownerName))):null,
          icon:const Icon(Icons.table_restaurant),label:const Text('Masa Planı · Sipariş İşlemleri')),
        title('Kayıtlı siparişler'),...orderList('orders'),
      ];
      case 'staff':return [
        FilledButton.icon(key:const ValueKey('staff-payroll'),onPressed:openPayroll,
          icon:const Icon(Icons.payments_outlined),label:const Text('Haftalık Maaş Ödemeleri')),
        title('Maaş durumu'),
        payrollPanel(),
        title(day==ReportPeriod.day(ReportPeriod.today())?'Bugün ekip':'Ekip · ${dayLabel(day)}'),
        teamPanel(),
        title('Personel Listesi'),
        for(final p in entries('employees').where((p)=>p['active']!=false))
          line((p['name']??'').toString(),(p['role']??'').toString()),
        if(data!=null&&entries('employees').isEmpty)notice('Personel kaydı yok veya henüz eşitlenmedi.'),
        notice('Saatlik ücretler ve ekip programı şimdilik yerel Yönetici sayfasında; kullanıcılar, yetkiler ve cihazlar Windows POS’ta yönetilir.'),
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
        Card(child:ListTile(
          key:const ValueKey('open-menu-admin'),
          leading:const Icon(Icons.restaurant_menu_outlined),
          title:const Text('Menü Yönetimi',style:TextStyle(fontWeight:FontWeight.w700)),
          subtitle:const Text('Ürünler, fiyatlar, stok, QR görünürlüğü, kategoriler ve kampanyalar · '
            'Windows’taki taslağa kaydedilir'),
          trailing:const Icon(Icons.chevron_right),
          onTap:offline?null:()=>Navigator.of(context).push(menuAdminRoute(api)))),
        notice('Yayınlama Windows’taki QR Menü Yönetimi’nden, işletme sahibi onayıyla yapılır. '
          'Uzaktan (bulut) menü düzenleme henüz hazır değil.'),
        title('Windows POS menüsü'),...[
          for(final p in entries('menu'))line((p['name']??'').toString(),(p['category']??'').toString(),
            p['price'] is num?money(asCents(p['price'])):'—'),
        ],
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
        FilledButton.icon(key:const ValueKey('owner-payroll'),onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>OwnerPayrollPage(request:api.request))),
          icon:const Icon(Icons.payments_outlined),label:const Text('Haftalık Maaş Ödemeleri')),
        const SizedBox(height:8),
        OutlinedButton.icon(onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Finans')),body:ManagerFinancePage(store:finance)))),
          icon:const Icon(Icons.account_balance_wallet),label:const Text('Finans · Giderler · Aylık Rapor')),
        OutlinedButton.icon(onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Hızlı Günlük Gider')),body:ExpenseDraftPage(store:finance,ownerMode:true)))),
          icon:const Icon(Icons.add),label:const Text('Hızlı Günlük Gider')),
      ];
      case 'market-prices':return [
        for(final p in entries('market'))line((p['title']??'').toString(),
          (p['market']??'').toString()+' · '+(p['lastCheckedAt']??'').toString(),amount(p['priceCents'])),
        notice('Takip edilen fiyatlar Windows kaydından gelir. Yeni takip ve canlı market araması henüz Windows üzerinden yapılır.'),
      ];
      case 'settings':
        final nc=context.nohut;
        Widget tile(IconData icon,String title,String subtitle,{Widget? trailing})=>ListTile(
          leading:Icon(icon,color:nc.muted),title:Text(title,style:const TextStyle(fontWeight:FontWeight.w600)),
          subtitle:Text(subtitle),trailing:trailing);
        return [
        // Q2 Ayarlar: only settings that really live on this phone, grouped;
        // what Windows owns is listed as such, never as a dead switch.
        title('Hesap'),
        Card(child:Column(children:[
          tile(Icons.verified_user_outlined,api.ownerName??'İşletme sahibi','Yetkili yönetici · kimlik Windows eşleştirmesinden gelir'),
        ])),
        title('Bağlantı'),
        Card(child:Column(children:[
          tile(offline?Icons.cloud_off_outlined:Icons.lan_outlined,offline?'Çevrimdışı kopya':'Windows bağlı',api.host??'—',
            trailing:NohutPill(offline?'Bağlantı yok':'Bağlı',tone:offline?NohutTone.warning:NohutTone.success)),
          const Divider(height:1),
          ListTile(key:const ValueKey('settings-finance-sync'),leading:Icon(Icons.sync,color:nc.muted),
            title:const Text('Finansı Yenile'),
            subtitle:Text(finance.lastSync==null?'Henüz eşitlenmedi':'Son eşitleme ${TimeOfDay.fromDateTime(finance.lastSync!).format(context)}'),
            onTap:()async{await finance.sync(force:true);if(mounted)setState((){});}),
        ])),
        title('Görünüm'),
        Card(child:tile(Icons.brightness_6_outlined,'Tema','Telefonun açık veya koyu ayarını izler')),
        title('Windows’ta yönetilenler'),
        Card(child:Column(children:[
          tile(Icons.print_outlined,'Yazıcı & Fiş','Her bilgisayarın kendi ayarı'),
          tile(Icons.key_outlined,'Entegrasyonlar ve API anahtarları','Maskeli, hiçbir zaman telefona gönderilmez'),
          tile(Icons.manage_accounts_outlined,'Kullanıcılar, yetkiler ve cihazlar','Kullanıcılar & Güvenlik'),
          tile(Icons.backup_outlined,'Yedekleme ve Bulut & Senkronizasyon','Yalnızca Windows POS'),
        ])),
        title('Personel kayıtları · Windows'),
        for(final p in entries('employees'))line((p['name']??'').toString(),(p['role']??'').toString()),
        title('Bu cihaz'),
        Card(child:ListTile(key:const ValueKey('settings-forget'),
          leading:Icon(Icons.phonelink_erase_outlined,color:nc.danger),
          title:Text('Yönetim Bağlantısını Unut',style:TextStyle(color:nc.danger,fontWeight:FontWeight.w600)),
          subtitle:const Text('Yerel onaylı kopyalar silinir. Bekleyen finans işlemleri korunur.'),
          onTap:()async{
          final yes=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
            title:const Text('Yönetim bağlantısı kaldırılsın mı?'),
            content:const Text('Yerel onaylı kopyalar silinir. Bekleyen finans işlemleri korunur.'),
            actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Vazgeç')),
              FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Bağlantıyı kaldır'))]));
          if(yes==true&&mounted){await api.forget();widget.onUnpair();}
        })),
      ];
      default:return [];
    }
  }
  @override
  Widget build(BuildContext context){
    final wide=MediaQuery.sizeOf(context).width>=900;
    final barIndex=_bar.indexWhere((b)=>b.$1==section);
    return Scaffold(
      key:scaffoldKey,
      appBar:AppBar(title:Text(sectionLabel(section)),
        actionsPadding:const EdgeInsets.only(right:6),
        actions:[IconButton(tooltip:'Yenile',onPressed:loading?null:()async{
          await widget.controller.refresh();await refresh();
        },icon:const Icon(Icons.refresh))]),
      drawer:wide?null:Drawer(child:menu(true)),
      body:Row(children:[
        if(wide)SizedBox(width:244,child:menu(false)),
        Expanded(child:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:1100),
          child:ListView(padding:const EdgeInsets.fromLTRB(16,8,16,24),children:[
            if(section!='settings')Wrap(spacing:8,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
              ActionChip(avatar:const Icon(Icons.calendar_today,size:17),onPressed:loading?null:pickDay,
                label:Text(day==ReportPeriod.day(ReportPeriod.today())?'Bugün':dayLabel(day))),
              NohutPill(offline?'Çevrimdışı kopya':'Windows bağlı',
                tone:offline?NohutTone.warning:NohutTone.success,icon:offline?Icons.cloud_off_outlined:Icons.lan_outlined),
            ]),
            const SizedBox(height:8),
            if(loading)const Padding(padding:EdgeInsets.only(bottom:8),child:LinearProgressIndicator()),
            if(error!=null)notice(error!),
            ...body(),
          ])))),
      ]),
      bottomNavigationBar:wide?null:MediaQuery.withClampedTextScaling(maxScaleFactor:1.15,child:NavigationBar(
        selectedIndex:barIndex<0?_bar.length:barIndex,
        onDestinationSelected:(i){
          if(i==_bar.length){scaffoldKey.currentState?.openDrawer();return;}
          go(_bar[i].$1);
        },
        destinations:[
          for(final (_,label,icon) in _bar)NavigationDestination(icon:Icon(icon),label:label),
          const NavigationDestination(icon:Icon(Icons.more_horiz),label:'Daha Fazla'),
        ])),
    );
  }
}
