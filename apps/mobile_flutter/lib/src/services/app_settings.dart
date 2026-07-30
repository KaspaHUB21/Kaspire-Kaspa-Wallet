import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum KaspireTheme {
  midnight,
  emerald,
  amethyst,
  sakura,
  crimson,
  phoenix,
  cypherpunk,
}

enum FiatCurrency {
  usd('USD', r'$', 'US Dollar'),
  eur('EUR', '€', 'Euro'),
  gbp('GBP', '£', 'British Pound'),
  aud('AUD', r'A$', 'Australian Dollar'),
  cad('CAD', r'C$', 'Canadian Dollar'),
  jpy('JPY', '¥', 'Japanese Yen'),
  cny('CNY', 'CN¥', 'Chinese Yuan'),
  inr('INR', '₹', 'Indian Rupee'),
  brl('BRL', r'R$', 'Brazilian Real'),
  chf('CHF', 'CHF', 'Swiss Franc'),
  krw('KRW', '₩', 'South Korean Won'),
  sgd('SGD', r'S$', 'Singapore Dollar'),
  hkd('HKD', r'HK$', 'Hong Kong Dollar'),
  nzd('NZD', r'NZ$', 'New Zealand Dollar'),
  mxn('MXN', r'MX$', 'Mexican Peso'),
  zar('ZAR', 'R', 'South African Rand'),
  sek('SEK', 'kr', 'Swedish Krona'),
  nok('NOK', 'kr', 'Norwegian Krone'),
  dkk('DKK', 'kr', 'Danish Krone'),
  pln('PLN', 'zł', 'Polish Zloty'),
  tryCurrency('TRY', '₺', 'Turkish Lira'),
  idr('IDR', 'Rp', 'Indonesian Rupiah'),
  aed('AED', 'د.إ', 'UAE Dirham'),
  sar('SAR', '﷼', 'Saudi Riyal'),
  thb('THB', '฿', 'Thai Baht'),
  myr('MYR', 'RM', 'Malaysian Ringgit'),
  php('PHP', '₱', 'Philippine Peso');

  const FiatCurrency(this.code, this.symbol, this.label);
  final String code;
  final String symbol;
  final String label;
}

class AppSettings {
  static const _lockMinutesKey = 'security_lock_minutes_v1';
  static const _showSubwalletsKey = 'wallet_show_subwallets_v1';
  static const _themeKey = 'appearance_theme_v1';
  static const _uppercaseButtonsKey = 'appearance_uppercase_buttons_v1';
  static const _lastBackgroundAtKey = 'security_last_background_at_v1';
  static const _fiatCurrencyKey = 'appearance_fiat_currency_v1';

  static final ValueNotifier<int> lockMinutes = ValueNotifier(15);
  static final ValueNotifier<bool> showSubwallets = ValueNotifier(true);
  static final ValueNotifier<bool> uppercaseButtons = ValueNotifier(true);
  static final ValueNotifier<KaspireTheme> theme =
      ValueNotifier(KaspireTheme.midnight);
  static final ValueNotifier<FiatCurrency> fiatCurrency =
      ValueNotifier(FiatCurrency.usd);

  static Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    lockMinutes.value = preferences.getInt(_lockMinutesKey) ?? 15;
    showSubwallets.value = preferences.getBool(_showSubwalletsKey) ?? true;
    uppercaseButtons.value = preferences.getBool(_uppercaseButtonsKey) ?? true;
    final storedCurrency = preferences.getString(_fiatCurrencyKey);
    fiatCurrency.value = FiatCurrency.values.firstWhere(
      (item) => item.code == storedCurrency,
      orElse: () => FiatCurrency.usd,
    );
    final stored = preferences.getString(_themeKey);
    theme.value = KaspireTheme.values.firstWhere(
      (item) => item.name == stored,
      orElse: () => KaspireTheme.midnight,
    );
  }

  static Future<void> setLockMinutes(int value) async {
    if (!const {0, 5, 10, 15}.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported lock interval');
    }
    lockMinutes.value = value;
    await (await SharedPreferences.getInstance())
        .setInt(_lockMinutesKey, value);
  }

  static Future<void> setShowSubwallets(bool value) async {
    showSubwallets.value = value;
    await (await SharedPreferences.getInstance())
        .setBool(_showSubwalletsKey, value);
  }

  static Future<void> setTheme(KaspireTheme value) async {
    theme.value = value;
    await (await SharedPreferences.getInstance())
        .setString(_themeKey, value.name);
  }

  static Future<void> setUppercaseButtons(bool value) async {
    uppercaseButtons.value = value;
    await (await SharedPreferences.getInstance())
        .setBool(_uppercaseButtonsKey, value);
  }

  static Future<void> setFiatCurrency(FiatCurrency value) async {
    fiatCurrency.value = value;
    await (await SharedPreferences.getInstance())
        .setString(_fiatCurrencyKey, value.code);
  }

  static Future<void> recordBackgroundedAt(DateTime value) async {
    await (await SharedPreferences.getInstance())
        .setInt(_lastBackgroundAtKey, value.millisecondsSinceEpoch);
  }

  static Future<DateTime?> lastBackgroundedAt() async {
    final milliseconds =
        (await SharedPreferences.getInstance()).getInt(_lastBackgroundAtKey);
    return milliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }
}

String displayLabel(String uppercase) {
  if (AppSettings.uppercaseButtons.value) return uppercase;
  const preserved = {
    'KAS': 'KAS',
    'KRC-20': 'KRC-20',
    'KRC-721': 'KRC-721',
    'KCC20': 'KCC20',
    'KNS': 'KNS',
    'NFT': 'NFT',
    'PIN': 'PIN',
    'QR': 'QR',
    'TX': 'TX',
    'DAPP': 'dApp',
    'KASPIRE': 'Kaspire',
  };
  return uppercase.split(' ').map((word) {
    final punctuation = word.endsWith('…') ? '…' : '';
    final raw = punctuation.isEmpty ? word : word.substring(0, word.length - 1);
    final kept = preserved[raw];
    if (kept != null) return '$kept$punctuation';
    if (raw.isEmpty) return punctuation;
    final lower = raw.toLowerCase();
    return '${lower[0].toUpperCase()}${lower.substring(1)}$punctuation';
  }).join(' ');
}

String buttonLabel(String uppercase) => displayLabel(uppercase);
