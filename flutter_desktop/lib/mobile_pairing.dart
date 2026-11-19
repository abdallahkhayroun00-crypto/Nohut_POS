import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'pos_logic.dart';
import 'pos_store.dart';

/// LAN-only pairing for native Android staff clients. Raw bearer tokens are
/// returned once to the device and never persisted by the restaurant.
class MobilePairing extends ChangeNotifier {
  MobilePairing(this.store) {
    _ensureIdentity();
    rotatePin();
  }

  final PosStore store;
  final Random _random = Random.secure();
  final Map<String, List<DateTime>> _attempts = {};
  late String serverId;
  late String pin;
  late DateTime pinExpires;
  bool _closed = false;

  static String hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  String _secret(int bytes) {
    final raw = List<int>.generate(bytes, (_) => _random.nextInt(256));
    return base64UrlEncode(raw).replaceAll('=', '');
  }

  void _ensureIdentity() {
    for (var retry = 0; retry < 5; retry++) {
      final snapshot = store.read();
      final existing = '${snapshot.data['mobileServerId'] ?? ''}';
      if (existing.length >= 16) {
        serverId = existing;
        return;
      }
      final candidate = _secret(16);
      final next = copyJson(snapshot.data);
      next['mobileServerId'] = candidate;
      next.putIfAbsent('mobileDevices', () => <dynamic>[]);
      if (store.replace(next, snapshot.revision).ok) {
        serverId = candidate;
        return;
      }
    }
    throw StateError('Mobile LAN identity could not be saved');
  }

  void rotatePin() {
    pin = (_random.nextInt(900000) + 100000).toString();
    pinExpires = DateTime.now().add(const Duration(minutes: 15));
    if (!_closed) notifyListeners();
  }

  List<Json> get devices => asMaps(store.read().data['mobileDevices'])
      .map((d) => {
        'id': d['id'],
        'name': d['name'],
        'createdAt': d['createdAt'],
        'revoked': d['revoked'] == true,
      }).toList();

  bool _safeEqual(String a, String b) {
    if (a.length != b.length) return false;
    var value = 0;
    for (var i = 0; i < a.length; i++) {
      value |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return value == 0;
  }

  bool authorized(String? bearer) {
    if (bearer == null || !bearer.startsWith('Bearer ')) return false;
    final token = bearer.substring(7);
    if (token.length < 32 || token.length > 256) return false;
    final fingerprint = hash(token);
    return asMaps(store.read().data['mobileDevices']).any(
      (d) => d['revoked'] != true &&
          d['hash'] is String &&
          _safeEqual('${d['hash']}', fingerprint),
    );
  }

  Json pair(String clientIp, Json body) {
    final now = DateTime.now();
    final attempts = _attempts.putIfAbsent(clientIp, () => []);
    attempts.removeWhere((t) => now.difference(t) > const Duration(minutes: 5));
    if (attempts.length >= 5) {
      throw const FormatException('Çok fazla deneme. Beş dakika bekleyin.');
    }
    attempts.add(now);
    final entered = '${body['pin'] ?? ''}';
    if (now.isAfter(pinExpires) || !_safeEqual(entered, pin)) {
      throw const FormatException('Eşleştirme kodu yanlış veya süresi doldu.');
    }
    final name = '${body['deviceName'] ?? 'Android Personel'}'.trim();
    if (name.isEmpty || name.length > 48) {
      throw const FormatException('Geçerli cihaz adı gerekli.');
    }
    final token = _secret(32);
    final deviceId = _secret(12);
    for (var retry = 0; retry < 5; retry++) {
      final snapshot = store.read();
      final next = copyJson(snapshot.data);
      final devices = asMaps(next['mobileDevices']);
      devices.add({
        'id': deviceId,
        'name': name,
        'hash': hash(token),
        'createdAt': now.toUtc().toIso8601String(),
        'revoked': false,
      });
      next['mobileDevices'] = devices;
      if (store.replace(next, snapshot.revision).ok) {
        // PIN is single-use; a further client needs a fresh PIN from the PC.
        rotatePin();
        return {'ok': true, 'serverId': serverId, 'token': token,
            'deviceId': deviceId};
      }
    }
    throw const FormatException('Eşleştirme kaydedilemedi.');
  }

  bool revoke(String deviceId) {
    for (var retry = 0; retry < 5; retry++) {
      final snapshot = store.read();
      final next = copyJson(snapshot.data);
      final devices = asMaps(next['mobileDevices']);
      final match = devices.where((d) => d['id'] == deviceId).firstOrNull;
      if (match == null) return false;
      match['revoked'] = true;
      next['mobileDevices'] = devices;
      if (store.replace(next, snapshot.revision).ok) {
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
