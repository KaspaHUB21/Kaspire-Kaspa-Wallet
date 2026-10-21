import '../models/wallet_snapshot.dart';

class Kcc20Step {
  const Kcc20Step(this.cells, this.amount, this.compound,
      {this.requiredCells = 1, this.transactionCount = 1});
  final List<Kcc20CellRecord> cells;
  final int amount;
  final bool compound;
  final int requiredCells;

  /// Includes the final recipient payment, not just self-consolidations.
  final int transactionCount;
}

int kcc20TransactionCount(int requiredCells, [int inputLimit = 3]) {
  if (requiredCells < 1 || inputLimit < 2) {
    throw StateError('Invalid KCC20 transaction count parameters.');
  }
  return ((requiredCells - 2) ~/ (inputLimit - 1) + 1).clamp(1, requiredCells);
}

Kcc20Step planKcc20Step(List<Kcc20CellRecord> cells, int amount, int limit) {
  if (amount <= 0 || limit < 2) {
    throw StateError('Invalid KCC20 compound parameters.');
  }
  final seen = <String>{};
  final sorted = List<Kcc20CellRecord>.of(cells);
  var available = BigInt.zero;
  for (final cell in sorted) {
    if (cell.tokenAmount <= 0 ||
        !seen.add('${cell.transactionId}:${cell.index}')) {
      throw StateError('Invalid or duplicate KCC20 cell.');
    }
    available += BigInt.from(cell.tokenAmount);
    if (available > BigInt.from(0x7fffffffffffffff)) {
      throw StateError('KCC20 amount overflow.');
    }
  }
  if (available < BigInt.from(amount)) {
    throw StateError('Insufficient spendable KCC20 token balance.');
  }
  sorted.sort((a, b) {
    final value = b.tokenAmount.compareTo(a.tokenAmount);
    if (value != 0) return value;
    final tx = a.transactionId.compareTo(b.transactionId);
    return tx != 0 ? tx : a.index.compareTo(b.index);
  });
  final selected = <Kcc20CellRecord>[];
  var requiredCells = 0, covered = BigInt.zero;
  for (final cell in sorted) {
    covered += BigInt.from(cell.tokenAmount);
    requiredCells++;
    if (covered >= BigInt.from(amount)) break;
  }
  var total = 0;
  for (final cell in sorted.take(limit)) {
    selected.add(cell);
    total += cell.tokenAmount;
    if (total >= amount) break;
  }
  return Kcc20Step(selected, total < amount ? total : amount, total < amount,
      requiredCells: requiredCells,
      transactionCount: kcc20TransactionCount(requiredCells, limit));
}
