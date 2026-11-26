part of 'main.dart';

class _OrderComposer extends StatefulWidget {
  const _OrderComposer({
    required this.products,
    required this.employees,
    required this.customers,
    this.table,
    this.originalOrder,
    this.adding = false,
    this.pickupOnly = false,
    this.tableOrders = const {},
    this.onSubmit,
    this.refreshProducts,
    this.refreshTables,
  });
  final List<Product> products;
  final List<Json> employees;
  final List<Json> customers;
  final int? table;
  final Json? originalOrder;
  final bool adding, pickupOnly;
  final Map<int, Json> tableOrders;
  final bool Function(OrderRequest)? onSubmit;
  final List<Product> Function()? refreshProducts;
  final Map<int, Json> Function()? refreshTables;
  @override
  State<_OrderComposer> createState() => _OrderComposerState();
}

class _OrderComposerState extends State<_OrderComposer> {
  // Every cart row is independent: two wraps may have different notes.
  final List<Json> draft = [];
  Json pickupCustomer = {};
  String category = 'all', search = '', source = 'Masa', pickup = 'Tezgahtan';
  int? table;
  int? selectedEmployeeId;
  int nextLine = 0;
  String? saveError;
  late List<Product> products;
  late Map<int, Json> tableOrders;
  @override
  void initState() {
    super.initState();
    products = widget.products;
    tableOrders = widget.tableOrders;
    table = widget.table;
    if (widget.pickupOnly || (widget.adding && table == null))
      source = 'Gel-Al';
  }


