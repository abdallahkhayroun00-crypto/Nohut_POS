import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/online_order_alarm.dart';

void main() {
  final origin = DateTime.utc(2026, 11, 19, 9);
  late DateTime current;
  late List<String> played;
  late int stops;
  late OnlineOrderAlarm alarm;
  Map<String, dynamic> order(
    String id, {
    String status = 'Created',
    String platform = 'Trendyol Go',
  }) => {
    'source': platform,
    'supplierId': '120',
    'storeId': '316490',
    'packageId': id,
    'orderNumber': 'ORDER-$id',
    'createdAt': origin.toIso8601String(),
    'status': status,
  };

  setUp(() {
    current = origin.add(const Duration(seconds: 5));
    played = [];
    stops = 0;
    alarm = OnlineOrderAlarm(
      startTicker: false,
      clock: () => current,
      play: (platform, level) async => played.add('$platform:$level'),
      stopAudio: () => stops++,
    );
  });
  tearDown(() => alarm.dispose());

  test('first verified sync rings for a still-unaccepted online order', () {
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    expect(played, ['Trendyol Go:0']);
    expect(alarm.pending.single.number, 'ORDER-1');
  });

  test('same package in repeated syncs does not restart or duplicate ring', () {
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    current = current.add(const Duration(seconds: 14));
    alarm.tick();
    expect(played.length, 1);
    current = current.add(const Duration(seconds: 1));
    alarm.tick();
    expect(played.length, 2);
    expect(alarm.pending.length, 1);
  });

  test('45/90-second escalation and confirmed acceptance stops the sound', () {
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    current = current.add(const Duration(seconds: 45));
    alarm.tick();
    expect(alarm.maxSeverity, 1);
    expect(played.last, 'Trendyol Go:1');
    current = current.add(const Duration(seconds: 45));
    alarm.tick();
    expect(alarm.maxSeverity, 2);
    expect(played.last, 'Trendyol Go:2');
    alarm.acceptSnapshot('Trendyol Go', [order('1', status: 'Picking')]);
    expect(alarm.pending, isEmpty);
    expect(stops, greaterThan(0));
    current = current.add(const Duration(seconds: 60));
    alarm.tick();
    expect(played.length, 3);
  });

  test('opening a page cannot acknowledge; only explicit remote status does', () {
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    alarm.acceptSnapshot('Trendyol Go', []);
    expect(alarm.pending.length, 1); // missing page is not acceptance
    alarm.acceptSnapshot('Trendyol Go', [order('1', status: 'Cancelled')]);
    expect(alarm.pending, isEmpty);
  });

  test('three providers share one queue without overlapping audio calls', () {
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    alarm.acceptSnapshot('Yemeksepeti', [order('2', platform: 'Yemeksepeti')]);
    alarm.acceptSnapshot('Migros Yemek', [order('3', platform: 'Migros Yemek')]);
    expect(alarm.pending.length, 3);
    expect(played.length, 1);
    current = current.add(const Duration(seconds: 15));
    alarm.tick();
    current = current.add(const Duration(seconds: 15));
    alarm.tick();
    expect(played.length, 3);
    expect(played.map((x) => x.split(':').first).toSet().length, 3);
  });

  test('stale archive cannot start an alarm after an old outage', () {
    current = origin.add(const Duration(days: 3));
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    expect(alarm.pending, isEmpty);
    expect(played, isEmpty);
  });

  test('independent sound toggle preserves visible pending orders', () {
    alarm.setAudioEnabled(false);
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    expect(alarm.pending, hasLength(1));
    expect(played, isEmpty);
    alarm.setAudioEnabled(true);
    expect(played, hasLength(1));
  });
}
