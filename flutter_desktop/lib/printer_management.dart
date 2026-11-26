import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'brand.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'receipt_printer.dart';

class InstalledPrinter {
  const InstalledPrinter(this.name,this.driver,this.port,this.isDefault,this.offline,this.status);
  final String name,driver,port,status;
  final bool isDefault,offline;
}

List<InstalledPrinter> parseWindowsPrinters(String value) {
  if(value.trim().isEmpty)return [];
  final decoded=jsonDecode(value);
  final rows=decoded is List?decoded:[decoded];
  final printers=<InstalledPrinter>[],seen=<String>{};
  for(final row in rows){
    if(row is! Map)continue;
    final name=(row['Name']??'').toString().trim();
    if(name.isEmpty||!seen.add(name.toLowerCase()))continue;
    printers.add(InstalledPrinter(name,(row['DriverName']??'').toString(),
      (row['PortName']??'').toString(),row['Default']==true,
      row['WorkOffline']==true,(row['PrinterStatus']??'').toString()));
  }
  printers.sort((a,b)=>a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return printers;
}

Future<List<InstalledPrinter>> enumerateWindowsPrinters() async {
  if(!Platform.isWindows)throw const FormatException('Yazıcı keşfi Windows üzerinde çalışır.');
  const command=r'$ErrorActionPreference="Stop"; Get-CimInstance Win32_Printer | Select-Object Name,DriverName,PortName,Default,WorkOffline,PrinterStatus | ConvertTo-Json -Compress -Depth 2';
  final encoded=base64Encode([for(final unit in command.codeUnits)...[unit&255,unit>>8]]);
  final process=await Process.run('powershell.exe',
    ['-NoProfile','-NonInteractive','-EncodedCommand',encoded])
    .timeout(const Duration(seconds:15),
      onTimeout:()=>throw const FormatException('Windows yazıcı listesi yanıt vermedi.'));
  if(process.exitCode!=0)throw const FormatException(
    'Windows yazıcıları okunamadı. Print Spooler hizmetini kontrol edin.');
  return parseWindowsPrinters((process.stdout??'').toString());
}

class PrinterManagementPanel extends StatefulWidget {
  const PrinterManagementPanel({super.key,required this.state,required this.edit});
  final Json state;
  final EditState edit;
  @override State<PrinterManagementPanel> createState()=>_PrinterManagementPanelState();
}
class _PrinterManagementPanelState extends State<PrinterManagementPanel>{
  List<InstalledPrinter> printers=[];
  bool busy=false;
  String message='Windows yazıcıları henüz taranmadı.';
  @override void initState(){super.initState();_refresh();}
  Future<void> _refresh()async{
    if(busy)return;
    setState(()=>busy=true);
    try{
      final result=await enumerateWindowsPrinters();
      if(mounted)setState((){
        printers=result;
        message=result.isEmpty?'Yüklü yazıcı bulunamadı. Windows üzerinden sürücüyü yükleyin.':
          result.length.toString()+' yüklü yazıcı bulundu.';
      });
    }on FormatException catch(e){
      if(mounted)setState(()=>message=e.message);
    }catch(_){
      if(mounted)setState(()=>message='Yazıcı durumu okunamadı.');
    }finally{if(mounted)setState(()=>busy=false);}
  }
  void _select(String field,String name)=>widget.edit((state){
    final cfg=state.putIfAbsent('settings',()=> <String,dynamic>{}) as Map;
    cfg[field]=name;
  });
  Future<void> _test(String printer)async{
    if(printer.trim().isEmpty){setState(()=>message='Önce yazıcı seçin.');return;}
    if(printer.toLowerCase().contains('pdf')||printer.toLowerCase().contains('xps')){
      setState(()=>message='PDF/XPS fiziksel fiş yazıcısı değildir.');return;
    }
    final confirmed=await confirmAction(context,'Test Fişi',
      'Seçilen yazıcıya test gönderilsin mi?\n'+printer,
      confirm:'Testi Yazdır');
    if(!confirmed||!mounted)return;
    setState(()=>busy=true);
    try{
      await windowsPrint('NOHUT FALAFEL · TEST FİŞİ\n'
        'Türkçe: ğ ı İ ş ç ö ü\nSOL |-------------| SAĞ\n'
        'Bu bir sipariş değildir.',
        printer,settings:widget.state['settings'] as Map?);
      if(mounted)setState(()=>message='Test kuyruğa gönderildi; gerçek çıktıyı kontrol edin.');
    }on FormatException catch(e){
      if(mounted)setState(()=>message=e.message);
    }catch(_){
      if(mounted)setState(()=>message='Test başarısız. Sürücü ve portu kontrol edin.');
    }finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context){
    final cfg=widget.state['settings'] as Map? ?? {};
    final mainPrinter=(cfg['printerName']??'').toString();
    List<DropdownMenuItem<String>> entries(String chosen)=>[
      if(chosen.isNotEmpty&&!printers.any((p)=>p.name==chosen))
        DropdownMenuItem(value:chosen,child:Text(chosen+' · bulunamadı')),
      for(final p in printers)
        DropdownMenuItem(value:p.name,
          child:Text(p.name+(p.isDefault?' · Windows varsayılanı':'')+
            (p.offline?' · Çevrimdışı':''),overflow:TextOverflow.ellipsis)),
    ];
    return Card(child:Padding(padding:const EdgeInsets.all(18),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Yazıcı Yönetimi · Windows',
          style:Theme.of(context).textTheme.titleLarge),
        const SizedBox(height:8),
        const Text('Tüm fişler (Masa, Gel-Al ve Trendyol Go sipariş fişi, '
          'hesap özeti) bu yazıcıdan çıkar. '
          'Spooler durumu kağıdın gerçekten çıktığını garanti etmez.'),
        const SizedBox(height:10),
        if(busy)const LinearProgressIndicator(),
        Text(message),
        const SizedBox(height:12),
        DropdownButtonFormField<String>(
          key:ValueKey('printer-main-'+mainPrinter+'-'+printers.length.toString()),
          initialValue:mainPrinter.isEmpty?null:mainPrinter,
          isExpanded:true,hint:const Text('Yazıcı seçin'),
          decoration:const InputDecoration(labelText:'Fiş Yazıcısı'),
          items:entries(mainPrinter),
          onChanged:busy?null:(v){if(v!=null)_select('printerName',v);},
        ),
        const SizedBox(height:10),
        for(final p in printers)
          if(p.name==mainPrinter)
            ListTile(dense:true,
              title:Text(p.name),
              subtitle:Text('Sürücü: '+p.driver+' · Port: '+p.port+
                (p.offline?' · Çevrimdışı':' · Windows listesinde')+
                ' · Kod: '+p.status),
              leading:Icon(Icons.print_outlined,
                color:p.offline?Colors.orange:NohutBrand.green)),
        Wrap(spacing:8,runSpacing:8,children:[
          OutlinedButton.icon(onPressed:busy?null:_refresh,
            icon:const Icon(Icons.refresh),label:const Text('Yazıcıları Yenile')),
          OutlinedButton.icon(
            onPressed:busy?null:()async{
              if(Platform.isWindows){
                await Process.start('explorer.exe',['ms-settings:printers']);
              }
            },
            icon:const Icon(Icons.settings_outlined),
            label:const Text('Windows Yazıcı Özellikleri')),
          FilledButton.icon(onPressed:busy?null:()=>_test(mainPrinter),
            icon:const Icon(Icons.receipt_outlined),
            label:const Text('Test Fişi')),
        ]),
        const SizedBox(height:8),
        const Text('Kağıt, ESC/POS, logo, hizalama ve yazdırma geçmişi '
          'aşağıdaki Gelişmiş Ayarlar bölümünde kalır.',
          style:TextStyle(fontSize:12)),
      ])));
  }
}
