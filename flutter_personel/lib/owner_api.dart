import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'expense_drafts.dart';
import 'pos_api.dart';

/// Owner-only native client. No staff PIN, staff bearer or employee selector.
class OwnerApi extends NohutApi {
  final _ownerStorage = const FlutterSecureStorage();
  ExpenseDraftStore? get finance => serverId == null ? null : ExpenseDraftStore.forServer(serverId!);
  /// Display name from the Windows owner profile (never hardcoded).
  String? ownerName;
  @override
  bool get paired => host != null && serverId != null && employeeId != null;
  @override
  Future<void> restore() async {
    final raw = await _ownerStorage.read(key:'owner_pairing_v1');
    if (raw == null) return;
    final data = Map<String,dynamic>.from(jsonDecode(raw) as Map);
    host = data['host'] as String;
    serverId = data['serverId'] as String;
    employeeId = data['ownerId'].toString();
    ownerName = data['ownerName'] as String?;
    finance!.host = host;
    if (!await finance!.configured()) {
      host = null; serverId = null; employeeId = null;
    }
  }
  Future<void> _persist() => _ownerStorage.write(key:'owner_pairing_v1',
    value:jsonEncode({'host':host,'serverId':serverId,'ownerId':employeeId,'ownerName':ownerName}));
  Future<void> enroll(String raw) async {
    if (paired) throw const FormatException('Önce mevcut cihaz bağlantısını kaldırın.');
    final data = Map<String,dynamic>.from(jsonDecode(raw.trim()) as Map);
    final url = NohutApi.normalizeQr(data['host'].toString());
    if (url == null || data['serverId'] is! String || data['key'] is! String) {
      throw const FormatException('Windows Yönetim QR kodu gerekli.');
    }
    host = url.toString(); serverId = data['serverId'] as String;
    final f = finance!;
    f.host = host;
    try {
      await f.configure(data['key'] as String);
      final hello = await f.managerRequest({'operation':'ownerHello'});
      if (hello['ownerId'] is! int) {
        throw const FormatException('İşletme sahibi yetkisi gerekli.');
      }
      employeeId = hello['ownerId'].toString();
      ownerName = hello['ownerName'] is String ? hello['ownerName'] as String : null;
      await _persist();
    } catch (_) {
      await f.disconnect();
      host = null; serverId = null; employeeId = null;
      rethrow;
    }
  }
  @override
  Future<void> pair(Uri url,String pin) async {
    throw const FormatException('Personel PIN değil, Yönetim QR kodu kullanın.');
  }
  @override
  Future<void> saveEmployee(int id) async {
    if (id.toString()!=employeeId) throw const FormatException('Yönetici değiştirilemez.');
  }
  Future<Json> request(Json payload) {
    final f = finance;
    if (f == null || !paired) throw const FormatException('Yönetim eşleştirmesi gerekli.');
    f.host=host;
    return f.managerRequest(payload);
  }
  /// Menü Yönetimi over the paired owner channel (owner: every edit).
  @override
  Future<(int, Json)> menu(String method, String path, {Json? body}) async {
    if (method == 'GET') {
      final r = await request({'operation': 'ownerMenu'});
      final view = r['menu'];
      if (view is! Map) throw const FormatException('Menü yanıtı geçersiz.');
      return (200, Map<String, dynamic>.from(view));
    }
    final op = switch (path) {
      'publish' => 'ownerMenuPublish',
      'reconcile' => 'ownerMenuReconcile',
      'sync' => 'ownerMenuSync',
      'image' => 'ownerMenuImage',
      _ => 'ownerMenuWrite',
    };
    final r = await request({'operation': op, 'data': {...?body}});
    if (r['ok'] == false && r['error'] == 'conflict') return (409, r);
    return (200, r);
  }
  @override
  Future<Json> bootstrap() async {
    try { return await request({'operation':'ownerBootstrap'}); }
    catch (_) {
      if (await discover()) return request({'operation':'ownerBootstrap'});
      rethrow;
    }
  }
  @override
  Future<Json> submitOrder(Json payload) =>
    request({'operation':'ownerOrder','data':payload});
  @override
  Future<Json> submitAction(Json payload) =>
    request({'operation':'ownerAction','data':payload});

  @override
  Future<bool> discover() async {
    if (!paired) return false;
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    final old = host;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4,0);
      socket.broadcastEnabled = true;
      final found = Completer<Uri>();
      sub = socket.listen((event){
        if(event != RawSocketEvent.read) return;
        final packet=socket?.receive();
        if(packet==null || !NohutApi.isLocalHost(packet.address.address)) return;
        final p=utf8.decode(packet.data,allowMalformed:true).split(':');
        if(p.length!=3 || p[0]!='NOHUT_HERE_V1' || p[1]!=serverId || found.isCompleted) return;
        final port=int.tryParse(p[2]);
        if(port==null || port<1024 || port>65535) return;
        found.complete(Uri(scheme:'http',host:packet.address.address,port:port));
      });
      socket.send(utf8.encode('NOHUT_DISCOVER_V1:' + serverId!),InternetAddress('255.255.255.255'),8788);
      host=(await found.future.timeout(const Duration(seconds:3))).toString();
      final hello=await request({'operation':'ownerHello'});
      if(hello['ownerId'].toString()!=employeeId) {
        throw const FormatException('Yönetici doğrulanamadı.');
      }
      if (hello['ownerName'] is String) ownerName = hello['ownerName'] as String;
      await _persist();
      return true;
    } catch (_) {
      host=old;
      finance?.host=old;
      return false;
    } finally {
      await sub?.cancel();
      socket?.close();
    }
  }
  Future<Json?> cachedOverview(String day) async {
    if(!paired || !await finance!.configured()) return null;
    final raw=await _ownerStorage.read(key:'owner_view_' + serverId! + '_' + day);
    return raw==null?null:Map<String,dynamic>.from(jsonDecode(raw) as Map);
  }
  Future<Json> overview(String day) async {
    final response=await request({'operation':'ownerOverview','day':day});
    final data=Map<String,dynamic>.from(response['view'] as Map);
    await _ownerStorage.write(key:'owner_view_' + serverId! + '_' + day,value:jsonEncode(data));
    return data;
  }
  @override
  Future<void> forget() async {
    final id=serverId;
    if(id!=null) {
      await finance?.disconnect();
      final all=await _ownerStorage.readAll();
      for(final k in all.keys.where((k)=>k.startsWith('owner_view_' + id + '_'))) {
        await _ownerStorage.delete(key:k);
      }
    }
    await _ownerStorage.delete(key:'owner_pairing_v1');
    host=null;serverId=null;employeeId=null;
  }
}
