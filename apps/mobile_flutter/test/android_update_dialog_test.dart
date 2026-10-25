import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/app_settings.dart';
import 'package:kasvault_wallet/src/services/update_service.dart';
import 'package:kasvault_wallet/src/theme.dart';
import 'package:kasvault_wallet/src/widgets/android_update_dialog.dart';

final update = KaspireUpdate(
    version: '0.11.69',
    build: 212,
    minimumBuild: 1,
    critical: false,
    publishedAt: DateTime.utc(2026, 10, 25),
    apkUrl: Uri.parse(
        'https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v0.11.69.apk'),
    sha256: 'a' * 64,
    releaseNotesUrl: Uri.parse(
        'https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/v0.11.69'),
    signedPayload: 'verified-payload',
    signature: 'verified-signature');

class Backend extends UpdateService {
  int downloads = 0, installs = 0, cancels = 0;
  String result = 'installer-opened';
  bool fail = false;
  Completer<Map<String, Object?>>? blocked;
  @override
  Future<Map<String, Object?>> startAndroidUpdate(KaspireUpdate value) async {
    expect(value, same(update));
    downloads++;
    if (fail) {
      throw PlatformException(
          code: 'UPDATE_ERROR',
          message: 'Verification failed. Use the official website.');
    }
    return {'token': 'public-fixture'};
  }

  @override
  Future<Map<String, Object?>> androidUpdateStatus(String token) async =>
      blocked == null ? {'stage': 'ready'} : blocked!.future;
  @override
  Future<String> installAndroidUpdate(String token) async {
    installs++;
    return result;
  }

  @override
  Future<void> cancelAndroidUpdate(String token) async {
    cancels++;
    if (blocked != null && !blocked!.isCompleted) {
      blocked!.complete({'stage': 'cancelled'});
    }
  }
}

Future<void> open(WidgetTester tester, Backend backend,
    {KaspireTheme theme = KaspireTheme.midnight,
    Future<bool> Function(Uri)? website}) async {
  await tester.pumpWidget(MaterialApp(
      theme: KasVaultTheme.forTheme(theme),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AndroidUpdateDialog(
                          update: update,
                          service: backend,
                          openWebsite: website)),
                  child: const Text('Open update'))))));
  await tester.tap(find.text('Open update'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('both update choices fit narrow screens and use every app theme',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final theme in KaspireTheme.values) {
      final backend = Backend();
      await open(tester, backend, theme: theme);
      expect(find.text('How would you like to update?'), findsOneWidget);
      expect(find.text('Download from official website'), findsOneWidget);
      expect(find.text('Download & install from GitHub'), findsOneWidget);
      expect(backend.downloads, 0);
      final dialog = tester.element(find.byType(AlertDialog));
      expect(Theme.of(dialog).dialogTheme.backgroundColor,
          KasVaultTheme.forTheme(theme).dialogTheme.backgroundColor);
      expect(tester.takeException(), isNull, reason: theme.name);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  testWidgets(
      'website option opens only the signed official URL, no native installer',
      (tester) async {
    final backend = Backend();
    Uri? opened;
    await open(tester, backend, website: (uri) async {
      opened = uri;
      return true;
    });
    await tester.tap(find.text('Download from official website'));
    await tester.pumpAndSettle();
    expect(opened, update.apkUrl);
    expect(backend.downloads, 0);
    expect(backend.installs, 0);
  });
  testWidgets(
      'GitHub option downloads, verifies then opens Android installer without claiming success',
      (tester) async {
    final backend = Backend();
    await open(tester, backend);
    await tester.ensureVisible(find.text('Download & install from GitHub'));
    await tester.tap(find.text('Download & install from GitHub'));
    await tester.pumpAndSettle();
    expect(backend.downloads, 1);
    expect(backend.installs, 1);
    expect(find.textContaining('Opening the installer alone does not mean'),
        findsOneWidget);
    expect(find.text('Update installed'), findsNothing);
  });
  testWidgets(
      'unknown-source permission requires an explicit continue tap after returning',
      (tester) async {
    final backend = Backend()..result = 'permission-required';
    await open(tester, backend);
    await tester.ensureVisible(find.text('Download & install from GitHub'));
    await tester.tap(find.text('Download & install from GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('Continue installation'), findsOneWidget);
    expect(backend.installs, 1);
    backend.result = 'installer-opened';
    await tester.ensureVisible(find.text('Continue installation'));
    await tester.tap(find.text('Continue installation'));
    await tester.pumpAndSettle();
    expect(backend.installs, 2);
  });
  testWidgets(
      'verification failure is readable and leaves website recovery available',
      (tester) async {
    final backend = Backend()..fail = true;
    await open(tester, backend);
    await tester.ensureVisible(find.text('Download & install from GitHub'));
    await tester.tap(find.text('Download & install from GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('Verification failed. Use the official website.'),
        findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
    expect(backend.installs, 0);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNotNull);
  });
  testWidgets('auto-lock navigation preserves the permission handoff',
      (tester) async {
    final backend = Backend()..result = 'permission-required';
    await open(tester, backend);
    await tester.ensureVisible(find.text('Download & install from GitHub'));
    await tester.tap(find.text('Download & install from GitHub'));
    await tester.pumpAndSettle();
    expect(backend.installs, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(backend.cancels, 0);
  });
  testWidgets(
      'cancel stops native download and closes without opening installer',
      (tester) async {
    final backend = Backend()..blocked = Completer();
    await open(tester, backend);
    await tester.ensureVisible(find.text('Download & install from GitHub'));
    await tester.tap(find.text('Download & install from GitHub'));
    await tester.pump();
    await tester.tap(find.text('Cancel download'));
    await tester.pumpAndSettle();
    expect(backend.cancels, greaterThan(0));
    expect(backend.installs, 0);
    expect(find.byType(AndroidUpdateDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
