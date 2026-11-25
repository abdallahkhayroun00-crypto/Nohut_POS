/// One inclusive Istanbul calendar period for every section of the report.
class ReportPeriod {
  const ReportPeriod(this.from, this.to);
  final String from, to;

  static String day(DateTime date) => date.toIso8601String().substring(0, 10);
  static DateTime today() => DateTime.now().toUtc().add(const Duration(hours: 3));
  static DateTime parse(String value) {
    final d = DateTime.tryParse(value);
    if (d == null || value.length != 10 || day(d) != value) {
      throw const FormatException('Geçerli YYYY-MM-DD tarihi girin.');
    }
    return DateTime.utc(d.year, d.month, d.day);
  }
  void validate() {
    final a = parse(from), b = parse(to);
    if (a.isAfter(b) || b.difference(a).inDays > 365 ||
        to.compareTo(day(today())) > 0) {
      throw const FormatException('Geçerli, en fazla 366 günlük geçmiş dönem seçin.');
    }
  }
  bool includes(String value) => value.compareTo(from) >= 0 && value.compareTo(to) <= 0;
  bool includesStamp(Object? value) {
    final d = DateTime.tryParse(value?.toString() ?? '');
    return d != null && includes(day(d.toUtc().add(const Duration(hours: 3))));
  }
  static const presets = ['Bugün', 'Son 7 Gün', 'Son 30 Gün', 'Bu Ay', 'Geçen Ay', 'Bu Yıl', 'Özel Tarih'];
  static ReportPeriod preset(String label, {DateTime? now}) {
    final d = now ?? today();
    final end = DateTime.utc(d.year, d.month, d.day);
    final start = switch (label) {
      'Son 7 Gün' => end.subtract(const Duration(days: 6)),
      'Son 30 Gün' => end.subtract(const Duration(days: 29)),
      'Bu Ay' => DateTime.utc(d.year, d.month, 1),
      'Geçen Ay' => DateTime.utc(d.year, d.month - 1, 1),
      'Bu Yıl' => DateTime.utc(d.year, 1, 1),
      _ => end,
    };
    final last = label == 'Geçen Ay' ? DateTime.utc(d.year, d.month, 0) : end;
    return ReportPeriod(day(start), day(last));
  }
  List<String> get months {
    final start = parse(from), end = parse(to);
    final result = <String>[];
    for (var d = DateTime.utc(start.year, start.month); !d.isAfter(end);
        d = DateTime.utc(d.year, d.month + 1)) {
      result.add(day(d).substring(0, 7));
    }
    return result;
  }
  bool fullMonth(String month) {
    final d = parse(month + '-01');
    return includes(day(d)) && includes(day(DateTime.utc(d.year, d.month + 1, 0)));
  }
  String get fileName => 'Nohut_Tam_Yonetim_' + from + '_' + to + '.pdf';
}
