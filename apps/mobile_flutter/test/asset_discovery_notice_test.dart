import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/widgets/asset_discovery_notice.dart';

void main() {
  testWidgets('loading and partial discovery never claim an empty wallet',
      (tester) async {
    Future<void> show({required bool loading, String? warning}) =>
        tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: AssetDiscoveryNotice(
                    empty: true, loading: loading, warning: warning))));
    await show(loading: true);
    expect(find.text('Asset discovery is still loading…'), findsOneWidget);
    expect(find.textContaining('No token,'), findsNothing);
    await show(
        loading: false, warning: 'Standard KCC20 discovery is incomplete.');
    expect(find.textContaining('Pull to refresh'), findsOneWidget);
    expect(
        find.text('Standard KCC20 discovery is incomplete.'), findsOneWidget);
    expect(find.textContaining('No token,'), findsNothing);
    await show(loading: false);
    expect(find.textContaining('No token,'), findsOneWidget);
  });
  testWidgets(
      'partial source warning wraps beside existing holdings at phone width',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: const [
      Text('NACHO 1.25'),
      AssetDiscoveryNotice(
          empty: false,
          loading: true,
          warning:
              'Standard KCC20 discovery is incomplete; additional holdings may not yet be indexed.'),
    ]))));
    expect(find.text('NACHO 1.25'), findsOneWidget);
    expect(find.textContaining('additional holdings'), findsOneWidget);
    expect(find.textContaining('No token,'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
