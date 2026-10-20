import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/kas_receive_request.dart';

void main() {
  const address =
      'kaspa:pq02dzckvs0g6hhl9s9c484fv0wsd93sltwct9symfad4yw062w5y4v4mtlxa';
  for (final theme in KaspireTheme.values) {
    testWidgets('shared Receive fits 320px at 1.8 text scale in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(320, 680);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = AppSettings.theme.value;
      AppSettings.theme.value = theme;
      addTearDown(() => AppSettings.theme.value = previous);
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Scaffold(
              body: MediaQuery(
                  data:
                      const MediaQueryData(textScaler: TextScaler.linear(1.8)),
                  child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: const [
                        KasReceiveRequest(address: address)
                      ])))));
      await tester.pumpAndSettle();
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(qr.size!, lessThanOrEqualTo(244));
      expect(qr.dataModuleStyle.color!.computeLuminance(), lessThan(.1));
      await tester.scrollUntilVisible(find.text('Share'), 160,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('P2SH Copy and Share use the same address and exact amount',
      (tester) async {
    String? copied;
    Map<Object?, Object?>? shared;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    const share = MethodChannel('dev.fluttercommunity.plus/share');
    messenger.setMockMethodCallHandler(share, (call) async {
      shared = Map<Object?, Object?>.from(call.arguments as Map);
      return 'success';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(share, null);
    });
    await tester.pumpWidget(MaterialApp(
        theme: KasVaultTheme.dark,
        home: Scaffold(
            body: ListView(
                padding: const EdgeInsets.all(20),
                children: const [KasReceiveRequest(address: address)]))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '21056.45645');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.ensureVisible(find.text('Copy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, '$address?amount=21056.45645');
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(shared?['text'], copied);
    expect(tester.takeException(), isNull);
  });
}
