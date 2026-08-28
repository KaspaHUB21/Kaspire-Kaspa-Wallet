import '../number_format.dart';

class WalletSnapshot {
  const WalletSnapshot({
    required this.balanceSompi,
    required this.kasUsd,
    this.usdToFiat = 1,
    this.fiatCode = 'USD',
    this.fiatSymbol = r'$',
    required this.transactions,
    required this.krc20Tokens,
    this.kcc20Tokens = const [],
    required this.krc721Collections,
    required this.knsDomains,
    this.assetWarning,
    this.hasMoreTransactions = false,
    this.utxoCount = 0,
  });

  final int balanceSompi;
  final double? kasUsd;
  final double usdToFiat;
  final String fiatCode;
  final String fiatSymbol;
  final List<WalletTransaction> transactions;
  final List<WalletAsset> krc20Tokens;
  final List<WalletAsset> kcc20Tokens;
  final List<WalletAsset> krc721Collections;
  final List<KnsDomain> knsDomains;
  final String? assetWarning;
  final bool hasMoreTransactions;
  final int utxoCount;

  double get balanceKas => balanceSompi / 100000000;
  double? get fiatValue => kasUsd == null || !usdToFiat.isFinite
      ? null
      : balanceKas * kasUsd! * usdToFiat;

  WalletSnapshot withTransactions(List<WalletTransaction> value) =>
      WalletSnapshot(
        balanceSompi: balanceSompi,
        kasUsd: kasUsd,
        usdToFiat: usdToFiat,
        fiatCode: fiatCode,
        fiatSymbol: fiatSymbol,
        transactions: value,
        krc20Tokens: krc20Tokens,
        kcc20Tokens: kcc20Tokens,
        krc721Collections: krc721Collections,
        knsDomains: knsDomains,
        assetWarning: assetWarning,
        hasMoreTransactions: hasMoreTransactions,
        utxoCount: utxoCount,
      );
}

class WalletAsset {
  const WalletAsset({
    required this.symbol,
    required this.balance,
    required this.kind,
    this.imageUrl,
    this.id,
    this.decimals = 0,
    this.rawBalance,
    this.priceKas,
    this.priceUsd,
    this.covenantId,
    this.templateHash,
    this.validationStatus,
    this.kcc20Cells = const [],
    this.discoveryComplete = true,
    this.standard = 'legacy-kcc20',
  });

  final String symbol;
  final double balance;
  final String kind;
  final String? imageUrl;
  final String? id;
  final int decimals;
  final String? rawBalance;
  final double? priceKas;
  final double? priceUsd;
  final String? covenantId;
  final String? templateHash;
  final String? validationStatus;
  final List<Kcc20CellRecord> kcc20Cells;
  final bool discoveryComplete;
  final String standard;
}

class Kcc20CellRecord {
  const Kcc20CellRecord({
    required this.covenantId,
    required this.transactionId,
    required this.index,
    required this.valueSompi,
    required this.blockDaaScore,
    required this.scriptPublicKey,
    required this.tokenAmount,
    this.isMinter = false,
    this.redeemScript,
  });

  final String covenantId;
  final String transactionId;
  final int index;
  final int valueSompi;
  final int blockDaaScore;
  final String scriptPublicKey;
  final int tokenAmount;
  final bool isMinter;
  final String? redeemScript;

  Map<String, Object?> toJson() => {
        'covenantId': covenantId,
        'transactionId': transactionId,
        'index': index,
        'valueSompi': valueSompi,
        'blockDaaScore': blockDaaScore,
        'scriptPublicKey': scriptPublicKey,
        'tokenAmount': tokenAmount,
        'isMinter': isMinter,
        if (redeemScript != null) 'redeemScript': redeemScript,
      };
}

class NftCollectionPage {
  const NftCollectionPage({
    required this.ticker,
    required this.total,
    required this.nfts,
    this.nextOffset,
  });

  final String ticker;
  final int total;
  final List<WalletNft> nfts;
  final int? nextOffset;
}

class WalletNft {
  const WalletNft({
    required this.ticker,
    required this.tokenId,
    this.imageUrl,
    this.rarityRank,
    this.nexusUrl,
  });

  final String ticker;
  final String tokenId;
  final String? imageUrl;
  final int? rarityRank;
  final String? nexusUrl;
}

