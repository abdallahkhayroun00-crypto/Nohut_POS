import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/services.dart';

import 'expense_drafts.dart';
import 'performance_page.dart';
import 'personel_dashboard.dart';
import 'activation_page.dart';
import 'staff_expense_page.dart';
import 'models.dart';
import 'pos_api.dart';
import 'style.dart';
import 'menu_admin_page.dart';
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
    // §24.3: Personel opens on Ana Sayfa. Owner mode keeps Masalar.
    if (!widget.ownerMode) tab = _home;
  }

  /// Page ids. The staff bottom bar shows Ana Sayfa / Masalar / Sipariş /
  /// Siparişler / Daha Fazla; Ürünler sits under Sipariş and Gider under
  /// Daha Fazla.
  static const _home = 6;

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

  void _openWork([int initialTab = 0]) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WorkPage(api: c.api, initialTab: initialTab)));

  /// PIN for this phone. Windows checks the password and the PIN rules.
  Future<void> _changePin() async {
    final password = TextEditingController(), pin = TextEditingController();
    String? error;
    var busy = false;
    final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.viewInsetsOf(ctx).bottom + 22),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('PIN Değiştir', style: Theme.of(ctx).textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text('Güvenlik için hesap şifreniz de istenir.', style: TextStyle(color: ctx.nohut.muted)),
          const SizedBox(height: 14),
          TextField(key: const ValueKey('pin-password'), controller: password, obscureText: true,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(labelText: 'Şifre')),
          const SizedBox(height: 10),
          TextField(key: const ValueKey('pin-new'), controller: pin, obscureText: true, maxLength: 5,
            keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Yeni PIN (5 hane)')),
          if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Text(error!, style: TextStyle(color: ctx.nohut.danger))),
          FilledButton(onPressed: busy ? null : () async {
            if (password.text.isEmpty || pin.text.length != 5) {
              setSheet(() => error = 'Şifrenizi ve 5 haneli yeni PIN’i girin.');
              return;
            }
            setSheet(() { busy = true; error = null; });
            try {
              await c.api.setPin(pin.text, password.text);
              if (ctx.mounted) Navigator.pop(ctx, true);
            } on FormatException catch (e) {
              setSheet(() { busy = false; error = e.message; });
            } catch (_) {
              setSheet(() { busy = false; error = 'Windows POS’a ulaşılamadı.'; });
            }
          }, child: const Text('PIN Kaydet')),
        ]),
      )));
    // Let the sheet finish closing before its fields go away.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    password.dispose();
    pin.dispose();
    if (ok == true && mounted) _message('PIN kaydedildi.');
  }

  Widget _homePage() {
    final busy = {for (final o in c.orders) if (o['source'] == 'Masa') o['table']}.length;
    return PersonelDashboard(
      key: ValueKey('home-${c.api.sessionEmployeeId}'),
      api: c.api,
      name: c.api.signedIn ? _signedInLabel() : null,
      busyTables: busy,
      openPickups: c.orders.where((o) => o['source'] == 'Gel-Al').length,
      openOrders: c.orders.length,
      onTables: () => setState(() => tab = 0),
      onNewOrder: () => setState(() => tab = 1),
      onOrders: () => setState(() => tab = 3),
      onWork: _openWork,
      onLogin: _login,
      online: c.online,
    );
  }

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
    var busy = false, activate = false;
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
          if (!locked) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              key: const ValueKey('open-activation'),
              onPressed: busy ? null : () { activate = true; Navigator.pop(sheet); },
              icon: const Icon(Icons.key_outlined),
              label: const Text('İlk kez mi? Aktivasyon kodum var')),
          ],
        ])),
      )),
    );
    user.dispose();
    pass.dispose();
    if (activate && mounted) {
      await Navigator.of(context).push(MaterialPageRoute<bool>(
          builder: (_) => ActivationPage(api: c.api)));
    }
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
    final cols = width >= 1100 ? 5 : width >= 800 ? 4 : width >= 330 ? 3 : 2;
    final busy = [for (var n = 1; n <= 5; n++)
      if (c.orders.any((o) => o['source'] == 'Masa' && o['table'] == n)) n];
    final pickups = c.orders.where((o) => o['source'] == 'Gel-Al').length;
    final nc = context.nohut, scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      _heading('Masa Planı', 'Masayı seçerek sipariş oluşturun'),
      const SizedBox(height: 12),
      NohutMetricGrid(minTileWidth: 140, children: [
        NohutMetric(label: 'Dolu masa', value: '${busy.length} / 5', icon: Icons.table_restaurant_outlined),
        NohutMetric(label: 'Açık Gel-Al', value: '$pickups', icon: Icons.takeout_dining_outlined),
      ]),
      const SizedBox(height: 14),
      GridView.count(
        crossAxisCount: cols,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.02,
        children: [
          for (var n = 1; n <= 5; n++)
            Builder(builder: (context) {
              final o = c.orders.where((o) =>
                  o['source'] == 'Masa' && o['table'] == n).firstOrNull;
              final taken = o != null;
              return Material(
                color: taken ? scheme.secondaryContainer : nc.card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: taken ? scheme.secondary : nc.outline, width: taken ? 1.4 : 1)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _chooseTable(n),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(Icons.table_restaurant_outlined, size: 20,
                          color: taken ? scheme.onSecondaryContainer : nc.muted),
                        const Spacer(),
                        Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle,
                          color: taken ? scheme.secondary : nc.success)),
                      ]),
                      const Spacer(),
                      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
                        child: Text('Masa $n', style: TextStyle(fontFamily: 'Bree', fontSize: 21,
                          color: taken ? scheme.onSecondaryContainer : nc.heading))),
                      Text(taken ? money(orderTotal(o)) : 'Boş',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                          color: taken ? scheme.onSecondaryContainer : nc.muted)),
                    ]),
                  ),
                ),
              );
            }),
        ],
      ),
      const SizedBox(height: 14),
      FilledButton.tonalIcon(
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
    final categories = ['Tümü', ...menuCategoriesOf(c.products)];
    final columns = width >= 1100 ? 4 : width >= 750 ? 3 :
        width >= 480 ? 2 : 1;
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 3),
        child: Column(children: [
          _heading('Ürünler', source == 'Masa'
              ? 'Masa $tableNumber ${targetOrderId == null ? '· Yeni' : '· Ek sipariş'}'
              : 'Gel-Al · Yeni sipariş'),
          // Staff reach Ürünler and Sepet from one Sipariş tab.
          if (!widget.ownerMode && count > 0) ...[
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: FilledButton.tonal(
              key: const ValueKey('go-cart'),
              onPressed: () {
                // "sepete eklendi" notes would cover the send button.
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                setState(() => tab = 2);
              },
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.shopping_cart_outlined, size: 18),
                const SizedBox(width: 8),
                Flexible(child: Text('Sepete Git · $count ürün · ${money(total)}',
                    overflow: TextOverflow.ellipsis)),
              ]))),
          ],
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
                  label: Text(menuCategoryLabel(group)),
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
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
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

  Widget _cartLine(CartEntry line) {
    final nc = context.nohut;
    final details = [
      if (line.removed.isNotEmpty) 'Çıkar: ${line.removed.join(', ')}',
      if (line.note.trim().isNotEmpty) line.note.trim(),
    ];
    return Card(margin: const EdgeInsets.only(bottom: 8), child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(line.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16.5)),
            const SizedBox(height: 2),
            Text('${line.qty} × ${money(line.unitCents)}',
              style: TextStyle(color: nc.muted, fontSize: 13)),
          ])),
          Padding(padding: const EdgeInsets.only(right: 6), child: Text(money(line.totalCents),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
        ]),
        if (details.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(details.join(' · '),
            key: ValueKey('cart-details-${line.productId}'),
            style: TextStyle(color: nc.heading, fontSize: 13, fontWeight: FontWeight.w600))),
        const SizedBox(height: 6),
        Row(children: [
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(24)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                key: ValueKey('cart-minus-${line.productId}'),
                tooltip: line.qty == 1 ? 'Sepetten çıkar' : 'Bir azalt',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  _dirty();
                  line.qty--;
                  if (line.qty == 0) cart.remove(line);
                }),
                icon: Icon(line.qty == 1 ? Icons.delete_outline : Icons.remove)),
              SizedBox(width: 28, child: Text('${line.qty}', textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              IconButton(
                key: ValueKey('cart-plus-${line.productId}'),
                tooltip: 'Bir artır',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  _dirty();
                  line.qty++;
                }),
                icon: const Icon(Icons.add)),
            ])),
          Expanded(child: Align(alignment: Alignment.centerRight, child: TextButton.icon(
            onPressed: () => _edit(line),
            icon: const Icon(Icons.edit_note_outlined),
            label: Text(details.isEmpty ? 'Not / Malzeme' : 'Düzenle', overflow: TextOverflow.ellipsis)))),
        ]),
      ]),
    ));
  }

  Widget _cartPage(double width) {
    final nc = context.nohut;
    final addition = source == 'Masa' && targetOrderId != null;
    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(15, 15, 15, 8), children: [
      Row(children: [
        Expanded(child: _heading('Sipariş Sepeti', '$count ürün')),
        if (!widget.ownerMode && cart.isNotEmpty)
          TextButton.icon(key: const ValueKey('add-more'), onPressed: () => setState(() => tab = 1),
            icon: const Icon(Icons.add), label: const Text('Ürün Ekle')),
      ]),
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
      if (addition)
        Padding(padding: const EdgeInsets.only(top: 10), child: Row(children: [
          Icon(Icons.info_outline, size: 18, color: nc.heading),
          const SizedBox(width: 8),
          Expanded(child: Text('Masa $tableNumber açık: ürünler mevcut siparişe ek sipariş olarak eklenir.',
            key: const ValueKey('cart-addition-hint'),
            style: TextStyle(color: nc.heading, fontSize: 13, fontWeight: FontWeight.w600))),
        ])),
      const SizedBox(height: 14),
      if (cart.isEmpty) Card(child: NohutEmpty(
        icon: Icons.shopping_basket_outlined, message: 'Sepet henüz boş',
        action: 'Ürün Ekle', onAction: () => setState(() => tab = 1))),
      for (final line in cart) _cartLine(line),
      ])),
      DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
        child: SafeArea(top: false, child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(
                source == 'Masa' ? 'Masa $tableNumber${addition ? ' · Ek sipariş' : ''} · $count ürün'
                    : 'Gel-Al · $pickupChannel · $count ürün',
                style: TextStyle(color: nc.muted, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              Text(money(total), key: const ValueKey('cart-total'), style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 22, color: nc.heading)),
            ]),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('cart-send'),
              onPressed: sending || cart.isEmpty || !c.online ? null : _send,
              icon: sending
                  ? const SizedBox(height: 17, width: 17,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: const Text('Siparişi Laptopa Kaydet')),
            if (MediaQuery.sizeOf(context).height >= 700) ...[const SizedBox(height: 6),
            Text(c.online ? 'Windows POS onaylayınca kaydedilir. Bağlantı kesilirse sepet korunur.'
                : 'Laptop bağlantısı yok. Sepet korunuyor; bağlanınca gönderebilirsiniz.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: nc.muted))],
          ]),
        )),
      ),
    ]);
  }

  Widget _ordersPage(double width) {
    final platforms = rows(c.state['trendyolGoOrders']);
    return ListView(padding: const EdgeInsets.all(14), children: [
      _heading('Açık Siparişler', 'Laptop ile ortak sipariş listesi'),
      const SizedBox(height: 10),
      if (c.orders.isEmpty && platforms.isEmpty)
        const Card(child: NohutEmpty(icon: Icons.receipt_long_outlined, message: 'Açık sipariş yok.')),
      for (final order in c.orders)
        Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(
          leading: Icon(order['source'] == 'Masa'
              ? Icons.table_restaurant_outlined : Icons.takeout_dining_outlined),
          title: Text(orderLabel(order),
            style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text([
            money(orderTotal(order)),
            '${orderLines(order).fold<int>(0, (n, l) => n + ((l['qty'] as num?)?.toInt() ?? 0))} ürün',
            '${order['serviceStatus'] ?? 'Açık'}',
          ].join(' · ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showOrder(order),
        )),
      if (platforms.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Trendyol Go · Salt okunur',
            style: TextStyle(fontWeight: FontWeight.w800))),
        for (final order in platforms)
          Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(
            title: Text('#${order['orderNumber']}'),
            subtitle: Text('${order['status']} · ${money((order['totalCents'] as num?)?.toInt() ?? 0)}'),
            leading: const Icon(Icons.delivery_dining_outlined),
          )),
      ],
    ]);
  }

  Widget _settingsPage({required bool hasDrafts}) {
    final canWork = c.api.signedIn && c.api.sessionEmployeeId != null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      _heading(widget.ownerMode ? 'Hesap ve Bağlantı' : 'Daha Fazla', 'Android yerel uygulama'),
      if (!widget.ownerMode && (canWork || hasDrafts)) ...[
        const NohutSection('Çalışmam'),
        Card(child: Column(children: [
          if (canWork) ...[
            ListTile(leading: const Icon(Icons.timer_outlined), title: const Text('Mesailerim'),
              trailing: const Icon(Icons.chevron_right), onTap: () => _openWork(0)),
            ListTile(leading: const Icon(Icons.calendar_month_outlined), title: const Text('Vardiyalarım'),
              trailing: const Icon(Icons.chevron_right), onTap: () => _openWork(1)),
            ListTile(leading: const Icon(Icons.payments_outlined), title: const Text('Maaş & Avans'),
              trailing: const Icon(Icons.chevron_right), onTap: () => _openWork(2)),
            ListTile(key: const ValueKey('open-performance'),
              leading: const Icon(Icons.insights_outlined), title: const Text('Performansım'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => PerformancePage(api: c.api)))),
          ],
          // With the explicit grant the signed-in person submits to Windows
          // (own entries only); otherwise the existing paired outbox stays.
          if (canSubmitExpenses(c.api))
            ListTile(key: const ValueKey('open-staff-expense'),
              leading: const Icon(Icons.account_balance_wallet_outlined), title: const Text('Hızlı Gider'),
              subtitle: const Text('Alışveriş gideri ekle · kendi kayıtlarım'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => StaffExpensePage(api: c.api))))
          else if (hasDrafts)
            ListTile(leading: const Icon(Icons.account_balance_wallet_outlined), title: const Text('Giderler'),
              subtitle: const Text('Hızlı Gider Ekle'),
              trailing: const Icon(Icons.chevron_right), onTap: () => setState(() => tab = 5)),
        ])),
      ],
      if (!widget.ownerMode) ...[
        const NohutSection('Menü'),
        Card(child: ListTile(
          key: const ValueKey('more-menu-admin'),
          leading: const Icon(Icons.restaurant_menu_outlined),
          title: const Text('Menü Yönetimi'),
          subtitle: Text(c.api.signedIn ? 'Stok, fiyat ve QR görünürlüğü · yetkinize göre'
              : 'Kendi hesabınızla giriş yapın'),
          trailing: const Icon(Icons.chevron_right),
          onTap: c.api.signedIn ? () => Navigator.of(context).push(menuAdminRoute(c.api)) : _login)),
        const NohutSection('Hesabım'),
        Card(child: Column(children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(c.api.signedIn ? _signedInLabel() : 'Giriş yapılmadı'),
            subtitle: Text(c.api.signedIn ? 'Kimliğiniz oturumdan gelir · ${c.api.sessionUser}'
                : 'Mesai ve maaş için kendi hesabınızla giriş yapın.'),
          ),
          if (c.api.signedIn) ...[
            const Divider(),
            ListTile(key: const ValueKey('change-pin'), leading: const Icon(Icons.pin_outlined),
              title: const Text('PIN Değiştir'), subtitle: const Text('Kilit açmak için 5 haneli PIN · şifreniz istenir'),
              trailing: const Icon(Icons.chevron_right), onTap: _changePin),
          ],
          const Divider(),
          if (c.api.signedIn)
            ListTile(leading: const Icon(Icons.logout), title: const Text('Çıkış Yap'),
              onTap: () async { await c.api.logout(); if (mounted) setState(() {}); })
          else
            ListTile(leading: const Icon(Icons.login), title: const Text('Giriş Yap'), onTap: _login),
        ])),
      ],
      const NohutSection('Bağlantı'),
      Card(child: Column(children: [
        ListTile(
          leading: Icon(c.online ? Icons.wifi : Icons.wifi_off,
            color: c.online ? context.nohut.success : context.nohut.warning),
          title: Text(c.online ? 'Laptop bağlı' : 'Bağlantı yok'),
          subtitle: Text(c.api.host ?? 'Sunucu bulunamadı'),
          trailing: NohutPill(c.online ? 'Bağlı' : 'Bağlantı yok',
            tone: c.online ? NohutTone.success : NohutTone.danger),
        ),
        if (c.error != null)
          ListTile(title: Text(c.error!,
            style: TextStyle(color: context.nohut.danger))),
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
          leading: Icon(Icons.phonelink_erase_outlined,
            color: context.nohut.danger),
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
      Text('Siparişler restoran Wi-Fi ağında Windows POS’a '
        'kaydedilir. Uygulama kapalıyken bulut push bildirimi yoktur; '
        'Android açıkken yeni personel siparişleri bildirilir.',
        style: TextStyle(fontSize: 12, color: context.nohut.muted)),
    ]);
  }

  Widget _heading(String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.headlineSmall),
      Text(subtitle, style:
        TextStyle(fontSize: 13.5, color: context.nohut.muted)),
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
        final cartIcon = Badge(isLabelVisible: count > 0, label: Text('$count'),
            child: const Icon(Icons.shopping_cart_outlined));
        // Each entry: (page id, destination). Owner mode keeps the old bar.
        final nav = <(int, NavigationDestination)>[
          if (!widget.ownerMode)
            (_home, const NavigationDestination(icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home), label: 'Ana Sayfa')),
          (0, const NavigationDestination(icon: Icon(Icons.table_restaurant_outlined),
            selectedIcon: Icon(Icons.table_restaurant), label: 'Masalar')),
          if (widget.ownerMode) ...[
            (1, const NavigationDestination(icon: Icon(Icons.restaurant_menu), label: 'Ürünler')),
            (2, NavigationDestination(icon: cartIcon, label: 'Sepet')),
          ] else
            (2, NavigationDestination(icon: cartIcon, label: 'Sipariş')),
          (3, const NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Siparişler')),
          if (!widget.ownerMode)
            (4, const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'Daha Fazla')),
        ];
        final destinations = [for (final n in nav) n.$2];
        // Ürünler belongs to Sipariş and Gider to Daha Fazla on the staff bar.
        final shown = widget.ownerMode ? tab
            : tab == 1 ? 2 : tab == 5 ? 4 : tab;
        final selectedIndex = nav.indexWhere((n) => n.$1 == shown).clamp(0, nav.length - 1);
        void go(int i) {
          if (nav[i].$1 == 2) ScaffoldMessenger.of(context).hideCurrentSnackBar();
          setState(() => tab = nav[i].$1);
        }
        final screen = switch (tab) {
          _home when !widget.ownerMode => _homePage(),
          0 => _tablePage(contentWidth),
          1 => _menuPage(contentWidth),
          2 => _cartPage(contentWidth),
          3 => _ordersPage(contentWidth),
          5 when hasDrafts => ExpenseDraftPage(
            key: ValueKey(c.api.serverId),
            store: ExpenseDraftStore.forServer(c.api.serverId!)),
          _ => _settingsPage(hasDrafts: hasDrafts),
        };
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: height < 500 ? 56 : 64,
            title: NohutBrandHeader(online: c.online,
              subtitle: c.online ? 'Laptop bağlı' : 'Bağlantı bekleniyor'),
            actions: [
              if (widget.ownerMode)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Center(child: Text(widget.ownerName ?? 'İşletme sahibi', overflow: TextOverflow.ellipsis)))
              else if (c.api.signedIn) ...[
                if (c.api.sessionEmployeeId != null)
                  IconButton(tooltip: 'Mesai ve Maaşım', onPressed: () => _openWork(),
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
                      // Compact phones: the icon alone, so the brand stays readable.
                      if (width >= 380) ...[
                        const SizedBox(width: 6),
                        ConstrainedBox(constraints: BoxConstraints(maxWidth: wide ? 180 : 96),
                          child: Text(_signedInLabel(), overflow: TextOverflow.ellipsis)),
                      ],
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
                selectedIndex: selectedIndex,
                onDestinationSelected: go,
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
                  content: const Text('Laptop çevrimdışı · Sepet korunuyor',
                    style: TextStyle(fontFamily: 'Barlow', fontWeight: FontWeight.w700)),
                  actions: [TextButton(
                    onPressed: c.refresh, child: const Text('Yenile'))],
                ),
              // Keyed so each tab starts at its own top instead of inheriting
              // the previous tab's scroll offset.
              Expanded(child: KeyedSubtree(key: ValueKey('page-$tab'), child: screen)),
            ])),
          ]),
          // Large system text: labels scale at most 1.15× so they never wrap.
          // Labels always visible (owner, relay 7226986975); narrow phones use a
          // smaller label so five fit at 320 dp. NavigationBar keeps the
          // system gesture area clear (bottom safe area).
          bottomNavigationBar: wide ? null : MediaQuery.withClampedTextScaling(maxScaleFactor: 1.15, child: NavigationBarTheme(
            data: NavigationBarTheme.of(context).copyWith(labelTextStyle: WidgetStateProperty.resolveWith((st) =>
                TextStyle(fontFamily: 'Barlow', fontSize: width < 360 ? 11 : 12.5,
                  fontWeight: st.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w600))),
            child: NavigationBar(
            height: height < 500 ? 56 : 68,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            selectedIndex: selectedIndex,
            onDestinationSelected: go,
            destinations: destinations,
          ))),
        );
      },
    );
  }
}
