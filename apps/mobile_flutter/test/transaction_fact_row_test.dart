import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/transaction_fact_row.dart';

const facts = [
  ('Amount sent', '4,287.00000000 KAS'),
  ('Network fee', '0.00203600 KAS'),
  ('Total debit', '4,287.00203600 KAS'),
  ('Change', '132,087.21478167 KAS'),
  ('Network', 'Kaspa Layer 1'),
  ('Inputs / outputs', '1 / 2'),
  ('Mass', '2036'),
  ('Time', '2026-11-21 18:50:45'),
];

void main() {
  tearDown(() => AppSettings.theme.value = KaspireTheme.midnight);
  for (final theme in KaspireTheme.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
          'payment values share one left edge in ${theme.name}, scale $scale',
          (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        AppSettings.theme.value = theme;
        await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(children: [
              for (final fact in facts)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: TransactionFactRow(fact.$1, fact.$2))
            ]),
          ))),
        ));
        await tester.pumpAndSettle();
        final left = tester.getTopLeft(find.text(facts.first.$2)).dx;
        for (final fact in facts) {
          expect(tester.getTopLeft(find.text(fact.$2)).dx, closeTo(left, .01));
          expect(tester.widget<Text>(find.text(fact.$2)).textAlign,
              TextAlign.left);
          expect(
              tester.getRect(find.text(fact.$2)).right, lessThanOrEqualTo(302));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