class KnsDomain {
  const KnsDomain({required this.name, this.status, this.assetId});
  final String name;
  final String? status;
  final String? assetId;
}

class WalletTransaction {
  const WalletTransaction({
    required this.id,
    required this.timestamp,
    required this.amountSompi,
    required this.incoming,
    this.assetKind = 'KAS',
    this.assetSymbol = 'KAS',
    this.displayAmount,
    this.operationLabel,
    this.amountLabelOverride,
    this.tokenId,
    this.counterparty,
    this.from = const [],
    this.to = const [],
    this.feeSompi,
    this.totalInputSompi,
    this.totalOutputSompi,
    this.inputCount,
    this.outputCount,
    this.blockDaaScore,
    this.mass,
    this.isCoinbase = false,
    this.status = TransactionStatus.confirmed,
  });

  factory WalletTransaction.fromStoredJson(Map<String, Object?> json) =>
      WalletTransaction(
        id: json['transactionId']!.toString(),
        timestamp: DateTime.parse(json['timestamp']!.toString()),
        amountSompi: (json['amountSompi'] as num?)?.toInt() ?? 0,
        incoming: json['incoming'] == true,
        assetKind: json['assetKind']?.toString() ?? 'ASSET',
        assetSymbol: json['assetSymbol']?.toString(),
        displayAmount: json['displayAmount']?.toString(),
        operationLabel: json['operationLabel']?.toString(),
        amountLabelOverride: json['amountLabelOverride']?.toString(),
        tokenId: json['tokenId']?.toString(),
        counterparty: json['counterparty']?.toString(),
        from: _storedParties(json['from']),
        to: _storedParties(json['to']),
        feeSompi: (json['feeSompi'] as num?)?.toInt(),
        totalInputSompi: (json['totalInputSompi'] as num?)?.toInt(),
        totalOutputSompi: (json['totalOutputSompi'] as num?)?.toInt(),
        inputCount: (json['inputCount'] as num?)?.toInt(),
        outputCount: (json['outputCount'] as num?)?.toInt(),
        blockDaaScore: (json['blockDaaScore'] as num?)?.toInt(),
        mass: (json['mass'] as num?)?.toInt(),
        isCoinbase: json['isCoinbase'] == true,
        status: TransactionStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => TransactionStatus.accepted,
        ),
      );

  final String id;
  final DateTime timestamp;
  final int amountSompi;
  final bool incoming;
  final String assetKind;
  final String? assetSymbol;
  final String? displayAmount;
  final String? operationLabel;
  final String? amountLabelOverride;
  final String? tokenId;
  final String? counterparty;
  final List<TransactionParty> from;
  final List<TransactionParty> to;
  final int? feeSompi;
  final int? totalInputSompi;
  final int? totalOutputSompi;
  final int? inputCount;
  final int? outputCount;
  final int? blockDaaScore;
  final int? mass;
  final bool isCoinbase;
  final TransactionStatus status;
  double get amountKas => amountSompi / 100000000;

  String get amountLabel {
    if (amountLabelOverride != null && amountLabelOverride!.isNotEmpty) {
      return amountLabelOverride!;
    }
    if (assetKind == 'KAS') {
      return '${formatEnglishNumber(amountKas, decimals: 4)} KAS';
    }
    final amount = displayAmount == null || displayAmount!.isEmpty
        ? ''
        : '${formatEnglishDecimal(displayAmount!)} ';
    final token =
        assetKind == 'KRC-721' && tokenId != null && tokenId!.isNotEmpty
            ? ' #$tokenId'
            : '';
    return '$amount${assetSymbol ?? assetKind}$token'.trim();
  }

  static List<TransactionParty> _storedParties(Object? value) =>
      (value as List? ?? const [])
          .whereType<Map>()
          .map((item) => TransactionParty(
                address: item['address']?.toString() ?? '',
                amountSompi: (item['amountSompi'] as num?)?.toInt(),
                ownerId: item['ownerId']?.toString(),
              ))
          .where((item) => item.address.isNotEmpty)
          .toList();
}

class TransactionParty {
  const TransactionParty({
    required this.address,
    this.amountSompi,
    this.ownerId,
  });

  final String address;
  final int? amountSompi;
  final String? ownerId;
}

enum TransactionStatus { pending, accepted, confirmed, failed }
