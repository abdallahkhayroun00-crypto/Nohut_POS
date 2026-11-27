/// Ayarlar › Bildirimler › Bildirim geçmişi (spec §23.5, N2).
library;

import 'package:flutter/material.dart';

import 'brand.dart';
import 'notification_center.dart';
import 'notification_events.dart';
import 'pos_logic.dart';
import 'pos_store.dart';
import 'review_sync_service.dart' show notificationsStateKey;

class NotificationHistoryPanel extends StatefulWidget {
  const NotificationHistoryPanel({super.key, required this.store});
  final PosStore store;
  @override
  State<NotificationHistoryPanel> createState() => _NotificationHistoryPanelState();
}

class _NotificationHistoryPanelState extends State<NotificationHistoryPanel> {
  String? category;

  void _markRead(bool Function(Json) where) {
    final snap = widget.store.read(), next = copyJson(snap.data);
    next[notificationsStateKey] = updateNotifications(
        next[notificationsStateKey] as List?, where, (r) => r['read'] = true);
    widget.store.replace(next, snap.revision);
    setState(() {});
  }

  static String _time(Object? iso) {
    final t = DateTime.tryParse('$iso')?.toLocal();
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final rows = asMaps(widget.store.read().data[notificationsStateKey]).reversed
        .where((r) => category == null || r['category'] == category).take(200).toList();
    final unread = unreadNotifications(widget.store.read().data[notificationsStateKey] as List?);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('Okunmamış: $unread',
            style: const TextStyle(color: NohutBrand.green, fontWeight: FontWeight.w700)),
        DropdownButton<String?>(
          isDense: true,
          value: category,
          hint: const Text('Tüm kategoriler'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Tüm kategoriler')),
            for (final e in notificationCategories.entries)
              if (e.value.clients.contains('windows'))
                DropdownMenuItem<String?>(value: e.key, child: Text(e.value.label)),
          ],
          onChanged: (v) => setState(() => category = v),
        ),
        TextButton(
          key: const ValueKey('notifications-mark-all'),
          onPressed: unread == 0 ? null : () => _markRead((r) => category == null || r['category'] == category),
          child: const Text('Tümünü okundu say'),
        ),
      ]),
      if (rows.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Henüz bildirim yok.')),
      for (final r in rows)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            r['severity'] == 'high' ? Icons.error_outline : Icons.notifications_none,
            color: r['read'] == true ? NohutBrand.muted
                : r['severity'] == 'high' ? const Color(0xff9b2c22) : NohutBrand.green),
          title: Text('${r['title']}', style: TextStyle(
              fontWeight: r['read'] == true ? FontWeight.w400 : FontWeight.w700)),
          subtitle: Text([
            notificationCategories['${r['category']}']?.label ?? '${r['category']}',
            _time(r['createdAt']),
            if ('${r['body'] ?? ''}'.isNotEmpty) '${r['body']}',
          ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: r['read'] == true ? null : TextButton(
            onPressed: () => _markRead((x) => x['eventId'] == r['eventId']),
            child: const Text('Okundu'),
          ),
        ),
    ]);
  }
}
