// Personel Ana Sayfa (owner chose option A "Özet kartı", 2026-11-27) at
// 320/360/390/430 dp, a tablet, light/dark, large text and a long Turkish
// name: no overflow, week near the top, nav labels, every action reachable.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nohut_personel/home.dart';
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

Widget app(String name, {double scale = 1, bool online = true}) {
  final c = PersonelController(api(name), StaffNotifications())..state = staffController().state..online = online;
  c.state['orders'] = [{'id': 1, 'source': 'Masa', 'table': 2}, {'id': 2, 'source': 'Gel-Al'}];
  return MaterialApp(debugShowCheckedModeBanner: false, theme: NohutStyle.theme, darkTheme: NohutStyle.darkTheme,
      builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: StaffHome(controller: c, onUnpair: () {}));
}

void main() {
  setUpAll(loadNohutFonts);
  {
    const s = 'a';
    for (final (w, h) in [(320.0, 640.0), (360.0, 740.0), (390.0, 844.0), (430.0, 932.0)]) {
      for (final mode in Brightness.values) {
        final m = mode == Brightness.light ? 'light' : 'dark';
        testWidgets('home $s ${w.toInt()} $m', (t) async {
          await renderScreen(t, 'home-$s-${w.toInt()}-$m', app('Test Personel A'),
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
          final list = find.descendant(of: find.byKey(const ValueKey('home-summary')), matching: find.byType(Scrollable)).first;
          for (final label in ['Masalar', 'Sipariş Al', 'Siparişler', 'Mesai Ekle', 'Vardiya Ekle', 'Maaş & Avans']) {
            await t.scrollUntilVisible(find.descendant(of: find.byKey(const ValueKey('home-summary')),
                matching: find.text(label)), 120, scrollable: list);
          }
        });
      }
    }
    testWidgets('home $s long name, 1.3× text, offline', (t) async {
      await renderScreen(t, 'home-$s-320-long-name-large-text', app(longName, scale: 1.3, online: false),
          size: const Size(320, 640));
      expect(t.takeException(), isNull);
      final g = t.widget<Text>(find.byKey(const ValueKey('home-greeting')));
      expect(g.maxLines, 1);
      expect(find.text('Laptop çevrimdışı · Sepet korunuyor'), findsOneWidget);
      // QA-22: the next shift's full date and times are shown, not clipped.
      final shift = find.text('Cmt 28 Kas · 10:00–18:00');
      expect(shift, findsOneWidget);
      expect(t.renderObject<RenderParagraph>(shift).didExceedMaxLines, isFalse);
      // QA-22: quick-action tiles in one row have equal heights.
      final a = t.getRect(find.ancestor(of: find.text('Masalar').first, matching: find.byType(Material)).first);
      final b = t.getRect(find.ancestor(of: find.text('Sipariş Al'), matching: find.byType(Material)).first);
      expect(a.height, b.height);
    });
    testWidgets('home $s tablet', (t) async {
      await renderScreen(t, 'home-$s-tablet', app(longName), size: const Size(1100, 800));
      expect(t.takeException(), isNull);
    });
  }
}
