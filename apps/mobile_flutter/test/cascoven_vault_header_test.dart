import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/screens/covenant_vault_screen.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/cascoven_vault_header.dart';
import 'package:kasvault_wallet/src/widgets/hub21_material.dart';
import 'package:kasvault_wallet/src/widgets/neptune_material.dart';

import 'covenant_vault_test.dart' show ScreenVaultService, owner;

void main() {
  // Optional rendered artifact for manual inspection, alongside raster tests.
  if (const bool.fromEnvironment('VAULT_GOLDENS')) {
    testWidgets('Glacier vault screen visual preview', (tester) async {
      final sdk = Platform.environment['FLUTTER_ROOT']!;
      await tester.runAsync(() async {
        await (FontLoader('sans-serif')
              ..addFont(File('$sdk/bin/cache/dart-sdk/bin/resources/devtools/'
                      'assets/packages/devtools_app_shared/fonts/Roboto/Roboto-Regular.ttf')
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes))))
            .load();
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
      });
      AppSettings.theme.value = KaspireTheme.glacier;
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = ScreenVaultService();
      await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: KasVaultTheme.forTheme(KaspireTheme.glacier),
          home: CovenantVaultScreen(address: owner, service: service)));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../artifacts/internal/covenant-vault-build179/glacier-vault-screen.png'));
      await tester.pumpWidget(const SizedBox.shrink());
      service.close();
    });
  }
  for (final theme in KaspireTheme.values) {
    for (final width in [320.0, 840.0]) {
      testWidgets(
          'KasCoven header preserves copy/layout in ${theme.name} at $width',
          (tester) async {
        AppSettings.theme.value = theme;
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
          theme: KasVaultTheme.forTheme(theme),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: KasCovenVaultHeader(),
              ),
            ),
          ),
        ));
        expect(find.text(KasCovenVaultHeader.eyebrow), findsOneWidget);
        expect(find.text(KasCovenVaultHeader.title), findsOneWidget);
        expect(find.text(KasCovenVaultHeader.lead), findsOneWidget);
        for (final text in KasCovenVaultHeader.guarantees) {
          expect(find.text(text), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        if (width <= 620) {
          final dots = KasCovenVaultHeader.guarantees
              .map((text) => tester.getCenter(find.text(text)))
              .toList();
          expect(dots[0].dx, closeTo(dots[1].dx, .01));
          expect(dots[1].dx, closeTo(dots[2].dx, .01));
          expect(dots[0].dy, lessThan(dots[1].dy));
          expect(dots[1].dy, lessThan(dots[2].dy));
        }
        final title = tester.widget<Text>(find.text(KasCovenVaultHeader.title));
        expect(title.textAlign, TextAlign.center);
        final eyebrow =
            tester.widget<Text>(find.text(KasCovenVaultHeader.eyebrow));
        final scheme = KasVaultTheme.forTheme(theme).colorScheme;
        expect(
            eyebrow.style!.color,
            theme == KaspireTheme.midnight
                ? KasCovenVaultHeader.mint
                : scheme.primary);
        final header = find.byType(KasCovenVaultHeader);
        final panels =
            find.descendant(of: header, matching: find.byType(Hub21Panel));
        if (KasVaultTheme.isDecorative) {
          expect(panels, findsNWidgets(4));
          final decorations = tester
              .widgetList<DecoratedBox>(find.descendant(
                  of: header, matching: find.byType(DecoratedBox)))
              .map((box) => box.decoration)
              .toList();
          expect(
              decorations.where((decoration) => switch (theme) {
                    KaspireTheme.hub21 => decoration is Hub21MetalDecoration,
                    KaspireTheme.glacier =>
                      decoration is GlacierGlassDecoration,
                    KaspireTheme.neptune =>
                      decoration is NeptuneWaterDecoration,
                    _ => false,
                  }),
              hasLength(4));
        } else {
          expect(panels, findsNothing);
        }
        final lead = tester.widget<Text>(find.text(KasCovenVaultHeader.lead));
        expect(
            lead.style!.color,
            theme == KaspireTheme.midnight
                ? const Color(0xB3EEFCFF)
                : KasVaultTheme.detailText);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets('recovery expansion has exactly the requested shortened copy',
      (tester) async {
    final service = ScreenVaultService();
    await tester.pumpWidget(MaterialApp(
        home: CovenantVaultScreen(address: owner, service: service)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Post-quantum recovery protection'), 220,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Post-quantum recovery protection'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Vault recovery files use Argon2id, XChaCha20-Poly1305, ML-KEM-1024 and ML-DSA-87. A strong password remains essential.'),
        findsOneWidget);
    expect(find.textContaining('has not been independently audited'),
        findsNothing);
    expect(find.textContaining('It does not make wallet signatures'),
        findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    service.close();
  });
}
