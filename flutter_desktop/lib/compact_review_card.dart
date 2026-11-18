import 'package:flutter/material.dart';
import 'brand.dart';

/// Compact, expandable card shared by Google and Trendyol feedback.
/// It explicitly distinguishes a star-only rating from a written comment.
class CompactReviewCard extends StatefulWidget {
  const CompactReviewCard({
    super.key,
    required this.platform,
    required this.score,
    required this.dateLabel,
    this.customerName,
    this.comment,
    this.orderNumber,
    this.orderCustomer,
    this.orderDate,
    this.products = const [],
    this.answerText,
    this.answerStatus,
    this.rejectedReason,
    this.awaitingVerification = false,
    this.onReply,
    this.replyBusy = false,
  });
  final String platform, dateLabel;
  final num? score;
  final String? customerName, comment, orderNumber, orderCustomer, orderDate;
  final List<String> products;
  final String? answerText, answerStatus, rejectedReason;
  final bool awaitingVerification, replyBusy;
  final VoidCallback? onReply;

  @override
  State<CompactReviewCard> createState() => _CompactReviewCardState();
}

class _CompactReviewCardState extends State<CompactReviewCard> {
  bool expanded = false;

  bool get hasComment => (widget.comment ?? '').trim().isNotEmpty;
  bool get hasAnswer => (widget.answerText ?? '').trim().isNotEmpty ||
      (widget.answerStatus ?? '').trim().isNotEmpty ||
      widget.awaitingVerification;
  bool get hasDetails =>
      (widget.orderNumber ?? '').isNotEmpty ||
      (widget.orderCustomer ?? '').isNotEmpty ||
      (widget.orderDate ?? '').isNotEmpty ||
      widget.products.isNotEmpty ||
      (widget.rejectedReason ?? '').isNotEmpty ||
      (widget.comment ?? '').length > 110 ||
      (widget.comment ?? '').contains('\n') ||
      (widget.answerText ?? '').length > 75;

  String get replyStatus {
    if (widget.awaitingVerification) return 'Platformda henüz doğrulanmadı';
    return switch ((widget.answerStatus ?? '').toUpperCase()) {
      'APPROVED' => 'Onaylandı',
      'REJECTED' => 'Reddedildi',
      'WAITING_FOR_APPROVE' => 'İnceleniyor',
      '' => 'Yanıt var',
      _ => widget.answerStatus!,
    };
  }

  @override
  Widget build(BuildContext context) {
    final score = widget.score?.round().clamp(0, 5) ?? 0;
    final comment = widget.comment?.trim() ?? '';
    final reply = widget.answerText?.trim() ?? '';
    final platformColor = widget.platform == 'Trendyol Go'
        ? const Color(0xffE87919) : NohutBrand.green;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: const BorderSide(color: Color(0xffE0E9E3)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 9,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 5; i++)
                      Icon(i < score ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                          size: 16, color: NohutBrand.gold),
                    const SizedBox(width: 5),
                    Text(widget.score == null ? '—'
                        : widget.score!.toStringAsFixed(1),
                      style: const TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: NohutBrand.green)),
                  ],
                ),
                if ((widget.customerName ?? '').trim().isNotEmpty)
                  Text(widget.customerName!,
                    style: const TextStyle(fontWeight: FontWeight.w700,
                        fontSize: 12, color: NohutBrand.ink)),
                Text(widget.platform,
                  style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: platformColor)),
                Text(widget.dateLabel,
                  style: const TextStyle(
                      color: NohutBrand.muted, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 5),
            if (hasComment)
              Text(comment,
                maxLines: expanded ? null : 2,
                overflow: expanded ? null : TextOverflow.ellipsis,
                style: const TextStyle(color: NohutBrand.ink,
                    height: 1.25, fontSize: 13))
            else
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star_border_rounded,
                    size: 14, color: NohutBrand.muted),
                  SizedBox(width: 5),
                  Text('Yalnızca yıldız puanı · Yazılı yorum yok',
                    style: TextStyle(fontSize: 11,
                        color: NohutBrand.muted)),
                ],
              ),
            if (hasAnswer) ...[
              const SizedBox(height: 7),
              Container(
                decoration: BoxDecoration(
                  color: widget.awaitingVerification
                      ? const Color(0xffFFF7E7)
                      : const Color(0xffEDF5F0),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 9, vertical: 6),
                child: Row(
                  children: [
                    Icon(widget.awaitingVerification
                            ? Icons.schedule_outlined
                            : Icons.subdirectory_arrow_right,
                      color: NohutBrand.green, size: 15),
                    const SizedBox(width: 6),
                    Expanded(child: Text(
                      reply.isEmpty
                          ? 'İşletme yanıtı · ' + replyStatus
                          : 'Yanıt · ' + replyStatus + ': ' + reply,
                      maxLines: expanded ? null : 1,
                      overflow: expanded ? null : TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11,
                          color: NohutBrand.ink),
                    )),
                  ],
                ),
              ),
            ],
            if (expanded) ...[
              const Divider(height: 17),
              if ((widget.orderNumber ?? '').isNotEmpty)
                _detail('Sipariş', '#' + widget.orderNumber!),
              if ((widget.orderDate ?? '').isNotEmpty)
                _detail('Sipariş tarihi', widget.orderDate!),
              if ((widget.orderCustomer ?? '').isNotEmpty)
                _detail('Sipariş müşterisi', widget.orderCustomer!),
              if (widget.products.isNotEmpty)
                _detail('Ürünler', widget.products.join(', ')),
              if ((widget.rejectedReason ?? '').isNotEmpty)
                _detail('Red nedeni', widget.rejectedReason!),
            ],
            if (hasDetails || widget.onReply != null)
              Wrap(
                spacing: 7,
                runSpacing: 0,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (hasDetails)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => setState(() => expanded = !expanded),
                      icon: Icon(expanded ? Icons.expand_less
                          : Icons.expand_more, size: 16),
                      label: Text(expanded ? 'Daha Az' : 'Detaylar'),
                    ),
                  if (widget.onReply != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: widget.replyBusy ? null : widget.onReply,
                      icon: const Icon(Icons.reply_outlined, size: 16),
                      label: const Text('Yanıtla'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 118,
          child: Text(label + ':',
            style: const TextStyle(
                fontSize: 11, color: NohutBrand.muted))),
        Expanded(child: SelectableText(value,
          style: const TextStyle(fontSize: 11, color: NohutBrand.ink))),
      ],
    ),
  );
}