  Future<void> editPickupCustomer() async {
    final name = TextEditingController(text: (pickupCustomer['name'] ?? '').toString());
    final phone = TextEditingController(text: (pickupCustomer['phone'] ?? '').toString());
    final pickupTime = TextEditingController(text: (pickupCustomer['time'] ?? '').toString());
    int? customerId = pickupCustomer['id'] as int?;
    bool save = pickupCustomer['saveCustomer'] == true;
    String activeSearch = '';
    final selected = await showDialog<Json>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) {
          final needle = activeSearch.trim().toLowerCase();
          final digits = customerPhoneKey(needle);
          final suggestions = needle.length < 2 ? <Json>[] : widget.customers
              .where((c) =>
                  (c['name'] ?? '').toString().toLowerCase().contains(needle) ||
                  (digits.isNotEmpty &&
                      customerPhoneKey((c['phone'] ?? '').toString())
                          .contains(digits)))
              .take(5).toList();
          return AlertDialog(
            title: const Text('Gel-Al Bilgileri'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Ad',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      onChanged: (v) => update(() {
                        activeSearch = v;
                        customerId = null;
                      }),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Telefon',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      onChanged: (v) => update(() {
                        activeSearch = v;
                        customerId = null;
                      }),
                    ),
                    if (suggestions.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Kayıtlı müşteriler',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      for (final customer in suggestions)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.history),
                          title: Text((customer['name'] ?? '').toString()),
                          subtitle: Text((customer['phone'] ?? '').toString()),
                          onTap: () => update(() {
                            name.text = (customer['name'] ?? '').toString();
                            phone.text = (customer['phone'] ?? '').toString();
                            customerId = customer['id'] as int?;
                            activeSearch = '';
                            save = false;
                          }),
                        ),
                    ],
                    if (customerId != null)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Kayıtlı müşteri seçildi',
                            style: TextStyle(color: Colors.green)),
                      ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: pickupTime,
                      decoration: const InputDecoration(
                        labelText: 'Teslim alma saati',
                        prefixIcon: Icon(Icons.schedule_outlined),
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: save,
                      title: const Text('Müşteriyi Kaydet'),
                      subtitle: const Text('Bir sonraki Gel-Al siparişinde ad veya telefon ile bulun. Yalnızca bu bilgisayara kaydedilir.'),
                      onChanged: (v) => update(() => save = v ?? false),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Vazgeç'),
              ),
              FilledButton(
                onPressed: () {
                  if ((save || customerId != null) && name.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Müşteri adı gerekli.')),
                    );
                    return;
                  }
                  Navigator.pop(dialogContext, <String, dynamic>{
                    'name': name.text.trim(),
                    'phone': phone.text.trim(),
                    'time': pickupTime.text.trim(),
                    if (customerId != null) 'id': customerId,
                    if (save) 'saveCustomer': true,
                  });
                },
                child: const Text('Kaydet'),
              ),
            ],
          );
        },
      ),
    );
    name.dispose();
    phone.dispose();
    pickupTime.dispose();
    if (selected != null && mounted) setState(() => pickupCustomer = selected);
  }

  void add(Product p, {String note = '', String removed = ''}) {
    // A plain repeat of the same product increases its quantity; lines with
    // notes, removals or campaign choices stay separate.
    if (note.isEmpty && removed.trim().isEmpty && p.campaignData == null) {
      final same = draft.where((l) =>
          l['productId'] == p.id && l['customItem'] != true &&
          l['_unavailable'] != true && '${l['note'] ?? ''}'.isEmpty &&
          (l['removed'] as List? ?? const []).isEmpty &&
          l['components'] == null && (l['qty'] as int) < 1000).firstOrNull;
      if (same != null) {
        setState(() => same['qty'] = (same['qty'] as int) + 1);
        return;
      }
    }
    if (draft.length >= 200) {
      setState(
        () => saveError = 'Bir sipariş en fazla 200 ayrı satır içerebilir.',
      );
      return;
    }
    setState(
      () => draft.add({
        if (p.campaignData != null) ...copyJson(p.campaignData!),
        '_draftId': nextLine++,
        'productId': p.id,
        'productKey': p.name,
        'name': p.name,
        'price': p.price,
        'qty': 1,
        'note': note,
        'removed': removed
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
      }),
    );
  }

  Future<void> customize(Product p, [Json? line]) async {
    final original =
        line ??
        <String, dynamic>{
          if (p.campaignData != null) ...copyJson(p.campaignData!),
          'name': p.name,
          'price': p.price,
          'note': '',
          'removed': <String>[],
        };
    final result = await customizeLineDialog(
      context,
      original,
      description: p.descriptionTr ?? '',
    );
    if (result == null || !mounted) return;
    if (line == null) {
      if (result['qty'] == 0 || draft.length >= 200) return;
      add(p);
      setState(() => draft.last.addAll(result));
    } else
      setState(() {
        if (result['qty'] == 0)
          draft.remove(line);
        else
          line.addAll(result);
      });
  }

  Future<void> addCustomItem() async {
    if (draft.length >= 200) return;
    final result = await askFields(
      context,
      'Özel Ürün Ekle',
      [
        ('Ürün adı', ''),
        ('Birim fiyat (₺)', ''),
        ('Adet', '1'),
        ('Not', ''),
        ('İç menüye kaydet', 'Hayır'),
      ],
      choices: {
        4: ['Hayır', 'Evet'],
      },
    );
    if (result == null || !mounted) return;
    try {
      final qty = int.tryParse(result[2]);
      if (qty == null || qty < 1 || qty > 1000 || result[3].length > 500) {
        throw const FormatException('Adet veya not geçersiz.');
      }
      final item = <String, dynamic>{
        'customItem': true,
        'saveToMenu': result[4] == 'Evet',
        'name': result[0].trim(),
        'price': fromCents(parseMoney(result[1])),
        'qty': qty,
        'note': result[3],
        'removed': <String>[],
      };
      prepareInternalItem({}, {...item, 'saveToMenu': false});
      setState(() {
        draft.add({...item, '_draftId': nextLine++});
        saveError = null;
      });
    } on FormatException catch (e) {
      setState(() => saveError = e.message);
    }
  }

  int inCart(Product p) => draft
      .where((l) => l['productId'] == p.id && l['customItem'] != true)
      .fold<int>(0, (n, l) => n + (l['qty'] as int));

  Widget productList() {
    final visibleProducts = products
        .where(
          (p) =>
              p.active &&
              (category == 'all' || p.category == category) &&
              p.name.toLowerCase().contains(search.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Ürün ara',
                  prefixIcon: Icon(Icons.search, size: 20),
                ),
                onChanged: (v) => setState(() => search = v),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: addCustomItem,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Özel Ürün Ekle'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final x in [
                ('campaign', 'Kampanyalar'),
                ('all', 'Tümü'),
                ('wrap', 'Dürümler'),
                ('plate', 'Porsiyonlar'),
                ('meze', 'Mezeler'),
                ('fatte', 'Fatte'),
                ('side', 'Diğer'),
                ('salad', 'Salatalar'),
                ('dessert', 'Tatlılar'),
                ('drink', 'İçecekler'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(x.$2),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    selected: category == x.$1,
                    onSelected: (_) => setState(() => category = x.$1),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: visibleProducts.isEmpty
              ? const Center(child: Text('Bu kategoride ürün yok',
                  style: TextStyle(color: NohutBrand.muted)))
              : GridView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 250,
                    mainAxisExtent: 176,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: visibleProducts.length,
                  itemBuilder: (context, i) => productTile(visibleProducts[i]),
                ),
        ),
      ],
    );
  }

  Widget productTile(Product p) {
    final count = inCart(p);
    final available = p.price != null;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: count > 0 ? NohutBrand.green : const Color(0xffE1E7E3),
          width: count > 0 ? 1.6 : 1,
        ),
      ),
      color: count > 0 ? const Color(0xffF3F8F4) : Colors.white,
      child: InkWell(
        onTap: available ? () => add(p) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xffF1F4F2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: p.image == null
                        ? const Icon(Icons.restaurant_menu,
                            size: 20, color: NohutBrand.muted)
                        : Image.network(
                            Uri.parse('https://nohutfalafel.github.io/qr-menu/')
                                .resolve(p.image!).toString(),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.restaurant_menu,
                              size: 20, color: NohutBrand.muted),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14, height: 1.2),
                    ),
                  ),
                  if (count > 0)
                    Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: NohutBrand.green,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('×$count', style: const TextStyle(
                        color: Colors.white, fontSize: 12,
                        fontWeight: FontWeight.w800)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                p.descriptionTr ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5,
                  color: NohutBrand.muted, height: 1.25),
              ),
              const Spacer(),
              Text(
                available ? formatTry(cents(p.price)) : 'Fiyat yok',
                style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 15,
                  color: available ? NohutBrand.ink : NohutBrand.muted),
              ),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: available ? () => add(p) : null,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Ekle'),
                  ),
                  const SizedBox(width: 2),
                  Flexible(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      onPressed: available ? () => customize(p) : null,
                      child: const Text('Not / Malzeme',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget cartList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Text(
            'Sipariş Sepeti',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(width: 8),
          if (draft.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: NohutBrand.green,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${draft.fold<int>(0, (n, l) => n + (l['qty'] as int))}',
                style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w800, fontSize: 12)),
            ),
        ],
      ),
      const Text(
        'Aynı ürüne farklı notlar ekleyebilirsiniz.',
        style: TextStyle(fontSize: 12, color: NohutBrand.muted),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: draft.isEmpty
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shopping_basket_outlined,
                      size: 34, color: Color(0xffA9B3AD)),
                    SizedBox(height: 6),
                    Text('Sepet boş', style: TextStyle(
                      color: NohutBrand.muted, fontWeight: FontWeight.w600)),
                    Text('Ürüne dokunarak ekleyin',
                      style: TextStyle(color: NohutBrand.muted, fontSize: 12)),
                  ],
                ),
              )
            : ListView.separated(
                itemCount: draft.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, i) {
                  final line = draft[i];
                  final unavailable = line['_unavailable'] == true;
                  final details = [
                    for (final component in asMaps(line['components']))
                      '${component['name']} · ${campaignComponentDetails(component)}',
                    if ('${line['note']}'.isNotEmpty) 'Not: ${line['note']}',
                    if ((line['removed'] as List).isNotEmpty)
                      'Çıkar: ${(line['removed'] as List).join(', ')}',
                  ];
                  return Container(
                    key: ValueKey(line['_draftId']),
                    padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
                    decoration: BoxDecoration(
                      color: unavailable ? const Color(0xffFBE9E6) : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xffE1E7E3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xffF1F4F2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Adedi azalt',
                                visualDensity: VisualDensity.compact,
                                iconSize: 18,
                                onPressed: () => setState(() {
                                  if (line['qty'] == 1) {
                                    draft.remove(line);
                                  } else {
                                    line['qty'] = (line['qty'] as int) - 1;
                                  }
                                }),
                                icon: const Icon(Icons.remove),
                              ),
                              Text('${line['qty']}', style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 15)),
                              IconButton(
                                tooltip: 'Adedi artır',
                                visualDensity: VisualDensity.compact,
                                iconSize: 18,
                                onPressed: (line['qty'] as int) >= 1000
                                    ? null
                                    : () => setState(
                                        () => line['qty'] =
                                            (line['qty'] as int) + 1,
                                      ),
                                icon: const Icon(Icons.add),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "${line['name']}${unavailable ? ' · Satış dışı, satırı kaldırın' : ''}",
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: unavailable
                                      ? const Color(0xff8c352e) : NohutBrand.ink,
                                ),
                              ),
                              for (final d in details)
                                Text(d, style: const TextStyle(
                                  fontSize: 12, color: NohutBrand.muted)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          formatTry(cents(line['price']) * (line['qty'] as int)),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        IconButton(
                          tooltip: 'Satır notunu düzenle',
                          visualDensity: VisualDensity.compact,
                          iconSize: 19,
                          onPressed: unavailable || line['customItem'] == true
                              ? null
                              : () => customize(
                                  products.firstWhere(
                                    (p) => p.id == line['productId'],
                                  ),
                                  line,
                                ),
                          icon: const Icon(Icons.edit_note),
                        ),
                        IconButton(
                          tooltip: 'Satırı kaldır',
                          visualDensity: VisualDensity.compact,
                          iconSize: 19,
                          onPressed: () => setState(() => draft.remove(line)),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final total = draft.fold<int>(
      0,
      (sum, line) => sum + cents(line['price']) * (line['qty'] as int),
    );
    final lockedOrder = widget.adding
        ? widget.originalOrder
        : source == 'Masa' ? tableOrders[table] : null;
    final firstBatch = lockedOrder == null
        ? null : asMaps(lockedOrder['batches']).firstOrNull;
    final lockedStaff = (firstBatch?['staff'] ?? 'Atanmamış').toString();
    return Dialog(
      child: SizedBox(
        width: (size.width - 48).clamp(280, 1100),
        height: (size.height - 48).clamp(350, 820),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.adding ? 'Ek Sipariş' : 'Yeni Sipariş',
                      style: const TextStyle(
                        fontSize: 21,
                        fontFamily: NohutBrand.headingFont,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Kapat',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (!widget.adding && !widget.pickupOnly)
                    SizedBox(
                      width: 180,
                      child: DropdownButtonFormField<String>(
                        initialValue: source,
                        decoration: const InputDecoration(
                          labelText: 'Sipariş türü',
                        ),
                        items: ['Masa', 'Gel-Al']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => source = v!),
                      ),
                    ),
                  if (lockedOrder == null)
                    SizedBox(
                      width: 225,
                      child: DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: selectedEmployeeId,
                        decoration: const InputDecoration(
                          labelText: 'Siparişi Alan Personel *',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        hint: const Text('Personel seçin'),
                        items: [
                          for (final employee in widget.employees)
                            if (employee['id'] is int)
                              DropdownMenuItem<int>(
                                value: employee['id'] as int,
                                child: Text((employee['name'] ?? '').toString(),
                                  overflow: TextOverflow.ellipsis),
                              ),
                        ],
                        onChanged: widget.employees.isEmpty
                            ? null : (id) => setState(() => selectedEmployeeId = id),
                      ),
                    )
                  else
                    Container(
                      key: const ValueKey('locked-original-employee'),
                      constraints: const BoxConstraints(maxWidth: 350),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                      decoration: BoxDecoration(
                        color: const Color(0xffEAF2EC),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline, color: NohutBrand.green, size: 18),
                          const SizedBox(width: 8),
                          Flexible(child: Text(
                            'Siparişi Alan Personel: ' + lockedStaff + ' · Değiştirilemez',
                            style: const TextStyle(
                              color: NohutBrand.green, fontWeight: FontWeight.w700),
                          )),
                        ],
                      ),
                    ),
                  if (lockedOrder == null && widget.employees.isEmpty)
                    const Text(
                      'Aktif personel yok. Ayarlar → Personel bölümünden ekleyin.',
                      style: TextStyle(color: Color(0xff9E4A38), fontSize: 12),
                    ),
                  if (source == 'Masa')
                    SizedBox(
                      width: 180,
                      child: DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: table,
                        decoration: const InputDecoration(
                          labelText: 'Masa seçin',
                        ),
                        items: List.generate(
                          5,
                          (i) => DropdownMenuItem(
                            value: i + 1,
                            child: Text(
                              'Masa ${i + 1} · ${tableOrders[i + 1] == null ? 'Boş' : 'Dolu · Ek sipariş #${displayOrderNumber(tableOrders[i + 1]!)}'}',
                            ),
                          ),
                        ),
                        onChanged: widget.adding
                            ? null
                            : (v) => setState(() => table = v),
                      ),
                    ),
                  if (source == 'Gel-Al')
                    SizedBox(
                      width: 180,
                      child: DropdownButtonFormField<String>(
                        initialValue: pickup,
                        decoration: const InputDecoration(
                          labelText: 'Teslim alma',
                        ),
                        items: ['Tezgahtan', 'Telefon']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => pickup = v!),
                      ),
                    ),
                  if (source == 'Gel-Al' && !widget.adding)
                    TextButton(
                      onPressed: editPickupCustomer,
                      child: Text(
                        pickupCustomer.isEmpty
                            ? 'Müşteri / Saat Bilgisi'
                            : '${pickupCustomer['name']} · ${pickupCustomer['time']}',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final cart = Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xffF4F6F2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: cartList()),
                        if (saveError != null) ...[
                          Text(
                            saveError!,
                            style: const TextStyle(color: Color(0xff8c352e)),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => setState(() {
                              products = widget.refreshProducts?.call() ?? products;
                              tableOrders = widget.refreshTables?.call() ?? tableOrders;
                              for (final line in draft) {
                                if (line['customItem'] == true) continue;
                                final product = products
                                    .where((p) => p.id == line['productId'])
                                    .firstOrNull;
                                line['_unavailable'] =
                                    product == null ||
                                    !product.active ||
                                    product.price == null;
                                if (product != null && product.price != null) {
                                  if (product.campaignData != null) {
                                    try {
                                      line['components'] = mergeCampaignComponents(
                                        asMaps(product.campaignData!['components']),
                                        line['components'],
                                      );
                                    } on FormatException {
                                      line['_unavailable'] = true;
                                    }
                                  }
                                  line['basePrice'] = product.price;
                                  line['price'] = fromCents(
                                    cents(product.price) +
                                        (line['adjustmentCents'] as int? ?? 0) +
                                        componentExtraCents(line),
                                  );
                                  line['name'] = product.name;
                                }
                              }
                              saveError =
                                  'Güncel fiyatlar ve masalar yüklendi. Sepeti kontrol edip kaydedin.';
                            }),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Güncel Menü ve Masaları Al'),
                          ),
                        ],
                        const Divider(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Ürün: ${draft.fold<int>(0, (n, l) => n + (l['qty'] as int))}',
                                style: const TextStyle(color: NohutBrand.muted),
                              ),
                            ),
                            Flexible(
                              flex: 3,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text.rich(TextSpan(children: [
                                  const TextSpan(text: 'Toplam  ', style: TextStyle(
                                    color: NohutBrand.muted, fontWeight: FontWeight.w600)),
                                  TextSpan(text: formatTry(total), style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w900)),
                                ])),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(50),
                                textStyle: const TextStyle(
                                  fontFamily: NohutBrand.bodyFont, fontSize: 16, fontWeight: FontWeight.w800),
                              ),
                              onPressed:
                                  draft.isEmpty ||
                                      draft.any((l) => l['_unavailable'] == true) ||
                                      (source == 'Masa' && table == null) ||
                                      (lockedOrder == null && selectedEmployeeId == null)
                                  ? null
                                  : () {
                                      final request = OrderRequest(
                                        source: source,
                                        table: source == 'Masa' ? table : null,
                                        pickupChannel: pickup,
                                        customer: pickupCustomer,
                                        staffId: selectedEmployeeId,
                                        expectedTableOrderId:
                                            tableOrders[table]?['id'] as int?,
                                        lines: draft
                                            .map(
                                              (line) => Map<String, dynamic>.from(line)
                                                ..remove('_draftId')
                                                ..remove('_unavailable'),
                                            )
                                            .toList(),
                                      );
                                      if (widget.onSubmit?.call(request) ?? true) {
                                        Navigator.pop(context, request);
                                      } else {
                                        setState(
                                          () => saveError =
                                              'Kaydedilemedi. Güncel menü ve masaları alın; sepetiniz korunuyor.',
                                        );
                                      }
                                    },
                              icon: const Icon(Icons.save),
                              label: const Text('Siparişi Kaydet'),
                            ),
                          ],
                        ),
                        ],
                      ),
                    );
                    return c.maxWidth >= 740
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: productList()),
                              const SizedBox(width: 14),
                              SizedBox(
                                width: (c.maxWidth * 0.38).clamp(330.0, 430.0),
                                child: cart,
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(flex: 3, child: productList()),
                              const SizedBox(height: 10),
                              Expanded(flex: 2, child: cart),
                            ],
                          );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
