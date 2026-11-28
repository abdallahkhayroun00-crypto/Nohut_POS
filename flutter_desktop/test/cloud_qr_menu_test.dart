import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/cloud_qr_menu_bridge.dart';

void main() {
  test('serializeQrMenuCloudState handles unavailable draft honestly', () {
    final out = serializeQrMenuCloudState({}, now: DateTime.utc(2026, 11, 27, 21));
    expect(out['available'], isFalse);
    expect(out['calculated_at'], '2026-11-27T21:00:00.000Z');
  });

  test('serializeQrMenuCloudState produces exact contract shape and strips unknown/secret fields', () {
    final state = <String, dynamic>{
      qrRevisionKey: 'rev-synthetic-987654',
      qrPendingKey: {'requestId': 'req-1'},
      qrDraftKey: {
        'githubToken': 'SHOULD_NEVER_SERIALIZE',
        'categories': [
          {
            'id': 'wraps',
            'name': {'tr': 'Dürümler', 'en': 'Wraps', 'ar': 'لفائف'},
            'active': true,
            'order': 1,
            'secret': 'strip-me',
          },
        ],
        'products': [
          {
            'id': 'falafel-wrap',
            'category': 'wraps',
            'name': {'tr': 'Falafel Dürüm', 'en': 'Falafel Wrap', 'ar': 'لفافة فلافل'},
            'price': 160,
            'available': true,
            'active': true,
            'image': 'assets/falafel_wrap.webp',
            'order': 1,
            'publisherKey': 'strip-me',
          },
        ],
        'campaigns': [
          {
            'id': 'camp-1',
            'title': {'tr': 'Menü', 'en': 'Combo', 'ar': 'عرض'},
            'price': 200,
            'active': true,
            'token': 'strip-me',
          },
        ],
      },
      qrAuditKey: List.generate(120, (i) => {
        'at': '2026-11-27T20:00:00Z',
        'actor': 'Synthetic Staff',
        'action': 'set_price',
        'id': 'p-$i',
        'token': 'strip-me',
      }),
    };

    final out = serializeQrMenuCloudState(
      state,
      link: 'ready',
      now: DateTime.utc(2026, 11, 27, 21, 5),
    );
    expect(out['available'], isTrue);
    expect(out['stamp'], matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(out['revision'], 'rev-synthetic-987654');
    expect(out['revisionLabel'], 'rev-synt');
    expect(out['offline'], isFalse);
    expect(out['pendingPublish'], isTrue);
    expect(out['link'], 'ready');

    final catalog = out['catalog'] as Map<String, dynamic>;
    final cat0 = (catalog['categories'] as List).first as Map<String, dynamic>;
    final prod0 = (catalog['products'] as List).first as Map<String, dynamic>;
    final camp0 = (catalog['campaigns'] as List).first as Map<String, dynamic>;
    expect(cat0.containsKey('secret'), isFalse);
    expect(prod0.containsKey('publisherKey'), isFalse);
    expect(camp0.containsKey('token'), isFalse);

    final audit = out['recentAudit'] as List;
    expect(audit, hasLength(100));
    expect((audit.first as Map).containsKey('token'), isFalse);
  });
}
