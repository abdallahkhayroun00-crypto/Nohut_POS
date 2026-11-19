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

/// A short one-shot alert for each newly discovered online order.
/// Acceptance controls the *visible* queue; it never triggers repeat audio.
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
  final List<OnlineAlarmOrder> _soundQueue = [];
  final Set<String> _signaled = {};
  bool _playing = false;
  bool _audioEnabled = true;
  bool _disposed = false;

  static const ringLength = Duration(seconds: 3);
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

  /// Failed/partial polling must never dismiss a still-pending visible alert.
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
        _soundQueue.removeWhere((queued) => queued.key == key);
        continue;
      }
      final createdAt = DateTime.tryParse('${order['createdAt'] ?? ''}');
      if (createdAt == null ||
          createdAt.isAfter(now.add(const Duration(minutes: 5))) ||
          now.difference(createdAt).inHours >= 24) {
        continue;
      }
      if (!_pending.containsKey(key)) {
        final incoming = OnlineAlarmOrder(
          platform: platform,
          key: key,
          number: '${order['orderNumber'] ?? order['packageId'] ?? ''}',
          detectedAt: now,
        );
        _pending[key] = incoming;
        // Each order ID can ring only once, even across repeated API polls
        // or a temporary out-of-order status snapshot.
        if (!_signaled.contains(key) &&
            !_soundQueue.any((queued) => queued.key == key)) {
          _soundQueue.add(incoming);
        }
        changed = true;
      }
    }
    if (changed) {
      if (_pending.isEmpty) stopAudio();
      notifyListeners();
    }
    _playNextOnce();
  }

  void _playNextOnce() {
    if (_disposed || !_audioEnabled || _playing || _soundQueue.isEmpty) return;
    final next = _soundQueue.removeAt(0);
    if (!_pending.containsKey(next.key)) {
      _playNextOnce();
      return;
    }
    _signaled.add(next.key);
    _playing = true;
    unawaited(play(next.platform, next.severity(_clock()))
        .catchError((Object _) {})
        .whenComplete(() {
      _playing = false;
      _playNextOnce();
    }));
  }

  void setAudioEnabled(bool value) {
    if (_audioEnabled == value) return;
    _audioEnabled = value;
    if (!value) stopAudio();
    notifyListeners();
    if (value) _playNextOnce();
  }

  /// Time affects visible urgency only; it never repeats the sound.
  void tick() {
    if (!_disposed && _pending.isNotEmpty) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _soundQueue.clear();
    stopAudio();
    super.dispose();
  }
}
