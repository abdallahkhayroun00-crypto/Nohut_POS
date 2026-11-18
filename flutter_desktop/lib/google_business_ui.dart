import 'dart:async';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'google_business.dart';
import 'order_reporting.dart';
import 'review_display.dart';
import 'pos_logic.dart';
import 'trendyol_go_ui.dart' show openExternalPage;

enum _Section {
  reviews('Yorumlar'),
  performance('Performans'),
  search('Arama terimleri'),
  profile('Profil'),
  menu('Menü'),
  media('Fotoğraflar'),
  posts('Gönderiler'),
  notifications('Bildirimler'),
  permissions('İzinler');

  const _Section(this.label);
  final String label;
}

class GoogleBusinessPanel extends StatefulWidget {
  const GoogleBusinessPanel({super.key, required this.google});
  final GoogleBusiness google;

  @override
  State<GoogleBusinessPanel> createState() => _GoogleBusinessPanelState();
}

class _GoogleBusinessPanelState extends State<GoogleBusinessPanel> {
  _Section section = _Section.reviews;
  Json? data;
  bool busy = false, onlyUnanswered = false;
  String? error;
  int _generation = 0;

  GoogleBusiness get google => widget.google;

  @override
  void initState() {
    super.initState();
    google.addListener(_connectionChanged);
    if (google.connected) unawaited(_load());
  }

  @override
  void dispose() {
    google.removeListener(_connectionChanged);
    super.dispose();
  }

