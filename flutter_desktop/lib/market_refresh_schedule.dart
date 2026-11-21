/// Exact-price-check scheduling for a POS running in Türkiye.
/// Türkiye uses UTC+03 year-round. No location permissions are needed.

String? validMarketRefreshClock(Object? value) {
  if (value is! String || value.length != 5 || value[2] != ':') return null;
  final hour = int.tryParse(value.substring(0, 2));
  final minute = int.tryParse(value.substring(3, 5));
  if (hour == null || minute == null ||
      hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  if (value.substring(0, 2) != hour.toString().padLeft(2, '0') ||
      value.substring(3, 5) != minute.toString().padLeft(2, '0')) return null;
  return value;
}

int marketScheduleHours(Object? value) =>
    value is int && const [24, 12, 6, 1].contains(value) ? value : 12;

List<String> marketRefreshClockLabels(int interval, String startTime) {
  final clock = validMarketRefreshClock(startTime);
  if (clock == null) return const [];
  final period = marketScheduleHours(interval);
  final anchor = int.parse(clock.substring(0, 2)) * 60 +
      int.parse(clock.substring(3, 5));
  final labels = <String>[];
  for (var hour = 0; hour < 24; hour += period) {
    final minute = (anchor + 60 * hour) % 1440;
    labels.add((minute ~/ 60).toString().padLeft(2, '0') +
        ':' + (minute % 60).toString().padLeft(2, '0'));
  }
  labels.sort();
  return labels;
}

/// Last scheduled wall-clock slot at/before now.
/// For 12h + 11:00: 11:00 and 23:00 Istanbul time.
DateTime latestMarketRefreshSlotUtc(
    DateTime now, int hours, String startTime) {
  final clock = validMarketRefreshClock(startTime);
  if (clock == null) throw const FormatException('Geçersiz kontrol saati.');
  const offset = Duration(hours: 3);
  final turkeyNow = now.toUtc().add(offset);
  final localAnchor = DateTime.utc(turkeyNow.year, turkeyNow.month,
      turkeyNow.day, int.parse(clock.substring(0, 2)),
      int.parse(clock.substring(3, 5)));
  final every = Duration(hours: marketScheduleHours(hours));
  // floor() is essential before the first slot of a day.
  final elapsedPeriods = (turkeyNow.difference(localAnchor).inMicroseconds /
      every.inMicroseconds).floor();
  return localAnchor.add(Duration(
      microseconds: every.inMicroseconds * elapsedPeriods)).subtract(offset);
}

/// Checks once per due slot even if a previous refresh was late. On reopening
/// a sleeping/closed POS, the first poll performs one catch-up check if due.
/// Manual checks bypass the slots, but retain the two-minute API guard.
bool marketRefreshIsDue(Map<String, dynamic> settings, DateTime now,
    {bool force = false}) {
  final last = DateTime.tryParse(
      (settings['lastRefreshAttempt'] ?? '').toString());
  final utcNow = now.toUtc();
  if (last != null && utcNow.difference(last.toUtc()) <
      const Duration(minutes: 2)) return false;
  if (force) return true;
  final hours = marketScheduleHours(settings['refreshIntervalHours']);
  final anchor = validMarketRefreshClock(settings['refreshAt']);
  if (anchor != null) {
    final slot = latestMarketRefreshSlotUtc(utcNow, hours, anchor);
    final configured = DateTime.tryParse(
        (settings['refreshConfiguredAt'] ?? '').toString());
    if (configured != null && !slot.isAfter(configured.toUtc())) {
      // Setting a clock at 10:00 must not trigger yesterday's 11:00 slot.
      return false;
    }
    return last == null || last.toUtc().isBefore(slot);
  }
  return last == null ||
      utcNow.difference(last.toUtc()) >= Duration(hours: hours);
}
