// Codex request on #42: an unresolved card-terminal outcome must never lose
// its order through deletion; resolved outcomes keep ordinary soft deletion.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/card_terminal.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';
import 'package:nohut_falafel_desktop/pos_store.dart';
import 'package:nohut_falafel_desktop/staff_commands.dart';

class FakeTerminal implements InposGateway {
  TerminalReply payReply = const TerminalReply(TerminalStatus.unknown);
  TerminalReply inquireReply = const TerminalReply(TerminalStatus.unknown);
  int payCalls = 0;
  @override
  bool get ready => true;
  @override
  Future<TerminalReply> pay(String reference, int amountCents) async {
    payCalls++;
    return payReply;
  }
  @override
  Future<TerminalReply> inquire(String reference) async => inquireReply;
}

void main() {
  late Directory dir;
  late PosStore store;
  late FakeTerminal terminal;
  late InposPayments payments;
  late int orderId;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nohut-terminal-del');
    store = PosStore(databaseFile: '${dir.path}/db');
    store.replace({
      ...emptyPosState(),
      'localMenu': [{'id': 0, 'name': 'Falafel', 'category': 'wrap', 'price': 140}],
      'settings': {'autoPrint': false},
    }, store.read().revision);
    submitStaffOrder(store, {
      'requestId': 'staff_td_0001', 'expectedRevision': store.read().revision,
      'staffId': 2, 'source': 'Masa', 'table': 1,
      'lines': [{'productId': 0, 'qty': 1, 'removed': <String>[], 'note': ''}],
    });
    orderId = asMaps(store.read().data['orders']).single['id'] as int;
    terminal = FakeTerminal();
    payments = InposPayments(store, terminal);
  });
  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  Json delete(String id) => store.deleteOrder(orderId, store.read().revision, id, reason: 'test');

  test('unknown terminal outcome blocks deletion, even without terminalPending', () async {
    expect((await payments.pay(orderId, 14000, 'ref_unknown_1')).status, TerminalStatus.unknown);
    expect(() => delete('del_req_0001'), throwsFormatException);

    // Simulate a lost terminalPending marker (older data / other path).
    final s = store.read().data;
    mutableOrder(s, orderId)!.remove('terminalPending');
    store.replace(s, store.read().revision);
    expect(() => delete('del_req_0002'), throwsFormatException);
    expect(mutableOrder(store.read().data, orderId), isNotNull);

    // Reconciliation still finds its target; no second pay call.
    terminal.inquireReply = const TerminalReply(TerminalStatus.declined);
    expect((await payments.reconcile('ref_unknown_1')).status, TerminalStatus.declined);
    expect(terminal.payCalls, 1);

    // After a definitive decline, ordinary audited deletion works and the
    // attempt is archived with the order.
    delete('del_req_0003');
    final after = store.read().data;
    expect(mutableOrder(after, orderId), isNull);
    final archived = asMaps(after['deletedOrders']).single;
    expect(asMaps((archived['related'] as Map)['terminalAttempts']).single['status'], 'declined');
  });

  test('approved payment history is preserved through deletion', () async {
    terminal.payReply = const TerminalReply(TerminalStatus.approved, transactionId: 'tx-1', amountCents: 14000);
    expect((await payments.pay(orderId, 14000, 'ref_ok_1')).status, TerminalStatus.approved);
    delete('del_req_0004');
    final archived = asMaps(store.read().data['deletedOrders']).single;
    final order = archived['order'] as Map? ?? archived;
    expect(order.toString(), contains('tx-1'));
    expect(asMaps((archived['related'] as Map)['terminalAttempts']).single['status'], 'approved');
  });

  test('a terminal outcome for a missing order fails closed', () async {
    expect((await payments.pay(orderId, 14000, 'ref_missing_1')).status, TerminalStatus.unknown);
    // Force-remove the order behind the guard's back (old database).
    final s = store.read().data;
    (s['orders'] as List).clear();
    store.replace(s, store.read().revision);
    terminal.inquireReply = const TerminalReply(TerminalStatus.approved, transactionId: 'tx-2', amountCents: 14000);
    expect(() => payments.reconcile('ref_missing_1'), throwsFormatException);
  });
}
