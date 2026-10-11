import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/widgets/krc20_order_card.dart';

void main() {
  for (final width in [280.0, 320.0, 400.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'long token amount fits at width $width and text scale $scale',
          (tester) async {
        var opened = false;
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: Center(
                        child: SizedBox(
                            width: width,
                            child: Krc20OrderCard(
                              totalKas: '457.5',
                              quantity: '21056.45645',
                              ticker: 'NACHO',
                              unitPrice: '0.021727',
                              logo: const SizedBox(width: 38, height: 38),
                              onOpen: () => opened = true,
                            )))))));
        expect(tester.takeException(), isNull);
        expect(find.text('21056.45645'), findsOneWidget);
        expect(find.text('NACHO'), findsOneWidget);
        expect(tester.getTopLeft(find.text('NACHO')).dy,
            greaterThan(tester.getTopLeft(find.text('21056.45645')).dy));
        await tester.tap(find.text('View order'));
        expect(opened, isTrue);
      });
    }
  }
}
