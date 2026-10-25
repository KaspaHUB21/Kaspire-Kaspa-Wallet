import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/widgets/sell_amount_buttons.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';

void main() {
  test(
      'percentages preserve exact units with no floating point or overspending',
      () {
    final raw = BigInt.parse('999999999999999999999999999');
    for (final p in [25, 50, 75, 100]) {
      expect(
          sellPercentageRaw(raw, p), raw * BigInt.from(p) ~/ BigInt.from(100));
      expect(sellPercentageRaw(raw, p), lessThanOrEqualTo(raw));
    }
    expect(sellAmountInput(sellPercentageRaw(BigInt.from(1234567), 25), 3),
        '308.641');
    expect(sellAmountInput(sellPercentageRaw(BigInt.from(123456789), 25), 8),
        '0.30864197');
    expect(sellAmountInput(BigInt.from(12345), 0), '12345');
    expect(sellPercentageRaw(BigInt.from(12345), 100, step: BigInt.from(1000)),
        BigInt.from(12000));
    expect(sellPercentageRaw(BigInt.from(999), 25, step: BigInt.from(1000)),
        BigInt.zero);
  });
  for (final theme in KaspireTheme.values) {
    testWidgets(
        'four presets share one narrow row, inherit theme and retain exact input in $theme',
        (tester) async {
      tester.view.physicalSize = const Size(280, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? selected;
      await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: Scaffold(
              body: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SellAmountButtons(
                      balance: BigInt.from(1234567),
                      decimals: 3,
                      onSelected: (value) => selected = value)))));
      await tester.pumpAndSettle();
      final tops = [
        for (final text in ['25%', '50%', '75%', 'MAX'])
          tester.getTopLeft(find.text(text)).dy
      ];
      expect(tops.every((y) => (y - tops.first).abs() < 1), isTrue);
      await tester.tap(find.text('25%'));
      await tester.pump();
      expect(selected, '308.641');
      await tester.tap(find.text('MAX'));
      await tester.pump();
      expect(selected, '1234.567');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'unavailable or zero balances and sub-lot percentages are disabled',
      (tester) async {
    for (final balance in [null, BigInt.zero, BigInt.from(999)]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SellAmountButtons(
                  balance: balance,
                  decimals: 0,
                  step: BigInt.from(1000),
                  onSelected: (_) => fail('disabled')))));
      expect(
          tester
              .widgetList<OutlinedButton>(find.byType(OutlinedButton))
              .every((b) => b.onPressed == null),
          isTrue);
    }
  });
}
