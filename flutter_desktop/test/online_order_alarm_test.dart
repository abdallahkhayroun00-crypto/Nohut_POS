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

  test('first verified order triggers one short sound while still pending', () {
    expect(OnlineOrderAlarm.ringLength, const Duration(seconds: 3));
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    expect(played, ['Trendyol Go:0']);
    expect(alarm.pending.single.number, 'ORDER-1');
  });

  test('same order NEVER re-rings even after 45/90 seconds unaccepted', () async {
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    current = current.add(const Duration(seconds: 45));
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    alarm.tick();
    expect(alarm.maxSeverity, 1);
    current = current.add(const Duration(seconds: 45));
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    alarm.tick();
    expect(alarm.maxSeverity, 2);
    await Future<void>.delayed(Duration.zero);
    expect(played, ['Trendyol Go:0']);
    expect(alarm.pending, hasLength(1));
  });

  test('accepted orders disappear visually and do not replay', () async {
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    alarm.acceptSnapshot('Trendyol Go', [order('1', status: 'Picking')]);
    expect(alarm.pending, isEmpty);
    expect(stops, greaterThan(0));
    alarm.acceptSnapshot('Trendyol Go', [order('1')]); // stale status
    await Future<void>.delayed(Duration.zero);
    expect(played, hasLength(1));
  });

  test('opening page and missing page entries never acknowledge the order', () {
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    alarm.acceptSnapshot('Trendyol Go', []);
    expect(alarm.pending.length, 1);
  });

  test('new distinct orders ring individually, never overlap', () async {
    alarm.acceptSnapshot('Trendyol Go', [order('1'), order('2')]);
    await Future<void>.delayed(Duration.zero);
    expect(played, hasLength(2));
    current = current.add(const Duration(seconds: 90));
    alarm.tick();
    alarm.acceptSnapshot('Trendyol Go', [order('1'), order('2')]);
    await Future<void>.delayed(Duration.zero);
    expect(played, hasLength(2));
    alarm.acceptSnapshot('Yemeksepeti',
        [order('3', platform: 'Yemeksepeti')]);
    await Future<void>.delayed(Duration.zero);
    expect(played, hasLength(3));
  });

  test('sound toggle never replays already notified pending orders', () async {
    alarm.setAudioEnabled(false);
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    expect(played, isEmpty);
    alarm.setAudioEnabled(true);
    expect(played, hasLength(1));
    await Future<void>.delayed(Duration.zero);
    alarm.setAudioEnabled(false);
    alarm.setAudioEnabled(true);
    expect(played, hasLength(1));
  });

  test('archived orders and demo packages do not trigger sound', () {
    current = origin.add(const Duration(days: 3));
    alarm.acceptSnapshot('Trendyol Go', [order('1')]);
    expect(alarm.pending, isEmpty);
    expect(played, isEmpty);
  });
}
