import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

typedef FinanceMessage = Map<String, dynamic>;

/// Finance traffic is encrypted/authenticated separately from the legacy
/// staff HTTP API. The 256-bit key is exchanged physically, never over HTTP.
class FinanceWire {
  static final _cipher = AesGcm.with256bits();
  static final _random = Random.secure();

  static String randomId([int bytes = 18]) =>
    base64UrlEncode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static String createKey() => randomId(32);

  static List<int> keyBytes(String value) {
    final raw = base64Url.decode(base64Url.normalize(value.trim()));
    if (raw.length != 32) throw const FormatException('Finans anahtarı geçersiz.');
    return raw;
  }

  static List<int> _aad(String serverId, String context) =>
    utf8.encode('nohut-finance-v1|$serverId|$context');

  static Future<FinanceMessage> seal(String key, String serverId,
      String context, FinanceMessage payload) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: SecretKey(keyBytes(key)),
      nonce: _cipher.newNonce(),
      aad: _aad(serverId, context),
    );
    return {
      'nonce': base64UrlEncode(box.nonce),
      'cipher': base64UrlEncode(box.cipherText),
      'mac': base64UrlEncode(box.mac.bytes),
    };
  }

  static Future<FinanceMessage> open(String key, String serverId,
      String context, FinanceMessage envelope) async {
    List<int> decode(String field) {
      final value = envelope[field];
      if (value is! String) throw const FormatException('Geçersiz şifreli mesaj.');
      return base64Url.decode(value);
    }
    final nonce = decode('nonce'), cipher = decode('cipher'), mac = decode('mac');
    if (nonce.length != 12 || mac.length != 16 || cipher.length > (context.startsWith('response:') ? 20 : 2) * 1024 * 1024) {
      throw const FormatException('Geçersiz şifreli mesaj.');
    }
    final bytes = await _cipher.decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(keyBytes(key)),
      aad: _aad(serverId, context),
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const FormatException('Geçersiz finans mesajı.');
    return Map<String, dynamic>.from(decoded);
  }
}
