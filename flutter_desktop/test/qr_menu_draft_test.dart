import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/qr_menu_draft.dart';

Map<String, dynamic> cat({List<Map<String, dynamic>>? products}) => {
      'categories': [
        {'id': 'c1', 'name': {'tr': 'Dürüm', 'en': 'Wrap'}, 'order': 1, 'active': true},
      ],
      'products': products ??
          [
            {'id': 'p1', 'legacyKey': 'falafel', 'name': {'tr': 'Falafel Dürüm'}, 'category': 'c1', 'price': 140, 'available': true, 'active': true},
            {'id': 'p2', 'legacyKey': 'humus', 'name': {'tr': 'Humus'}, 'category': 'c1', 'price': 90, 'available': true, 'active': true},
          ],
      'campaigns': <Map<String, dynamic>>[],
    };

void main() {
  test('prices use Turkish money, never raw doubles', () {
    expect(qrPrice(140), '140,00 ₺');
    expect(qrPrice(140.0), '140,00 ₺');
    expect(qrPrice(1250.5), '1.250,50 ₺');
    expect(qrPrice(null), '—');
  });

  test('a restored draft identical to its source has zero changes', () {
    expect(diffCatalog(cat(), cat()), isEmpty);
  });

  test('diff names each real change', () {
    final d = cat();
    (d['products'] as List)[0]['price'] = 150;
    (d['products'] as List)[1]['available'] = false;
    final c = diffCatalog(cat(), d).map((e) => '$e').toList();
    expect(c, contains('Falafel Dürüm: fiyat 140,00 ₺ → 150,00 ₺'));
    expect(c, contains('Humus: Tükendi'));
    expect(c.length, 2);
  });

  test('merge: untouched draft fields follow newer GitHub prices', () {
    final base = cat(), local = cat(), remote = cat();
    (remote['products'] as List)[0]['price'] = 155; // published after the offline copy
    (local['products'] as List)[1]['available'] = false; // owner edit offline
    final m = mergeOfflineDraft(base: base, local: local, remote: remote);
    expect(m.conflicts, isEmpty);
    final p = m.merged['products'] as List;
    expect(p[0]['price'], 155);
    expect(p[1]['available'], false);
    expect(m.fromGitHub, 1);
    expect(diffCatalog(remote, m.merged).length, 1);
  });

  test('merge: a field changed on both sides is a conflict, never silent', () {
    final base = cat(), local = cat(), remote = cat();
    (remote['products'] as List)[0]['price'] = 155;
    (local['products'] as List)[0]['price'] = 160;
    final m = mergeOfflineDraft(base: base, local: local, remote: remote);
    expect(m.conflicts.single.field, 'price');
    expect(m.conflicts.single.show(m.conflicts.single.remote), '155,00 ₺');
    expect((m.resolve({})['products'] as List)[0]['price'], 160);
    expect((m.resolve({m.conflicts.single.key: 'remote'})['products'] as List)[0]['price'], 155);
  });

  test('merge: removed on GitHub but edited offline is a conflict; untouched follows removal', () {
    final base = cat(), local = cat();
    final remote = cat(products: [cat()['products'][0] as Map<String, dynamic>]);
    var m = mergeOfflineDraft(base: base, local: local, remote: remote);
    expect(m.conflicts, isEmpty);
    expect((m.merged['products'] as List).length, 1);
    (local['products'] as List)[1]['price'] = 95;
    m = mergeOfflineDraft(base: base, local: local, remote: remote);
    expect(m.conflicts.single.field, '*');
    expect((m.resolve({m.conflicts.single.key: 'remote'})['products'] as List).length, 1);
  });

  test('merge: new items from both sides are kept', () {
    final base = cat(), local = cat(), remote = cat();
    (local['products'] as List).add({'id': 'p3', 'legacyKey': 'yeni', 'name': {'tr': 'Yeni'}, 'price': 50});
    (remote['products'] as List).add({'id': 'p4', 'legacyKey': 'gh', 'name': {'tr': 'GH'}, 'price': 60});
    final m = mergeOfflineDraft(base: base, local: local, remote: remote);
    final ids = (m.merged['products'] as List).map((r) => r['id']).toSet();
    expect(ids, containsAll(['p1', 'p2', 'p3', 'p4']));
  });

  test('merge refuses a changed product identity', () {
    final remote = cat();
    (remote['products'] as List)[0]['legacyKey'] = 'other';
    expect(() => mergeOfflineDraft(base: cat(), local: cat(), remote: remote), throwsFormatException);
  });

  test('page state: one truthful state each', () {
    QrPageState s({bool hasMenu = true, bool busy = false, bool publishing = false, String? revision = 'r1',
            int changes = 0, bool conflicts = false, bool pending = false}) =>
        qrPageState(hasMenu: hasMenu, busy: busy, publishing: publishing, revision: revision,
            changes: changes, conflicts: conflicts, pendingPublish: pending);
    expect(s(hasMenu: false), QrPageState.notLoaded);
    expect(s(hasMenu: false, busy: true), QrPageState.connecting);
    expect(s(revision: null, changes: 3), QrPageState.offlineDraft);
    expect(s(), QrPageState.clean);
    expect(s(changes: 2), QrPageState.dirty);
    expect(s(conflicts: true, changes: 2), QrPageState.conflict);
    expect(s(publishing: true), QrPageState.publishing);
    expect(s(pending: true), QrPageState.unknownOutcome);
  });
}
