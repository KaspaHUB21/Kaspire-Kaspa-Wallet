import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_security.dart';

class KaspireUpdate {
  const KaspireUpdate({
    required this.version,
    required this.build,
    required this.minimumBuild,
    required this.critical,
    required this.publishedAt,
    required this.apkUrl,
    required this.sha256,
    required this.releaseNotesUrl,
  });

  final String version;
  final int build;
  final int minimumBuild;
  final bool critical;
  final DateTime publishedAt;
  final Uri apkUrl;
  final String sha256;
  final Uri releaseNotesUrl;
}

class UpdateCheckState {
  const UpdateCheckState({
    this.update,
    this.checking = false,
    this.lastCheckedAt,
    this.error,
  });

  final KaspireUpdate? update;
  final bool checking;
  final DateTime? lastCheckedAt;
  final String? error;
}

class UpdateService {
  UpdateService({
    http.Client? client,
    NativeSecurity? security,
    Future<bool> Function(String payload, String signature)? verifier,
    Future<PackageInfo> Function()? packageInfo,
  })  : _client = client ?? http.Client(),
        _verify = verifier ??
            ((payload, signature) =>
                (security ?? NativeSecurity()).verifyUpdateManifest(
                  payload: payload,
                  signature: signature,
                )),
        _packageInfo = packageInfo ?? PackageInfo.fromPlatform;

  static final instance = UpdateService();
  static final manifestUri =
      Uri.parse('https://kaspire.kaslab.space/updates/android.json');
  static const _automaticKey = 'updates_automatic_v1';
  static const _lastCheckedKey = 'updates_last_checked_v1';
  static const _remindBuildKey = 'updates_remind_build_v1';
  static const _remindAfterKey = 'updates_remind_after_v1';

  final http.Client _client;
  final Future<bool> Function(String payload, String signature) _verify;
  final Future<PackageInfo> Function() _packageInfo;
  final ValueNotifier<UpdateCheckState> state =
      ValueNotifier(const UpdateCheckState());
  final ValueNotifier<bool> automaticChecks = ValueNotifier(true);

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    automaticChecks.value = preferences.getBool(_automaticKey) ?? true;
    final checked = preferences.getInt(_lastCheckedKey);
    if (checked != null) {
      state.value = UpdateCheckState(
        lastCheckedAt:
            DateTime.fromMillisecondsSinceEpoch(checked, isUtc: true),
      );
    }
  }

  Future<void> setAutomaticChecks(bool enabled) async {
    automaticChecks.value = enabled;
    await (await SharedPreferences.getInstance())
        .setBool(_automaticKey, enabled);
  }

  Future<void> checkIfDue() async {
    await initialize();
    if (!automaticChecks.value) return;
    // This method runs once for each cold app start. Always fetch the small,
    // signed manifest here: a 24-hour throttle could otherwise hide a release
    // for almost a full day when Kaspire happened to check shortly before it
    // was published.
    await checkNow();
  }

  Future<KaspireUpdate?> checkNow() async {
    if (state.value.checking) return state.value.update;
    state.value = UpdateCheckState(
      update: state.value.update,
      checking: true,
      lastCheckedAt: state.value.lastCheckedAt,
    );
    try {
      final requestUri = manifestUri.replace(
        queryParameters: {
          'check': DateTime.now().toUtc().millisecondsSinceEpoch.toString(),
        },
      );
      final response = await _client.get(
        requestUri,
        headers: const {
          'Cache-Control': 'no-cache, no-store, max-age=0',
          'Pragma': 'no-cache',
        },
      ).timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200 || response.bodyBytes.length > 32768) {
        throw StateError('The update server returned an invalid response.');
      }
      final envelope = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      final payloadBase64 = envelope['payload']?.toString() ?? '';
      final signature = envelope['signature']?.toString() ?? '';
      if (payloadBase64.isEmpty || signature.isEmpty) {
        throw StateError('The update manifest is incomplete.');
      }
      if (!await _verify(payloadBase64, signature)) {
        throw StateError('The update manifest signature is invalid.');
      }
      final payloadBytes = base64Decode(payloadBase64);
      if (payloadBytes.length > 16384) {
        throw StateError('The signed update payload is too large.');
      }
      final data = (jsonDecode(utf8.decode(payloadBytes)) as Map)
          .cast<String, Object?>();
      final update = _parse(data);
      final installed = int.parse((await _packageInfo()).buildNumber);
      final preferences = await SharedPreferences.getInstance();
      final now = DateTime.now().toUtc();
      await preferences.setInt(_lastCheckedKey, now.millisecondsSinceEpoch);
      final remindBuild = preferences.getInt(_remindBuildKey);
      final remindAfter = preferences.getInt(_remindAfterKey);
      final suppressed = remindBuild == update.build &&
          remindAfter != null &&
          now.isBefore(
            DateTime.fromMillisecondsSinceEpoch(remindAfter, isUtc: true),
          );
      final available = update.build > installed && !suppressed ? update : null;
      state.value = UpdateCheckState(update: available, lastCheckedAt: now);
      return available;
    } catch (error) {
      state.value = UpdateCheckState(
        update: state.value.update,
        lastCheckedAt: state.value.lastCheckedAt,
        error: error.toString().replaceFirst('Bad state: ', ''),
      );
      return null;
    }
  }

  Future<void> remindLater(KaspireUpdate update) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_remindBuildKey, update.build);
    await preferences.setInt(
      _remindAfterKey,
      DateTime.now()
          .toUtc()
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch,
    );
    state.value = UpdateCheckState(lastCheckedAt: state.value.lastCheckedAt);
  }

  KaspireUpdate _parse(Map<String, Object?> data) {
    final version = data['version']?.toString() ?? '';
    final build = data['build'];
    final minimumBuild = data['minimumBuild'];
    final apkUrl = Uri.tryParse(data['apkUrl']?.toString() ?? '');
    final notesUrl = Uri.tryParse(data['releaseNotesUrl']?.toString() ?? '');
    final sha256 = data['sha256']?.toString().toLowerCase() ?? '';
    final publishedAt =
        DateTime.tryParse(data['publishedAt']?.toString() ?? '');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build is! int ||
        build <= 0 ||
        minimumBuild is! int ||
        minimumBuild <= 0 ||
        apkUrl == null ||
        apkUrl.scheme != 'https' ||
        apkUrl.host != 'kaspire.kaslab.space' ||
        !apkUrl.path.startsWith('/downloads/Kaspire-Android-mainnet-v') ||
        notesUrl == null ||
        notesUrl.scheme != 'https' ||
        notesUrl.host != 'github.com' ||
        !notesUrl.path
            .startsWith('/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/') ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        publishedAt == null) {
      throw StateError('The signed update manifest contains invalid fields.');
    }
    return KaspireUpdate(
      version: version,
      build: build,
      minimumBuild: minimumBuild,
      critical: data['critical'] == true,
      publishedAt: publishedAt.toUtc(),
      apkUrl: apkUrl,
      sha256: sha256,
      releaseNotesUrl: notesUrl,
    );
  }
}
