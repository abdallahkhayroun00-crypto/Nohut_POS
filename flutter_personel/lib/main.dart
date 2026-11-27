import 'dart:async';

import 'package:flutter/material.dart';

import 'home.dart';
import 'pair_page.dart';
import 'pos_api.dart';
import 'style.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NohutPersonelApp());
}

/// Separate Android Flutter engine, not an embedded web page.
class NohutPersonelApp extends StatefulWidget {
  const NohutPersonelApp({super.key});

  @override
  State<NohutPersonelApp> createState() => _NohutPersonelAppState();
}

class _NohutPersonelAppState extends State<NohutPersonelApp>
    with WidgetsBindingObserver {
  late final controller =
      PersonelController(NohutApi(), StaffNotifications());
  bool initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await controller.start();
    } catch (e) {
      debugPrint('Android initialization failed: $e');
    }
    if (mounted) setState(() => initialized = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && controller.api.paired) {
      unawaited(controller.refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Nohut Personel',
    theme: NohutStyle.theme,
    darkTheme: NohutStyle.darkTheme,
    home: !initialized
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : controller.api.paired
            ? StaffHome(
                controller: controller,
                onUnpair: () => setState(() {}),
              )
            : PairPage(
                controller: controller,
                onPaired: () => setState(() {}),
              ),
  );
}
