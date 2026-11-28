// Two durums, different removals; and Ek Sipariş quick-repeat of what is
// already on the account (owner request 2026-11-28).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'visual/pos_flow_render_test.dart' show click, mount, onPlan, shot;

void main() {
  testWidgets('one unit of a two-durum line can be edited on its own', (t) async {
    await mount(t, const Size(1536, 864));
    await click(t, find.text('Masalar & Siparişler').last);
    await click(t, onPlan('Masa 2'));
    final ekle = find.widgetWithText(FilledButton, 'Ekle');
    await click(t, ekle.at(0));
    await click(t, ekle.at(0));
    expect(find.text('2'), findsWidgets);
    // The cart line's edit button.
    await click(t, find.byTooltip('Satır notunu düzenle'));
    await click(t, find.byKey(const ValueKey('customize-one-unit')));
    await click(t, find.text('Domates'));
    await click(t, find.text('Kaydet'));
    expect(t.takeException(), isNull);
    // Now two cart lines: one plain unit and one without tomato.
    expect(find.byTooltip('Satır notunu düzenle'), findsNWidgets(2));
    expect(find.textContaining('Domates'), findsWidgets);
    await shot(t, 'units-1-two-durum-split');
  });

  testWidgets('cancelling the one-unit edit leaves the line unchanged', (t) async {
    await mount(t, const Size(1536, 864));
    await click(t, find.text('Masalar & Siparişler').last);
    await click(t, onPlan('Masa 2'));
    final ekle = find.widgetWithText(FilledButton, 'Ekle');
    await click(t, ekle.at(0));
    await click(t, ekle.at(0));
    await click(t, find.byTooltip('Satır notunu düzenle'));
    await click(t, find.byKey(const ValueKey('customize-one-unit')));
    await click(t, find.text('Vazgeç'));
    expect(find.byTooltip('Satır notunu düzenle'), findsOneWidget);
  });

  testWidgets('Ek Sipariş shows the account items as one-tap adds', (t) async {
    await mount(t, const Size(1536, 864));
    await click(t, find.text('Masalar & Siparişler').last);
    await click(t, onPlan('Masa 3'));
    await click(t, find.text('Ek Sipariş').last);
    expect(find.text('Hesaptakiler · bir dokunuşla ekle'), findsOneWidget);
    // Masa 3 has 2× Falafel Dürüm, 2× Ayran, 1× Humus (product ids 0, 3, 2).
    await click(t, find.byKey(const ValueKey('quick-add-3')));
    await click(t, find.byKey(const ValueKey('quick-add-3')));
    expect(t.takeException(), isNull);
    expect(find.byTooltip('Satırı kaldır'), findsOneWidget,
        reason: 'two taps merge into one Ayran line');
    await shot(t, 'units-2-ek-siparis-quick-add');
  });
}
