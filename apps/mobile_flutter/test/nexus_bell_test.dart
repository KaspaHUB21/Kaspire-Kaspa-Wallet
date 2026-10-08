import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/widgets/nexus_bell.dart';
import 'package:kasvault_wallet/src/services/nexus_service.dart';
import 'package:kasvault_wallet/src/services/network_settings.dart';
import 'package:kasvault_wallet/src/services/native_security.dart';

class BellService extends NexusService {
  BellService() : super('kaspa:test');
  List<Map<String, Object?>> notifications = [
    {'id': 'offer', 'readAt': null},
    {'id': 'counter', 'readAt': null},
    {'id': 'listing', 'readAt': null}
  ];
  @override
  bool get connected => true;
  @override
  Future<Object?> request(String path,
          {Map<String, String> query = const {},
          Map<String, Object?>? body,
          bool private = false}) async =>
      notifications;
}

class FreshBellService extends BellService {
  bool ready = false;
  int logins = 0;
  @override
  bool get connected => ready;
  @override
  Future<bool> connect([BuildContext? context]) async {
    logins++;
    ready = true;
    return true;
  }
}

void main() {
  testWidgets('fresh unlocked wallet activates and rings without tapping Nexus',
      (tester) async {
    NativeSecurity.internalNexusUnlocked = true;
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final service = FreshBellService();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NexusBell(
                address: 'kaspa:test', notificationService: service))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.logins, 1);
    expect(find.text('3'), findsOneWidget);
    expect(
        tester
            .widget<Transform>(find.byType(Transform).first)
            .transform
            .storage[1]
            .abs(),
        greaterThan(0.01));
    await tester.pumpWidget(const SizedBox.shrink());
    NativeSecurity.internalNexusUnlocked = false;
  });
  testWidgets('locked wallet does not activate private notifications',
      (tester) async {
    NativeSecurity.internalNexusUnlocked = false;
    final service = FreshBellService();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NexusBell(
                address: 'kaspa:test', notificationService: service))));
    await tester.pump();
    expect(service.logins, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'offer, counter and listing alerts animate the bell and show unread count; reading stops it',
      (tester) async {
    NetworkSettings.network.value = KaspaNetwork.mainnet;
    final service = BellService();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NexusBell(
                address: 'kaspa:test', notificationService: service))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('3'), findsOneWidget);
    final moving =
        tester.widget<Transform>(find.byType(Transform).first).transform;
    expect(moving.storage[1].abs(), greaterThan(0.01));
    service.notifications = [];
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, false);
    expect(
        tester
            .widget<Transform>(find.byType(Transform).first)
            .transform
            .storage[1],
        0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
