// Personel Ana Sayfa: two alternatives for the owner (relay 7226986975),
// each at 320/360/390/430 dp, a tablet, light/dark, large text and a long
// Turkish name. Same actions and numbers in both; no overflow anywhere.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/home.dart';
import 'package:nohut_personel/personel_dashboard.dart';
import 'package:nohut_personel/pos_api.dart';
import 'package:nohut_personel/style.dart';

import '../work_page_test.dart' show weekReply;
import 'render_harness.dart';
import 'screens_render_test.dart' show staffController;

const longName = 'Ayşegül Büşra Karaçalıoğlu-Şimşekdağ';

NohutApi api(String name) {
  final reply = weekReply();
  (reply['week'] as Map)['employee'] = {...(reply['week'] as Map)['employee'] as Map, 'name': name};
  final a = NohutApi(client: MockClient((r) async => r.url.path == '/api/work/week'
      ? http.Response(jsonEncode(reply), 200, headers: {'content-type': 'application/json; charset=utf-8'})
      : http.Response('{}', 404)));
  a..host = 'http://192.168.1.5:8787'..token = 'x' * 40..serverId = 'synthetic'..session = 'synthetic'
    ..sessionInfo = {'session': {'status': 'ok', 'employeeId': 7, 'username': 'personela'}};
  return a;
}

Widget app(PersonelHomeStyle style, String name, {double scale = 1, bool online = true}) {
  final c = PersonelController(api(name), StaffNotifications())..state = staffController().state..online = online;
  c.state['orders'] = [{'id': 1, 'source': 'Masa', 'table': 2}, {'id': 2, 'source': 'Gel-Al'}];
  return MaterialApp(debugShowCheckedModeBanner: false, theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
      builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: StaffHome(controller: c, onUnpair: () {}, homeStyle: style));
}

void main() {
  setUpAll(loadNohutFonts);
  for (final style in PersonelHomeStyle.values) {
    final s = style == PersonelHomeStyle.summary ? 'a' : 'b';
    for (final (w, h) in [(320.0, 640.0), (360.0, 740.0), (390.0, 844.0), (430.0, 932.0)]) {
      for (final mode in Brightness.values) {
        final m = mode == Brightness.light ? 'light' : 'dark';
        testWidgets('home $s ${w.toInt()} $m', (t) async {
          await renderScreen(t, 'home-$s-${w.toInt()}-$m', app(style, 'Test Personel A'),
              size: Size(w, h), brightness: mode);
          expect(t.takeException(), isNull);
          // The week is above the fold, nav labels visible, every action reachable.
          expect(find.text('Kazanılan'), findsOneWidget);
          final week = t.getRect(find.byKey(const ValueKey('home-week')));
          expect(week.top, lessThan(h * .5), reason: 'week overview near the top');
          final nav = find.byType(NavigationBar);
          for (final l in ['Ana Sayfa', 'Masalar', 'Sipariş', 'Siparişler', 'Daha Fazla']) {
            expect(find.descendant(of: nav, matching: find.text(l)), findsOneWidget, reason: 'nav label $l');
          }
          final list = find.descendant(of: find.byKey(ValueKey('home-${style.name}')), matching: find.byType(Scrollable)).first;
          for (final label in ['Masalar', 'Sipariş Al', 'Siparişler', 'Mesai Ekle', 'Vardiya Ekle', 'Maaş & Avans']) {
            await t.scrollUntilVisible(find.descendant(of: find.byKey(ValueKey('home-${style.name}')),
                matching: find.text(label)), 120, scrollable: list);
          }
        });
      }
    }
    testWidgets('home $s long name, 1.3× text, offline', (t) async {
      await renderScreen(t, 'home-$s-320-long-name-large-text', app(style, longName, scale: 1.3, online: false),
          size: const Size(320, 640));
      expect(t.takeException(), isNull);
      final g = t.widget<Text>(find.byKey(const ValueKey('home-greeting')));
      expect(g.maxLines, 1);
      expect(find.text('Laptop çevrimdışı · Sepet korunuyor'), findsOneWidget);
    });
    testWidgets('home $s tablet', (t) async {
      await renderScreen(t, 'home-$s-tablet', app(style, longName), size: const Size(1100, 800));
      expect(t.takeException(), isNull);
    });
  }
}
