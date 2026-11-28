/// Isolated TEST builds (owner request 7236201964): username `test`, PIN
/// `00000`, synthetic data only. Built with
/// `flutter build windows --dart-define=NOHUT_TEST_BUILD=true`.
///
/// A normal build compiles every branch below away (`nohutTestBuild` is a
/// compile-time `false`), so production keeps its password and PIN rules.
/// A TEST build:
///  - keeps its database in `%APPDATA%\NohutFalafel-TEST`, never the restaurant's;
///  - seeds synthetic staff and menu on first start;
///  - refuses every outgoing connection except this computer (no Trendyol,
///    Yemeksepeti, Google, GitHub/QR publish, Supabase, market prices);
///  - never prints and never starts the QR publisher;
///  - shows a permanent TEST banner.
library;

import 'dart:io';

const nohutTestBuild = bool.fromEnvironment('NOHUT_TEST_BUILD');
const testFixtureUsername = 'test';
const testFixturePin = '00000';
const testBuildBanner = 'TEST SÜRÜMÜ · sentetik veri · canlı işlemler kapalı';
const testBuildDataFolder = 'NohutFalafel-TEST';

class TestBuildBlocked implements Exception {
  const TestBuildBlocked(this.what);
  final String what;
  @override
  String toString() => 'TEST sürümünde kapalı: $what';
}

/// True only in a TEST build, for the fixture account and its fixed code.
bool isTestFixtureLogin(String username, String secret) =>
    nohutTestBuild && username.trim() == testFixtureUsername && secret == testFixturePin;

bool _loopback(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]';

/// Outgoing HTTP from a TEST build may reach this computer only.
class TestBuildHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.scheme != 'http' || !_loopback(uri.host)) {
        return Future.error(TestBuildBlocked('${uri.scheme}://${uri.host}'));
      }
      return Socket.startConnect(uri.host, uri.port);
    };
    return client;
  }
}

/// Called first thing in a TEST build's `main`.
void installTestBuildGuards() => HttpOverrides.global = TestBuildHttpOverrides();
