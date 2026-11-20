import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as paths;

import 'pos_logic.dart';
import 'windows_vault.dart';

/// QR publishing credentials are scoped to this Windows user via DPAPI.
/// GitHub App private keys never enter the POS or its SQLite order database.
class QrPublisherClient {
  QrPublisherClient(this.databasePath, {this.testToken});
  final String databasePath;
  final String? testToken;
  File get credentialFile => File(paths.join(
    Platform.environment['APPDATA'] ?? paths.dirname(databasePath),
    'NohutFalafel','qr-publisher-credentials.dpapi',
  ));
  WindowsVault get vault => WindowsVault(credentialFile);

  static Uri checkEndpoint(String value) {
    final url=Uri.tryParse(value.trim());
    if(url==null||url.userInfo.isNotEmpty||url.hasQuery||url.hasFragment||
        (url.path.isNotEmpty&&url.path!='/')||url.host.isEmpty||
        !(url.scheme=='https'||(url.scheme=='http'&&
          (url.host=='127.0.0.1'||url.host=='localhost'))))
      throw const FormatException(
        'HTTPS adresi veya http://127.0.0.1:8787 gerekli.');
    return url;
  }

  Future<void> saveToken(String value) async {
    if(value.trim().length<32||value.trim().length>512)
      throw const FormatException('Yayınlama anahtarı en az 32 karakter olmalı.');
    await vault.save({'token':value.trim()});
  }

  Future<bool> hasToken() async =>
      testToken!=null||(await vault.load())?['token'] is String;

  Future<void> deleteToken() => vault.clear();

  Future<Map<String,dynamic>> call(
    String method, String endpoint, String path, [Json? data]
  ) async {
    final base=checkEndpoint(endpoint);
    final url=base.resolve(path.replaceFirst(RegExp(r'^/'), ''));
    if(url.host!=base.host||url.port!=base.port||url.scheme!=base.scheme)
      throw const FormatException('Yayınlama adresi geçersiz.');
    final token=testToken??(await vault.load())?['token'];
    if(token is! String||token.length<32)
      throw const FormatException('Önce yayınlama anahtarını kaydedin.');
    final client=HttpClient()..connectionTimeout=const Duration(seconds:10);
    try{
      final request=await (method=='GET'?client.getUrl(url):
          client.postUrl(url)).timeout(const Duration(seconds:15));
      request.followRedirects=false;
      request.headers.set(HttpHeaders.authorizationHeader,'Bearer $token');
      request.headers.set(HttpHeaders.acceptHeader,'application/json');
      if(data!=null){
        request.headers.contentType=ContentType.json;
        request.write(jsonEncode(data));
      }
      final response=await request.close().timeout(const Duration(seconds:45));
      if(response.statusCode>=300&&response.statusCode<400)
        throw const FormatException('Yönlendirme kabul edilmez.');
      final raw=await utf8.decoder.bind(response).join().timeout(
        const Duration(seconds:45));
      final decoded=jsonDecode(raw);
      if(decoded is! Map)throw const FormatException('Yanıt geçersiz.');
      final map=Map<String,dynamic>.from(decoded);
      if(response.statusCode>=400){
        final message=(map['error']??'').toString();
        throw FormatException(message.length<=220&&message.isNotEmpty
          ?message:'Yayınlama başarısız (HTTP '+
            response.statusCode.toString()+').');
      }
      return map;
    }on SocketException{
      throw const FormatException(
        'QR yayınlama hizmetine bağlanılamadı. Hizmet çalışıyor mu?');
    }on TimeoutException{
      throw const FormatException(
        'Yayınlama isteği zaman aşımına uğradı. Yeniden göndermeden önce GitHub kontrol edin.');
    }finally{client.close(force:true);}
  }
  Future<Map<String,dynamic>> catalog(String endpoint)=>
      call('GET',endpoint,'catalog');
  Future<Map<String,dynamic>> publish(
    String endpoint, String revision, Json menu,
  )=>call('POST',endpoint,'publish',{'revision':revision,'catalog':menu});
  Future<Map<String,dynamic>> uploadImage(
    String endpoint, String mime, List<int> bytes,
  ){
    if(bytes.isEmpty||bytes.length>6000000)
      throw const FormatException('Resim boyutu en fazla 6 MB.');
    return call('POST',endpoint,'image',
      {'mime':mime,'base64':base64Encode(bytes)});
  }
}
