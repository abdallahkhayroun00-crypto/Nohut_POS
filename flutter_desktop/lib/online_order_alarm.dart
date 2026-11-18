import 'dart:async';

import 'package:flutter/foundation.dart';

/// Verified remote order notification, never a local acceptance operation.
class OnlineAlarmOrder {
  const OnlineAlarmOrder({
    required this.platform,
    required this.key,
    required this.number,
    required this.detectedAt,
  });
  final String platform, key, number;
  final DateTime detectedAt;

  int elapsedSeconds(DateTime now) => now.difference(detectedAt).inSeconds;
  int severity(DateTime now) {
    final elapsed = elapsedSeconds(now);
    return elapsed >= 90 ? 2 : elapsed >= 45 ? 1 : 0;
  }
}

/// One shared audible queue for all restaurant delivery partners.
/// The partner connector must provide authoritative API status snapshots.
class OnlineOrderAlarm extends ChangeNotifier {
  OnlineOrderAlarm({
    required this.play,
    required this.stopAudio,
    DateTime Function()? clock,
    bool startTicker = true,
  }) : _clock = clock ?? DateTime.now {
    if (startTicker) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    }
  }

  final Future<void> Function(String platform, int severity) play;
  final void Function() stopAudio;
  final DateTime Function() _clock;
  Timer? _timer;
  final Map<String, OnlineAlarmOrder> _pending = {};
  DateTime? _lastRing;
  int _ringIndex = 0;
  bool _audioEnabled = true;
  bool _disposed = false;

  static const ringLength = Duration(seconds: 10);
  static const repeatEvery = Duration(seconds: 15);
  static const providers = ['Trendyol Go', 'Yemeksepeti', 'Migros Yemek'];

  List<OnlineAlarmOrder> get pending => _pending.values.toList()
    ..sort((a, b) => a.detectedAt.compareTo(b.detectedAt));
  bool get hasPending => _pending.isNotEmpty;
  bool get audioEnabled => _audioEnabled;
  int get maxSeverity {
    if (_pending.isEmpty) return 0;
    return _pending.values
        .map((order) => order.severity(_clock()))
        .reduce((a, b) => a > b ? a : b);
  }

  static bool requiresAcceptance(String status) =>
      const ['Created', 'New', 'Pending', 'PendingAcceptance', 'WaitingForApproval']
          .contains(status);

  static String identity(String platform, Map<String, dynamic> order) {
    final supplier = '${order['supplierId'] ?? ''}';
    final branch = '${order['storeId'] ?? order['restaurantId'] ?? ''}';
    final package = '${order['packageId'] ?? order['id'] ?? order['orderNumber'] ?? ''}';
    if (package.isEmpty) return '';
    return '$platform:$supplier:$branch:$package';
  }

  /// Called only after a successful, authoritative platform synchronization.
  /// Failed polling MUST NOT silently dismiss pending notifications.
  void acceptSnapshot(String platform, List<Map<String, dynamic>> orders) {
    if (_disposed || !providers.contains(platform)) return;
    final now = _clock();
    var changed = false;
    for (final order in orders) {
      if (order['testPackage'] == true) continue;
      final key = identity(platform, order);
      if (key.isEmpty) continue;
      final status = '${order['status'] ?? ''}';
      if (!requiresAcceptance(status)) {
        if (_pending.remove(key) != null) changed = true;
        continue;
      }
      final createdAt = DateTime.tryParse('${order['createdAt'] ?? ''}');
      // Do not ring for stale archived snapshots at first connection.
      if (createdAt == null ||
          createdAt.isAfter(now.add(const Duration(minutes: 5))) ||
          now.difference(createdAt).inHours >= 24) {
        continue;
      }
      if (!_pending.containsKey(key)) {
        _pending[key] = OnlineAlarmOrder(
          platform: platform,
          key: key,
          number: '${order['orderNumber'] ?? order['packageId'] ?? ''}',
          detectedAt: now,
        );
        changed = true;
      }
    }
    // Missing records do not imply acceptance: paginated API responses can
    // omit an active order. Only an explicit confirmed status removes an alert.
    if (_pending.isEmpty) {
      _lastRing = null;
      stopAudio();
    }
    if (changed) notifyListeners();
    if (changed && _pending.isNotEmpty && _lastRing == null) tick();
  }

  void setAudioEnabled(bool value) {
    if (_audioEnabled == value) return;
    _audioEnabled = value;
    if (!value) stopAudio();
    _lastRing = null;
    notifyListeners();
    if (value && hasPending) tick();
  }

  void tick() {
    if (_disposed) return;
    final now = _clock();
    if (_audioEnabled && _pending.isNotEmpty &&
        (_lastRing == null || now.difference(_lastRing!) >= repeatEvery)) {
      final active = pending;
      final chosen = active[_ringIndex % active.length];
      _ringIndex++;
      _lastRing = now;
      unawaited(play(chosen.platform, maxSeverity).catchError((Object _) {}));
    }
    if (_pending.isNotEmpty) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    stopAudio();
    super.dispose();
  }
}
