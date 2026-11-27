import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/services.dart';

import 'expense_drafts.dart';
import 'models.dart';
import 'pos_api.dart';
import 'style.dart';
import 'work_page.dart';

class StaffHome extends StatefulWidget {
  const StaffHome({
    super.key,
    required this.controller,
    required this.onUnpair,
    this.ownerMode = false,
    this.ownerName,
  });
  final PersonelController controller;
  final VoidCallback onUnpair;
  final bool ownerMode;
  final String? ownerName;

  @override
  State<StaffHome> createState() => _StaffHomeState();
}

class _StaffHomeState extends State<StaffHome> {
  int tab = 0;
  int tableNumber = 1;
  int? targetOrderId;
  int? selectedStaff;
  String source = 'Masa', pickupChannel = 'Tezgahtan';
  String query = '', category = 'Tümü';
  final List<CartEntry> cart = [];
  final name = TextEditingController();
  final phone = TextEditingController();
  final pickupTime = TextEditingController();
  Json? _pendingRequest;
  bool sending = false;

  PersonelController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    selectedStaff = int.tryParse(c.api.employeeId ?? '');
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    pickupTime.dispose();
    super.dispose();
  }

  void _dirty() => _pendingRequest = null;
  int get count => cart.fold(0, (s, e) => s + e.qty);
  int get total => cart.fold(0, (s, e) => s + e.totalCents);

  void _add(Json product) {
    setState(() {
      _dirty();
      final id = product['id'];
      final index = cart.indexWhere((e) => e.productId == id);
      if (index >= 0) {
        cart[index].qty++;
      } else {
        cart.add(CartEntry(product));
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 700),
      content: Text('${product['name']} · sepete eklendi'),
    ));
  }

  void _target(int table, Json? order) {
    setState(() {
      source = 'Masa';
      tableNumber = table;
      targetOrderId = order?['id'] as int?;
      tab = 1;
      _dirty();
    });
  }

  Future<void> _chooseTable(int n) async {
    final existing = c.orders.where((o) =>
        o['source'] == 'Masa' && o['table'] == n).firstOrNull;
    if (existing == null) {
      _target(n, null);
      return;
    }
    final selection = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Masa $n · Dolu'),
        content: const Text('Mevcut siparişi inceleyebilir veya yeni ürün ekleyebilirsiniz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'show'),
            child: const Text('Siparişi Gör')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'add'),
            child: const Text('Ürün Ekle')),
        ],
      ),
    );
    if (!mounted) return;
    if (selection == 'show') _showOrder(existing);
    if (selection == 'add') _target(n, existing);
  }

  Future<void> _edit(CartEntry line) async {
    final note = TextEditingController(text: line.note);
    final removed = TextEditingController(text: line.removed.join(', '));
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20,
            MediaQuery.viewInsetsOf(ctx).bottom + 22),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(line.name, style: const TextStyle(
            fontFamily: 'Bree', fontSize: 24)),
          const SizedBox(height: 16),
          TextField(controller: note, maxLength: 500,
            decoration: const InputDecoration(labelText: 'Ürün notu')),
          const SizedBox(height: 8),
          TextField(controller: removed,
            decoration: const InputDecoration(
              labelText: 'Çıkarılacak malzemeler (virgülle ayırın)')),
          const SizedBox(height: 14),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kaydet')),
        ]),
      ),
    );
    if (result == true && mounted) {
      setState(() {
        _dirty();
        line.note = note.text.trim();
        line.removed = removed.text.split(',').map((s) => s.trim())
            .where((s) => s.isNotEmpty).toList();
      });
    }
    note.dispose();
    removed.dispose();
  }

  void _openWork() => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WorkPage(api: c.api)));

  String _signedInLabel() {
    final id = c.api.sessionEmployeeId;
    final name = c.employees.where((e) => e['id'] == id).map((e) => '${e['name']}').firstOrNull;
    return name ?? c.api.sessionUser ?? 'Hesabım';
  }

  /// Native sign-in sheet (username + password), or PIN unlock when the
  /// session is only locked after idle time.
  Future<void> _login() async {
    final locked = c.api.sessionStatus == 'locked';
    final user = TextEditingController(), pass = TextEditingController();
    String? error;
    var busy = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(builder: (sheet, set) => Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + MediaQuery.viewInsetsOf(sheet).bottom),
        child: AutofillGroup(child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(locked ? 'Kilidi Aç' : 'Giriş Yap', style: Theme.of(sheet).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(locked ? 'Oturumunuz kilitlendi. 5 haneli PIN’inizi girin.'
              : 'Windows › Kullanıcılar’da oluşturulan hesabınızla giriş yapın.',
              style: Theme.of(sheet).textTheme.bodyMedium),
          const SizedBox(height: 16),
          if (!locked) TextField(controller: user, autofocus: true,
            autofillHints: const [AutofillHints.username], textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Kullanıcı adı', prefixIcon: Icon(Icons.person_outline))),
          if (!locked) const SizedBox(height: 12),
          TextField(controller: pass, obscureText: true, autofocus: locked,
            autofillHints: locked ? null : const [AutofillHints.password],
            keyboardType: locked ? TextInputType.number : TextInputType.visiblePassword,
            maxLength: locked ? 5 : null,
            decoration: InputDecoration(labelText: locked ? 'PIN' : 'Şifre',
              prefixIcon: const Icon(Icons.lock_outline))),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(error!, style: TextStyle(color: Theme.of(sheet).colorScheme.error))),
          const SizedBox(height: 16),
          FilledButton(onPressed: busy ? null : () async {
            set(() { busy = true; error = null; });
            try {
              if (locked) {
                await c.api.unlock(pin: pass.text.trim());
              } else {
                await c.api.login(user.text, pass.text);
              }
              HapticFeedback.lightImpact();
              if (sheet.mounted) Navigator.pop(sheet);
            } on FormatException catch (e) {
              HapticFeedback.heavyImpact();
              set(() { busy = false; error = e.message; });
            } catch (_) {
              set(() { busy = false; error = 'Laptop bağlantısı kurulamadı.'; });
            }
          }, child: busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(locked ? 'Kilidi Aç' : 'Giriş Yap')),
        ])),
      )),
    );
    user.dispose();
    pass.dispose();
    if (mounted) setState(() => _dirty());
  }

  /// Signed in: the session decides who you are. Legacy shared mode only:
  /// the picker (the server ignores it whenever a session exists).
  int? get _actingStaff => c.api.signedIn ? c.api.sessionEmployeeId : selectedStaff;

  Future<void> _send() async {
    if (sending || cart.isEmpty) return;
    if (c.api.loginRequired && !c.api.signedIn) {
      _message('Sipariş için giriş yapın.');
      unawaited(_login());
      return;
    }
    if (_actingStaff == null) {
      _message(c.api.signedIn ? 'Hesabınız bir personele bağlı değil. Windows › Kullanıcılar.'
          : 'Önce giriş yapın veya personel adınızı seçin.');
      return;
    }
    if (!c.online) {
      _message('Laptop bağlantısı kesildi. Sipariş sepeti korundu.');
      return;
    }
    _pendingRequest ??= {
      'requestId': requestId(),
      'expectedRevision': c.revision,
      'staffId': _actingStaff,
      'source': source,
      'table': source == 'Masa' ? tableNumber : null,
      if (targetOrderId != null && source == 'Masa')
        'orderId': targetOrderId,
      'pickupChannel': pickupChannel,
      if (source == 'Gel-Al')
        'customer': {
          'name': name.text.trim(),
          'phone': phone.text.trim(),
          'time': pickupTime.text.trim(),
        },
      'lines': cart.map((x) => x.asOrderLine()).toList(),
    };
    setState(() => sending = true);
    try {
      final number = await c.sendOrder(_pendingRequest!);
      if (!mounted) return;
      setState(() {
        cart.clear();
        targetOrderId = null;
        _pendingRequest = null;
        tab = 3;
      });
      _message('Sipariş #$number laptopa kaydedildi ✓');
    } catch (e) {
      if (!mounted) return;
      if ('$e'.contains('Başka cihaz')) {
        _pendingRequest = null;
        await c.refresh();
      }
      _message('Sipariş onayı alınamadı: $e. Aynı isteği yeniden deneyin.');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message), duration: const Duration(seconds: 4)));
  }

  Future<void> _showOrder(Json order) async {
    final lines = orderLines(order);
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.78),
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(orderLabel(order), style: const TextStyle(
                fontFamily: 'Bree', fontSize: 27)),
              const Divider(height: 22),
              for (final line in lines)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${line['qty'] ?? 1} × ${line['name'] ?? 'Ürün'}'),
                  subtitle: '${line['note'] ?? ''}'.trim().isEmpty
                      ? null : Text('${line['note']}'),
                ),
              const Divider(),
              Text('Toplam: ${money(orderTotal(order))}',
                style: const TextStyle(fontSize: 22,
                    fontWeight: FontWeight.w800)),
              if (order['source'] == 'Masa' && order['id'] is int)
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _target(order['table'] as int, order);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Bu Masaya Ürün Ekle'),
                  ),
                ),
            ],
          )),
        ),
      )),
    );
  }

  Widget _tablePage(double width) {
    final cols = width >= 1100 ? 5 : width >= 800 ? 4 :
        width >= 560 ? 3 : width >= 290 ? 2 : 1;
    return ListView(padding: const EdgeInsets.all(16), children: [
      _heading('Masa Planı', 'Masayı seçerek sipariş oluşturun'),
      const SizedBox(height: 16),
      GridView.count(
        crossAxisCount: cols,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 11,
        crossAxisSpacing: 11,
        mainAxisExtent: 136,
        children: [
          for (var n = 1; n <= 5; n++)
            Builder(builder: (context) {
              final o = c.orders.where((o) =>
                  o['source'] == 'Masa' && o['table'] == n).firstOrNull;
              return Card(
                color: o == null ? const Color(0xffe8f1e3)
                    : const Color(0xffffe3ac),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _chooseTable(n),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: FittedBox(fit: BoxFit.scaleDown,
                      child: Column(mainAxisSize: MainAxisSize.min,
                        children: [
                        const Icon(Icons.table_restaurant_outlined, size: 29),
                        Text('Masa $n', style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w800)),
                        Text(o == null ? 'Boş · Yeni sipariş'
                            : 'Dolu · ${money(orderTotal(o))}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12)),
                      ])),
                  ),
                ),
              );
            }),
        ],
      ),
      const SizedBox(height: 17),
      OutlinedButton.icon(
        onPressed: () => setState(() {
          source = 'Gel-Al';
          targetOrderId = null;
          tab = 1;
          _dirty();
        }),
        icon: const Icon(Icons.takeout_dining_outlined),
        label: const Text('Gel-Al Siparişi Oluştur'),
      ),
    ]);
  }

  Widget _menuPage(double width) {
    final items = c.products.where((p) {
      final text = '${p['name'] ?? ''}'.toLowerCase();
      final group = '${p['category'] ?? p['group'] ?? 'Diğer'}';
      return text.contains(query.toLowerCase()) &&
          (category == 'Tümü' || group == category);
    }).toList();
    final categories = {
      'Tümü',
      for (final p in c.products)
        '${p['category'] ?? p['group'] ?? 'Diğer'}',
    }.toList();
    final columns = width >= 1100 ? 4 : width >= 750 ? 3 :
        width >= 480 ? 2 : 1;
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 3),
        child: Column(children: [
          _heading('Ürünler', source == 'Masa'
              ? 'Masa $tableNumber ${targetOrderId == null ? '· Yeni' : '· Ek sipariş'}'
              : 'Gel-Al · Yeni sipariş'),
          const SizedBox(height: 11),
          TextField(
            decoration: const InputDecoration(
              hintText: 'Ürün ara…',
              prefixIcon: Icon(Icons.search),
              isDense: true),
            onChanged: (s) => setState(() => query = s),
          ),
          const SizedBox(height: 10),
          SizedBox(height: 48, child: ListView(
            scrollDirection: Axis.horizontal,
            children: [for (final group in categories)
              Padding(padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(group),
                  selected: group == category,
                  onSelected: (_) => setState(() => category = group))),
            ],
          )),
        ]),
      ),
      if (items.isEmpty)
        const Padding(padding: EdgeInsets.all(16),
          child: Center(child: Text('Ürün bulunamadı.')))
      else GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(13),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: 113,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10),
              itemCount: items.length,
              itemBuilder: (ctx, i) {
                final product = items[i];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(11),
                    child: Row(children: [
                      Expanded(child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${product['name']}', maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                          const SizedBox(height: 5),
                          Text(money(asCents(product['price'])),
                            style: const TextStyle(
                              color: NohutStyle.gold,
                              fontWeight: FontWeight.w800)),
                        ],
                      )),
                      const SizedBox(width: 6),
                      IconButton.filled(
                        tooltip: 'Sepete Ekle',
                        onPressed: () => _add(product),
                        icon: const Icon(Icons.add),
                      ),
                    ]),
                  ),
                );
              },
            ),
    ]);
  }

  Widget _cartPage(double width) {
    return ListView(padding: const EdgeInsets.all(15), children: [
      _heading('Sipariş Sepeti', '$count ürün'),
      const SizedBox(height: 14),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'Masa', label: Text('Masa')),
          ButtonSegment(value: 'Gel-Al', label: Text('Gel-Al')),
        ],
        selected: {source},
        onSelectionChanged: (x) => setState(() {
          source = x.first;
          targetOrderId = null;
          _dirty();
        }),
      ),
      const SizedBox(height: 14),
      if (source == 'Masa')
        DropdownButtonFormField<int>(
          value: tableNumber,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Masa'),
          items: [for (var n = 1; n <= 5; n++)
            DropdownMenuItem(value: n, child: Text('Masa $n'))],
          onChanged: (n) {
            if (n == null) return;
            final active = c.orders.where((o) =>
                o['source'] == 'Masa' && o['table'] == n).firstOrNull;
            setState(() {
              tableNumber = n;
              targetOrderId = active?['id'] as int?;
              _dirty();
            });
          },
        ),
      if (source == 'Gel-Al') ...[
        DropdownButtonFormField<String>(
          value: pickupChannel,
          decoration: const InputDecoration(labelText: 'Teslim alma'),
          items: const [
            DropdownMenuItem(value: 'Tezgahtan', child: Text('Tezgahtan')),
            DropdownMenuItem(value: 'Telefon', child: Text('Telefon')),
          ],
          onChanged: (s) => setState(() {
            pickupChannel = s ?? 'Tezgahtan';
            _dirty();
          }),
        ),
        const SizedBox(height: 9),
        TextField(controller: name,
          decoration: const InputDecoration(labelText: 'Müşteri adı')),
        const SizedBox(height: 8),
        TextField(controller: phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Telefon')),
        const SizedBox(height: 8),
        TextField(controller: pickupTime,
          keyboardType: TextInputType.datetime,
          decoration: const InputDecoration(labelText: 'Teslim saati (isteğe bağlı)')),
      ],
      const SizedBox(height: 14),
      if (cart.isEmpty) Card(child: Padding(
        padding: const EdgeInsets.all(26),
        child: Center(child: Column(children: [
          const Icon(Icons.shopping_basket_outlined,
            size: 38, color: NohutStyle.muted),
          const Text('Sepet henüz boş'),
          TextButton.icon(
            onPressed: () => setState(() => tab = 1),
            icon: const Icon(Icons.add),
            label: const Text('Ürün Ekle')),
        ])),
      )),
      for (final line in cart)
        Card(child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              Expanded(child: Text(line.name, style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 17))),
              Text(money(line.totalCents),
                style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            Row(children: [
              IconButton.outlined(
                onPressed: () => setState(() {
                  _dirty();
                  line.qty--;
                  if (line.qty == 0) cart.remove(line);
                }), icon: const Icon(Icons.remove)),
              Text('${line.qty}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
              IconButton.outlined(
                onPressed: () => setState(() {
                  _dirty();
                  line.qty++;
                }), icon: const Icon(Icons.add)),
              const Spacer(),
              TextButton.icon(onPressed: () => _edit(line),
                icon: const Icon(Icons.edit_note_outlined),
                label: const Text('Not / Malzeme')),
            ]),
          ]),
        )),
      const Divider(height: 24),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Toplam', style: TextStyle(fontSize: 21)),
        Text(money(total), style: const TextStyle(
          fontWeight: FontWeight.w800, fontSize: 24,
          color: NohutStyle.green)),
      ]),
      const SizedBox(height: 13),
      FilledButton.icon(
        onPressed: sending || cart.isEmpty || !c.online ? null : _send,
        icon: sending
            ? const SizedBox(height: 17, width: 17,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.send),
        label: const Text('Siparişi Laptopa Kaydet')),
      const SizedBox(height: 8),
      const Text('Yalnızca Windows POS siparişi onayladıktan sonra '
        'kayıt başarılı sayılır. Bağlantı kesilirse sepet korunur.',
        style: TextStyle(fontSize: 12, color: NohutStyle.muted)),
    ]);
  }

  Widget _ordersPage(double width) {
    final platforms = rows(c.state['trendyolGoOrders']);
    return ListView(padding: const EdgeInsets.all(14), children: [
      _heading('Açık Siparişler', 'Laptop ile ortak sipariş listesi'),
      const SizedBox(height: 10),
      if (c.orders.isEmpty && platforms.isEmpty)
        const Card(child: Padding(padding: EdgeInsets.all(22),
          child: Text('Açık sipariş yok.'))),
      for (final order in c.orders)
        Card(child: ListTile(
          title: Text(orderLabel(order),
            style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('${money(orderTotal(order))} · ${order['serviceStatus'] ?? 'Açık'}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showOrder(order),
        )),
      if (platforms.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Trendyol Go · Salt okunur',
            style: TextStyle(fontWeight: FontWeight.w800))),
        for (final order in platforms)
          Card(child: ListTile(
            title: Text('#${order['orderNumber']}'),
            subtitle: Text('${order['status']} · ${money((order['totalCents'] as num?)?.toInt() ?? 0)}'),
            leading: const Icon(Icons.delivery_dining_outlined),
          )),
      ],
    ]);
  }

  Widget _settingsPage() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      _heading('Bağlantı', 'Android yerel uygulama'),
      const SizedBox(height: 13),
      Card(child: Column(children: [
        ListTile(
          leading: Icon(c.online ? Icons.wifi : Icons.wifi_off,
            color: c.online ? Colors.green : Colors.orange),
          title: Text(c.online ? 'Laptop bağlı' : 'Bağlantı yok'),
          subtitle: Text(c.api.host ?? 'Sunucu bulunamadı'),
        ),
        if (c.error != null)
          ListTile(title: Text(c.error!,
            style: const TextStyle(color: Colors.red))),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.refresh),
          title: const Text('Bağlantıyı Yenile'),
          onTap: () => c.refresh()),
        ListTile(leading: const Icon(Icons.notifications_active_outlined),
          title: const Text('Bildirim İznini Kontrol Et'),
          onTap: () async {
            await c.notifications.init();
            _message('Android bildirim izinlerini kontrol edin.');
          }),
        ListTile(
          leading: const Icon(Icons.phonelink_erase_outlined,
            color: Colors.red),
          title: const Text('Bu Cihazın Bağlantısını Unut'),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Cihaz eşleştirmesi silinsin mi?'),
                content: const Text('Tekrar bağlanmak için QR ve yeni PIN gerekecek.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Vazgeç')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Eşleştirmeyi Sil')),
                ],
              ));
            if (ok == true) {
              await c.api.forget();
              widget.onUnpair();
            }
          },
        ),
      ])),
      const SizedBox(height: 10),
      const Text('Siparişler restoran Wi-Fi ağında Windows POS’a '
        'kaydedilir. Uygulama kapalıyken bulut push bildirimi yoktur; '
        'Android açıkken yeni personel siparişleri bildirilir.',
        style: TextStyle(fontSize: 12, color: NohutStyle.muted)),
    ]);
  }

  Widget _heading(String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(
        fontSize: 26, fontFamily: 'Bree', color: NohutStyle.green)),
      Text(subtitle, style:
        const TextStyle(fontSize: 13, color: NohutStyle.muted)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final width = MediaQuery.sizeOf(context).width;
        final height = MediaQuery.sizeOf(context).height;
        final wide = width >= 720 && height >= 600;
        final contentWidth = wide ? width - 96 : width;
        final hasDrafts = !widget.ownerMode && c.api.serverId != null;
        final selected = c.employees.any((e) => e['id'] == selectedStaff)
            ? selectedStaff : null;
        final destinations = <NavigationDestination>[
          const NavigationDestination(icon: Icon(Icons.table_restaurant_outlined),
            selectedIcon: Icon(Icons.table_restaurant), label: 'Masalar'),
          const NavigationDestination(icon: Icon(Icons.restaurant_menu),
            label: 'Ürünler'),
          NavigationDestination(icon: Badge(
            isLabelVisible: count > 0, label: Text('$count'),
            child: const Icon(Icons.shopping_cart_outlined)),
            label: 'Sepet'),
          const NavigationDestination(icon: Icon(Icons.receipt_long_outlined),
            label: 'Siparişler'),
          if (!widget.ownerMode)
            const NavigationDestination(icon: Icon(Icons.settings_outlined),
              label: 'Bağlantı'),
          if (hasDrafts)
            const NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined),
              label: 'Gider'),
        ];
        final screen = switch (tab) {
          0 => _tablePage(contentWidth),
          1 => _menuPage(contentWidth),
          2 => _cartPage(contentWidth),
          3 => _ordersPage(contentWidth),
          5 when hasDrafts => ExpenseDraftPage(
            key: ValueKey(c.api.serverId),
            store: ExpenseDraftStore.forServer(c.api.serverId!)),
          _ => _settingsPage(),
        };
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: height < 500 ? 56 : 75,
            title: NohutBrandHeader(
              subtitle: c.online ? '● Laptop bağlı' : '● Bağlantı bekleniyor'),
            actions: [
              if (widget.ownerMode)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Center(child: Text(widget.ownerName ?? 'İşletme sahibi', overflow: TextOverflow.ellipsis)))
              else if (c.api.signedIn) ...[
                if (c.api.sessionEmployeeId != null)
                  IconButton(tooltip: 'Mesai ve Maaşım', onPressed: _openWork,
                    icon: const Icon(Icons.badge_outlined)),
                PopupMenuButton<String>(
                  tooltip: 'Hesabım',
                  onSelected: (v) async {
                    if (v == 'work') _openWork();
                    if (v == 'logout') {
                      await c.api.logout();
                      if (mounted) setState(() {});
                    }
                  },
                  itemBuilder: (_) => [
                    if (c.api.sessionEmployeeId != null)
                      const PopupMenuItem(value: 'work', child: Text('Mesai ve Maaşım')),
                    const PopupMenuItem(value: 'logout', child: Text('Çıkış Yap')),
                  ],
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.verified_user_outlined, size: 20),
                      const SizedBox(width: 6),
                      ConstrainedBox(constraints: BoxConstraints(maxWidth: wide ? 180 : 96),
                        child: Text(_signedInLabel(), overflow: TextOverflow.ellipsis)),
                    ])),
                ),
              ]
              else if (c.api.loginRequired)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: FilledButton.tonal(onPressed: _login, child: const Text('Giriş Yap')))
              else if (selected != null || c.employees.isNotEmpty)
                SizedBox(width: wide ? 170 : width < 360 ? 88 : 110,
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: selected,
                    hint: const Text('Personel', overflow: TextOverflow.ellipsis),
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final e in c.employees)
                        DropdownMenuItem(value: e['id'] as int,
                          child: Text('${e['name']}',
                            overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      setState(() {
                        selectedStaff = id;
                        _dirty();
                      });
                      c.api.saveEmployee(id);
                    },
                  ),
                ),
              if (!widget.ownerMode && !c.api.signedIn && !c.api.loginRequired && c.api.paired)
                IconButton(tooltip: 'Giriş Yap', onPressed: _login, icon: const Icon(Icons.login)),
              IconButton(
                tooltip: 'Yenile',
                onPressed: c.refresh,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: Row(children: [
            if (wide)
              NavigationRail(
                backgroundColor: NohutStyle.card,
                selectedIndex: tab,
                onDestinationSelected: (n) => setState(() => tab = n),
                labelType: height < 760 ? NavigationRailLabelType.selected : NavigationRailLabelType.all,
                destinations: [
                  for (final d in destinations)
                    NavigationRailDestination(
                      icon: d.icon,
                      selectedIcon: d.selectedIcon,
                      label: Text(d.label)),
                ],
              ),
            Expanded(child: Column(children: [
              if (!c.online && tab != 5)
                MaterialBanner(
                  backgroundColor: const Color(0xffffe9c8),
                  content: const Text('Laptop çevrimdışı · Sepet korunuyor'),
                  actions: [TextButton(
                    onPressed: c.refresh, child: const Text('Yenile'))],
                ),
              Expanded(child: screen),
            ])),
          ]),
          bottomNavigationBar: wide ? null : NavigationBar(
            height: height < 500 ? 56 : width < 380 ? 65 : 72,
            labelBehavior: (width < 360 || (hasDrafts && width < 600))
              ? NavigationDestinationLabelBehavior.onlyShowSelected
              : NavigationDestinationLabelBehavior.alwaysShow,
            selectedIndex: tab,
            onDestinationSelected: (n) => setState(() => tab = n),
            destinations: destinations,
          ),
        );
      },
    );
  }
}
