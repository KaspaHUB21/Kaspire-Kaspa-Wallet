import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/models/wallet_snapshot.dart';
import 'package:kasvault_wallet/src/services/kcc20_compound.dart';

List<Kcc20CellRecord> cells(List<int> amounts) => List.generate(
    amounts.length,
    (i) => Kcc20CellRecord(
        covenantId: 'c' * 64,
        transactionId: i.toRadixString(16).padLeft(64, '0'),
        index: 0,
        valueSompi: 100000000,
        blockDaaScore: 123,
        scriptPublicKey: 'aa',
        tokenAmount: amounts[i]));
void main() {
  test('10-input boundary has one payment through ten and two at eleven', () {
    for (final count in [1, 3, 7, 10, 11, 19, 20]) {
      final step = planKcc20Step(cells(List.filled(count, 10)), count * 10, 10);
      expect(step.compound, count > 10);
      expect(step.cells.length, count > 10 ? 10 : count);
      expect(
          step.transactionCount,
          count <= 10
              ? 1
              : count <= 19
                  ? 2
                  : 3);
    }
  });
  test(
      'transaction estimate includes final payment and scales by cells, not units',
      () {
    for (final entry
        in {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 3, 7: 3, 1000: 500}.entries) {
      expect(kcc20TransactionCount(entry.key), entry.value);
    }
    expect(kcc20TransactionCount(4, 2), 3);
    expect(() => kcc20TransactionCount(0), throwsStateError);
    expect(() => kcc20TransactionCount(4, 1), throwsStateError);
    final huge = planKcc20Step(cells([100000000000000]), 100000000000000, 3);
    expect(huge.transactionCount, 1);
    expect(huge.requiredCells, 1);
    final fragmented = planKcc20Step(cells([10, 10, 10, 10, 10, 10]), 60, 3);
    expect(fragmented.transactionCount, 3);
    expect(fragmented.requiredCells, 6);
  });
  test('largest cells first avoid unnecessary compounds', () {
    final p = planKcc20Step(cells([1, 1, 1, 90]), 85, 3);
    expect(p.compound, false);
    expect(p.cells.length, 1);
    expect(p.amount, 85);
  });
  test('fragmented balance self-compounds full selected amount', () {
    final p = planKcc20Step(cells([10, 10, 10, 10]), 40, 3);
    expect(p.compound, true);
    expect(p.amount, 30);
    expect(p.cells.length, 3);
  });
  test('legacy two-cell limit is retained', () {
    final p = planKcc20Step(cells([10, 10, 10]), 30, 2);
    expect(p.compound, true);
    expect(p.amount, 20);
  });
  test('refuses duplicate, overflow and insufficient inputs', () {
    final row = cells([1]).single;
    expect(() => planKcc20Step([row, row], 1, 3), throwsStateError);
    expect(() => planKcc20Step(cells([0x7fffffffffffffff, 1]), 1, 3),
        throwsStateError);
    expect(() => planKcc20Step(cells([1, 2]), 4, 3), throwsStateError);
  });
}
