// The order composer with items in the cart, and its customize dialog, at
// both desktop sizes. For the Premium UI review; PNGs only with
// NOHUT_RENDER_DIR.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pos_flow_render_test.dart' show click, mount, onPlan, shot;

void main() {
  for (final (name, size) in [
    ('1536', const Size(1536, 864)),
    ('1280', const Size(1280, 720)),
  ]) {
    testWidgets('composer with items and customize dialog at $name', (t) async {
      await mount(t, size);
      await click(t, find.text('Masalar & Siparişler').last);
      await click(t, onPlan('Masa 2'));
      final ekle = find.widgetWithText(FilledButton, 'Ekle');
      await click(t, ekle.at(0));
      await click(t, ekle.at(0));
      await click(t, ekle.at(2));
      expect(t.takeException(), isNull);
      await shot(t, 'cart-$name-1-items');
      await click(t, find.text('Not / Malzeme').first);
      expect(t.takeException(), isNull);
      await shot(t, 'cart-$name-2-customize');
    });
  }
}