  void _connectionChanged() {
    setState(() {
      data = null;
      error = null;
    });
    if (google.connected) unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    final id = ++_generation;
    final token = more ? (data?['nextPageToken'] as String?) : null;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final received = await switch (section) {
        _Section.reviews => google.reviews(pageToken: token),
        _Section.performance => google.performance(),
        _Section.search => google.searchTerms(),
        _Section.profile => google.profile(),
        _Section.menu => google.menu(),
        _Section.media => google.media(),
        _Section.posts => google.posts(),
        _Section.notifications => google.notifications(),
        _Section.permissions => google.permissions(),
      };
      if (!mounted || id != _generation) return;
      if (section == _Section.reviews && more) {
        final rows = asMaps(received['reviews']);
        received['reviews'] = {
          for (final row in [...asMaps(data?['reviews']), ...rows])
            row['reviewId']: row,
        }.values.toList();
      }
      setState(() => data = received);
    } catch (e) {
      if (mounted && id == _generation)
        setState(() => error = _errorMessage(e));
    } finally {
      if (mounted && id == _generation) setState(() => busy = false);
    }
  }

  String _errorMessage(Object e) => e is FormatException && e.source == null
      ? e.message
      : 'Google bağlantısı tamamlanamadı. Bağlantıyı kontrol edip tekrar deneyin.';

  Future<void> _connect() async {
    final values = await showDialog<List<String>>(
      context: context,
      builder: (_) => const _GoogleConfigDialog(),
    );
    if (values == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await google.connect(
        clientId: values[0],
        clientSecret: values[1],
        account: values[2],
        location: values[3],
        openBrowser: (url) async {
          if (!mounted || !await openExternalPage(context, '$url')) {
            throw const FormatException(
              'Google yetkilendirmesi için tarayıcı açılamadı.',
            );
          }
        },
      );
    } catch (e) {
      if (mounted) setState(() => error = _errorMessage(e));
    } finally {
      if (mounted && !google.connected) setState(() => busy = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await google.disconnect();
    } catch (e) {
      if (mounted) setState(() => error = _errorMessage(e));
    }
  }

  Future<void> _reply(Json review) async {
    final existing = _map(review['reviewReply']);
    final comment = await showDialog<String>(
      context: context,
      builder: (_) =>
          _GoogleReplyDialog(existing: '${existing['comment'] ?? ''}'),
    );
    if (comment == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final sent = await google.reply('${review['reviewId']}', comment);
      if (!mounted) return;
      final rows = asMaps(data?['reviews']);
      setState(
        () => data = {
          ...?data,
          'reviews': [
            for (final row in rows)
              if (row['reviewId'] == review['reviewId'])
                {...row, 'reviewReply': sent}
              else
                row,
          ],
        },
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google yanıtı yayınlandı.')),
      );
    } catch (e) {
      if (mounted) setState(() => error = _errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  static Json _map(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : {};

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                google.connected
                    ? 'Google hesabı bağlı'
                    : 'Google hesabı bağlı değil',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (!google.connected)
                const Text(
                  'Bağlanmak için Google Business Profile API proje onayı ve işletme hesabı yetkisi gerekir.',
                ),
              if (google.loadError case final message?) Text(message),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (google.connected)
                    OutlinedButton(
                      onPressed: busy ? null : _disconnect,
                      child: const Text('Bağlantıyı Kaldır'),
                    )
                  else
                    FilledButton(
                      onPressed: busy ? null : _connect,
                      child: const Text('Google Hesabını Bağla'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        openExternalPage(context, GoogleBusiness.managerUrl),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('İşletme Paneli'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        openExternalPage(context, GoogleBusiness.mapsUrl),
                    icon: const Icon(Icons.place_outlined, size: 16),
                    label: const Text('Google Maps'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final option in _Section.values)
            ChoiceChip(
              label: Text(option.label),
              selected: section == option,
              onSelected: busy
                  ? null
                  : (_) {
                      if (section == option) return;
                      setState(() {
                        section = option;
                        data = null;
                        error = null;
                      });
                      if (google.connected) unawaited(_load());
                    },
            ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (error case final message?)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(message),
        ),
      if (google.connected) ...[
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Yenile'),
          ),
        ),
        if (data case final current?) ..._content(current),
      ],
    ],
  );

  List<Widget> _content(Json current) => switch (section) {
    _Section.reviews => _reviews(current),
    _Section.performance => [
      const ListTile(title: Text('Son 30 tamamlanan gün')),
      ..._performance(current),
    ],
    _Section.search => [
      const ListTile(title: Text('Geçen takvim ayı · İlk 25 sonuç')),
      ..._items(
        current,
        'searchKeywordsCounts',
        (row) => (
          '${row['searchKeyword']}',
          _impressions(_map(row['insightsValue'])),
        ),
      ),
    ],
    _Section.profile => [
      ListTile(
        title: Text('${current['title'] ?? 'İşletme'}'),
        subtitle: Text(
          [
            _map(current['storefrontAddress'])['locality'],
            _map(current['phoneNumbers'])['primaryPhone'],
            current['websiteUri'],
          ].whereType<String>().join(' · '),
        ),
      ),
      ..._items(
        _map(current['regularHours']),
        'periods',
        (row) => (
          '${row['openDay']} · ${_clock(row['openTime'])}',
          'Kapanış · ${row['closeDay']} ${_clock(row['closeTime'])}',
        ),
      ),
    ],
    _Section.menu => _items(
      current,
      'menus',
      (row) => (
        _label(row['labels'], 'Menü'),
        asMaps(row['sections'])
            .map(
              (entry) =>
                  '${_label(entry['labels'], 'Bölüm')} · ${asMaps(entry['items']).length} ürün',
            )
            .join('\n'),
      ),
    ),
    _Section.media => _items(
      current,
      'mediaItems',
      (row) => (
        '${_map(row['locationAssociation'])['category'] ?? row['mediaFormat'] ?? 'Fotoğraf'}',
        istanbulStamp(row['createTime']),
      ),
    ),
    _Section.posts => _items(
      current,
      'localPosts',
      (row) =>
          ('${row['summary'] ?? 'Gönderi'}', istanbulStamp(row['createTime'])),
    ),
    _Section.notifications => [
      ListTile(
        title: Text(
          current['pubsubTopic'] == null
              ? 'Google Pub/Sub konusu ayarlanmadı'
              : 'Google Pub/Sub konusu bağlı',
        ),
        subtitle: Text(
          (current['notificationTypes'] as List? ?? []).join(', '),
        ),
      ),
      const ListTile(
        title: Text('Yorum uyarıları'),
        subtitle: Text(
          'POS açıkken beş dakikada bir yeni yorumlar kontrol edilir.',
        ),
      ),
    ],
    _Section.permissions => _items(
      current,
      'admins',
      (row) => (
        '${row['admin'] ?? row['account'] ?? 'Google hesabı'}',
        '${row['role'] ?? ''}${row['pendingInvitation'] == true ? ' · Davet bekliyor' : ''}',
      ),
    ),
  };

  String _label(Object? value, String fallback) =>
      '${asMaps(value).firstOrNull?['displayName'] ?? fallback}';
  String _clock(Object? value) => [
    for (final key in ['hours', 'minutes'])
      '${_map(value)[key] ?? 0}'.padLeft(2, '0'),
  ].join(':');
  String _impressions(Json row) => row['value'] != null
      ? '${row['value']} gösterim'
      : row['threshold'] != null
      ? '${row['threshold']} altında'
      : '—';

  List<Widget> _performance(Json current) {
    const names = {
      'BUSINESS_IMPRESSIONS_MOBILE_MAPS': 'Maps · Mobil',
      'BUSINESS_IMPRESSIONS_DESKTOP_MAPS': 'Maps · Masaüstü',
      'BUSINESS_IMPRESSIONS_MOBILE_SEARCH': 'Arama · Mobil',
      'BUSINESS_IMPRESSIONS_DESKTOP_SEARCH': 'Arama · Masaüstü',
      'CALL_CLICKS': 'Arama düğmesi tıklaması',
      'WEBSITE_CLICKS': 'Web sitesi tıklaması',
      'BUSINESS_DIRECTION_REQUESTS': 'Yol tarifi isteği',
    };
    final rows = [
      for (final group in asMaps(current['multiDailyMetricTimeSeries']))
        ...asMaps(group['dailyMetricTimeSeries']),
    ];
    return _items(
      {'metrics': rows},
      'metrics',
      (row) => (
        names[row['dailyMetric']] ?? '${row['dailyMetric']}',
        '${asMaps(_map(row['timeSeries'])['datedValues']).fold(0, (total, day) => total + (int.tryParse('${day['value']}') ?? 0))}',
      ),
    );
  }

  List<Widget> _items(
    Json current,
    String key,
    (String, String) Function(Json) fields,
  ) {
    final rows = asMaps(current[key]);
    return [
      if (rows.isEmpty) const ListTile(title: Text('Gösterilecek kayıt yok.')),
      for (final (title, subtitle) in rows.map(fields))
        Card(
          child: ListTile(title: Text(title), subtitle: Text(subtitle)),
        ),
    ];
  }

  List<Widget> _reviews(Json current) {
    final rows = asMaps(current['reviews'])
        .where((row) => !onlyUnanswered || row['reviewReply'] == null)
        .toList()
      ..sort((a, b) {
        // Newest reviews first, regardless of reply/update time.
        final left = reviewDate(a['createTime'] ?? a['updateTime']);
        final right = reviewDate(b['createTime'] ?? b['updateTime']);
        if (left == null) return right == null ? 0 : 1;
        if (right == null) return -1;
        return right.compareTo(left);
      });
    const stars = {'ONE': 1, 'TWO': 2, 'THREE': 3, 'FOUR': 4, 'FIVE': 5};
    return [
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${current['averageRating'] ?? '—'} / 5 · ${current['totalReviewCount'] ?? 0} yorum',
          ),
          FilterChip(
            label: const Text('Yanıtsız'),
            selected: onlyUnanswered,
            onSelected: (value) => setState(() => onlyUnanswered = value),
          ),
        ],
      ),
      if (rows.isEmpty) const ListTile(title: Text('Gösterilecek yorum yok.')),
      for (final row in rows)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_map(row['reviewer'])['displayName'] ?? 'Google kullanıcısı'} · ${stars[row['starRating']] ?? '—'}/5',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(reviewDateText(row['createTime'] ?? row['updateTime'])),
                    Text(reviewRelativeAge(row['createTime'] ?? row['updateTime']),
                      style: const TextStyle(color: NohutBrand.muted)),
                    const Text('Google Maps',
                      style: TextStyle(color: NohutBrand.green,
                          fontWeight: FontWeight.w600)),
                  ],
                ),
                if (row['comment'] case final String comment
                    when comment.isNotEmpty)
                  SelectableText(comment),
                if (_map(row['reviewReply'])['comment']
                    case final String comment) ...[
                  const Divider(),
                  const Text('İşletme yanıtı'),
                  SelectableText(comment),
                ],
                TextButton(
                  onPressed: busy ? null : () => _reply(row),
                  child: Text(
                    row['reviewReply'] == null ? 'Yanıtla' : 'Yanıtı Düzenle',
                  ),
                ),
              ],
            ),
          ),
        ),
      if (current['nextPageToken'] case final String token
          when token.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: busy ? null : () => _load(more: true),
            child: const Text('Daha Fazla Yorum'),
          ),
        ),
    ];
  }
}

