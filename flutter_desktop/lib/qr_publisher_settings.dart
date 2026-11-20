import 'dart:io';
import 'package:path/path.dart' as paths;
import 'package:flutter/material.dart';
import 'operations_ui.dart';
import 'pos_logic.dart';
import 'qr_publisher_client.dart';

class QrPublisherSettingsPanel extends StatefulWidget {
  const QrPublisherSettingsPanel({super.key,
    required this.state,required this.edit,required this.databasePath});
  final Json state;
  final EditState edit;
  final String databasePath;
  @override
  State<QrPublisherSettingsPanel> createState()=>_QrPublisherSettingsPanelState();
}
class _QrPublisherSettingsPanelState extends State<QrPublisherSettingsPanel>{
  late final TextEditingController url;
  final secret=TextEditingController();
  bool busy=false,showSecret=false;
  String status='';
  late final QrPublisherClient client;
  @override
  void initState(){
    super.initState();
    client=QrPublisherClient(widget.databasePath);
    url=TextEditingController(text:
      (widget.state['settings']?['qrPublisherUrl']??'http://127.0.0.1:8787').toString());
  }
  @override
  void dispose(){url.dispose();secret.dispose();super.dispose();}
  Future<void> save()async{
    setState(()=>busy=true);
    try{
      final normalized=QrPublisherClient.checkEndpoint(url.text).toString();
      if(secret.text.trim().isNotEmpty)await client.saveToken(secret.text);
      final ok=widget.edit((db){
        final s=db.putIfAbsent('settings',()=> <String,dynamic>{}) as Map;
        s['qrPublisherUrl']=normalized;
      });
      if(!ok)throw const FormatException('Ayarlar kaydedilemedi.');
      secret.clear();
      if(mounted)setState(()=>status='Bağlantı ayarları kaydedildi. Private Key POS içine kopyalanmadı.');
    }on FormatException catch(e){
      if(mounted)setState(()=>status=e.message);
    }catch(_){
      if(mounted)setState(()=>status='Güvenli Windows kasasına kaydedilemedi.');
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> test()async{
    setState(()=>busy=true);
    try{
      final result=await client.catalog(url.text.trim());
      final products=result['catalog'] is Map
        ?(result['catalog']['products'] as List?)?.length??0:0;
      if(mounted)setState(()=>status='Bağlı · GitHub kataloğu: $products ürün. Yayınlama servisi hazır.');
    }on FormatException catch(e){
      if(mounted)setState(()=>status=e.message);
    }catch(_){
      if(mounted)setState(()=>status='Bağlantı kurulamadı. Yerel servis ve erişim anahtarını kontrol edin.');
    }finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> startLocalService() async {
    if(!Platform.isWindows) {
      setState(()=>status='Bu kurulum yalnızca Windows içindir.');
      return;
    }
    final base=paths.dirname(Platform.resolvedExecutable);
    final script=File(paths.join(base,'QRPublisher','start-windows.ps1'));
    if(!await script.exists()){
      setState(()=>status='Kurulum scripti bulunamadı. '
        'Windows Setup paketinden POS güncelleyin.');
      return;
    }
    try {
      await Process.start('powershell.exe',[
        '-NoProfile','-STA','-ExecutionPolicy','Bypass',
        '-File',script.path,
      ],mode:ProcessStartMode.detached);
      if(mounted)setState(()=>status='Yerel yayınlama servisi başlatılmaya çalışıldı. '
        'Node.js 22+ ve GitHub App .pem dosyası gerekli. '
        'Bağlantıyı Test Et ile doğrulayın.');
    }catch(_){
      if(mounted)setState(()=>status='PowerShell başlatılamadı. '
        'Başlat menüsünde Nohut QR Publisher Kurulum seçin.');
    }
  }

  @override
  Widget build(BuildContext context)=>Card(
    child:Padding(
      padding:const EdgeInsets.all(18),
      child:Column(
        crossAxisAlignment:CrossAxisAlignment.start,
        children:[
          Text('Nohut QR Publisher · GitHub',style:Theme.of(context).textTheme.titleLarge),
          const SizedBox(height:7),
          const Text('GitHub App: 5845851 · nohutfalafel/qr-menu. '
              'Windows kurulumu yerel erişim anahtarını DPAPI ile otomatik kaydeder. '
              'Mevcut GitHub App .pem dosyanız Downloads içinde bulunursa '
              'otomatik alınır; bulunmazsa Windows dosya seçim penceresi açılır. '
              'Anahtar POS içine veya GitHub koduna kopyalanmaz.'),
          const SizedBox(height:16),
          TextField(
            controller:url,
            decoration:const InputDecoration(
              labelText:'Yayınlama Servisi URL',
              helperText:'Aynı PC için http://127.0.0.1:8787',
              prefixIcon:Icon(Icons.link),
            ),
          ),
          const SizedBox(height:12),
          TextField(
            controller:secret,
            obscureText:!showSecret,
            enableSuggestions:false,
            autocorrect:false,
            decoration:InputDecoration(
              labelText:'Yayınlama Erişim Anahtarı · Bir kez kaydet',
              helperText:'Otomatik kurulumdan sonra boş bırakın. '
                'GitHub Private Key veya Client Secret buraya yazmayın.',
              prefixIcon:const Icon(Icons.key_outlined),
              suffixIcon:IconButton(
                onPressed:()=>setState(()=>showSecret=!showSecret),
                icon:Icon(showSecret?Icons.visibility_off:Icons.visibility),
              ),
            ),
          ),
          const SizedBox(height:12),
          Wrap(spacing:10,runSpacing:10,children:[
            OutlinedButton.icon(
              onPressed:busy?null:startLocalService,
              icon:const Icon(Icons.play_arrow_outlined),
              label:const Text('Yerel Yayınlama Servisini Başlat'),
            ),
            OutlinedButton.icon(
              onPressed:busy?null:() async {
                if(!Platform.isWindows)return;
                final folder=Directory(paths.join(
                  Platform.environment['APPDATA'] ?? '',
                  'NohutFalafel','QrPublisher'));
                try {
                  await folder.create(recursive:true);
                  await Process.start('explorer.exe',[folder.path],
                    mode:ProcessStartMode.detached);
                } catch (_) {
                  if(mounted)setState(()=>status=
                    'Güvenli anahtar klasörü Windows üzerinde açılamadı.');
                }
              },
              icon:const Icon(Icons.folder_open_outlined),
              label:const Text('Güvenli Anahtar Klasörünü Aç'),
            ),
            FilledButton.icon(
              onPressed:busy?null:save,
              icon:const Icon(Icons.save_outlined),
              label:const Text('Kaydet'),
            ),
            OutlinedButton.icon(
              onPressed:busy?null:test,
              icon:const Icon(Icons.network_check),
              label:const Text('Bağlantıyı Test Et'),
            ),
            OutlinedButton.icon(
              onPressed:busy?null:()async{
                await client.deleteToken();
                if(mounted)setState(()=>status='Yayınlama erişim anahtarı Windows kasasından silindi.');
              },
              icon:const Icon(Icons.link_off),
              label:const Text('Bağlantıyı Kaldır'),
            ),
          ]),
          if(busy)const LinearProgressIndicator(),
          if(status.isNotEmpty)Padding(
            padding:const EdgeInsets.only(top:10),
            child:SelectableText(status),
          ),
          const SizedBox(height:10),
          const SelectableText(
            'Güvenli klasör: %APPDATA%\\NohutFalafel\\QrPublisher\\'
            'github-app-private-key.pem',
            style:TextStyle(fontSize:12),
          ),
          const Text('Güvenlik: Erişim anahtarı Windows DPAPI kasasına kaydedilir. '
              'Sadece HTTPS veya aynı bilgisayardaki localhost HTTP kullanılır. '
              'Doğrudan GitHub token/PEM POS içinde saklanmaz.',
            style:TextStyle(fontSize:12)),
        ],
      ),
    ),
  );
}
