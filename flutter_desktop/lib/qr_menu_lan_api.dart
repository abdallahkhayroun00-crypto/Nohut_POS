/// `/api/menu/*` for phones on the restaurant LAN (Personel and Yönetici,
/// native and browser). Always needs an individual login; every edit is
/// checked against the signed-in person's grants on the server.
library;

import 'lan_auth_gate.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'qr_menu_remote.dart';

class QrMenuLanApi {
  QrMenuLanApi(this.store, this.gate, {this.remote, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final PosStore store;
  final LanAuthGate gate;
  /// Publish / verify / photo / POS sync through Windows' own publisher.
  /// Null in tests and before the publisher is wired: phones then only edit.
  final QrMenuRemoteService? remote;
  final DateTime Function() _clock;

  Future<GateReply> handle(String method, String path, Map<String, String> query, Json body,
      {String? token}) async {
    final client = '${body['client'] ?? query['client'] ?? 'personel'}' == 'yonetici' ? 'yonetici' : 'personel';
    final d = gate.guard(token: token, client: client, operation: 'menu.view',
        touch: method == 'POST', forceRequired: true);
    if (!d.allowed) return GateReply(d.status, {'error': d.error});
    final ctx = d.context!;
    bool can(String op) => gate.auth.authorize(ctx, op) == 'ok';
    final actor = ctx.username ?? 'personel';
    final r = remote;
    void need(String op) {
      if (!can(op)) throw QrMenuForbidden(op);
    }
    try {
      switch ((method, path)) {
        case ('GET', 'view'):
          return GateReply(200, qrMenuView(store.read().data, can: can, link: await r?.linkState()));
        case ('POST', 'publish' || 'reconcile' || 'image' || 'sync') when r == null:
          return const GateReply(404, {'error': 'not_found'});
        case ('POST', 'publish'):
          need('menu.qr.publish');
          return GateReply(200, await r!.publish(expectedStamp: '${body['expectedStamp'] ?? ''}',
              actor: actor, actorId: ctx.employeeId));
        case ('POST', 'reconcile'):
          need('menu.qr.publish');
          return GateReply(200, await r!.reconcile(actor: actor, actorId: ctx.employeeId));
        case ('POST', 'image'):
          return GateReply(200, await r!.uploadImage(payload: body, can: can, actor: actor, actorId: ctx.employeeId));
        case ('POST', 'sync'):
          need('menu.product.edit');
          return GateReply(200, await r!.sync(actor: actor));
        case ('POST', 'write'):
          final payload = Map<String, dynamic>.from(body)..remove('client');
          final result = applyQrMenuCommand(store, payload, can: can,
              actor: actor, actorId: ctx.employeeId, now: _clock());
          return GateReply(200, result);
      }
      return const GateReply(404, {'error': 'not_found'});
    } on QrMenuForbidden catch (e) {
      return GateReply(403, {'error': 'forbidden', 'message': '$e'});
    } on QrMenuConflict catch (e) {
      return GateReply(409, {'error': 'conflict', 'message': e.message});
    } on FormatException catch (e) {
      return GateReply(422, {'error': 'invalid_request', 'message': e.message});
    }
  }
}