class _GoogleConfigDialog extends StatefulWidget {
  const _GoogleConfigDialog();
  @override
  State<_GoogleConfigDialog> createState() => _GoogleConfigDialogState();
}

class _GoogleConfigDialogState extends State<_GoogleConfigDialog> {
  final fields = List.generate(4, (_) => TextEditingController());
  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Google İşletme Profili bağlantısı'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, label) in [
              'Masaüstü OAuth Client ID',
              'OAuth Client Secret',
              'Hesap ID',
              'Konum ID',
            ].indexed)
              TextField(
                controller: fields[i],
                obscureText: i == 1,
                keyboardType: i >= 2
                    ? TextInputType.number
                    : TextInputType.text,
                decoration: InputDecoration(labelText: label),
                autocorrect: false,
                enableSuggestions: false,
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Vazgeç'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, fields.map((f) => f.text.trim()).toList()),
        child: const Text('Google ile Devam Et'),
      ),
    ],
  );
}

class _GoogleReplyDialog extends StatefulWidget {
  const _GoogleReplyDialog({required this.existing});
  final String existing;
  @override
  State<_GoogleReplyDialog> createState() => _GoogleReplyDialogState();
}

class _GoogleReplyDialogState extends State<_GoogleReplyDialog> {
  late final reply = TextEditingController(text: widget.existing);
  @override
  void dispose() {
    reply.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Google yorumu için herkese açık yanıt'),
    content: SizedBox(
      width: 460,
      child: TextField(
        controller: reply,
        autofocus: true,
        minLines: 3,
        maxLines: 7,
        decoration: const InputDecoration(labelText: 'Yanıtınız'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Vazgeç'),
      ),
      FilledButton(
        onPressed: () {
          if (reply.text.trim().isNotEmpty)
            Navigator.pop(context, reply.text.trim());
        },
        child: const Text('Yanıtı Google’da Yayınla'),
      ),
    ],
  );
}
