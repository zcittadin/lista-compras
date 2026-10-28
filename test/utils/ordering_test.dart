import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/utils/ordering.dart';

void main() {
  group('positionBetween', () {
    test('lista vazia', () => expect(positionBetween(null, null), 1));
    test('no início: antes do primeiro', () => expect(positionBetween(null, 3), 2));
    test('no fim: depois do último', () => expect(positionBetween(3, null), 4));
    test('no meio: a média dos vizinhos', () => expect(positionBetween(2, 3), 2.5));
    test('posições negativas também funcionam', () => expect(positionBetween(null, -1), -2));

    test('a posição calculada fica sempre estritamente entre os vizinhos', () {
      var below = 2.0;
      for (var i = 0; i < 15; i++) {
        final p = positionBetween(1, below);
        expect(p, greaterThan(1));
        expect(p, lessThan(below));
        below = p;
      }
    });
  });

  group('needsRebalance', () {
    test('com espaço não precisa', () => expect(needsRebalance(1, 2), isFalse));
    test('sem vizinho de um lado nunca precisa', () {
      expect(needsRebalance(null, 1), isFalse);
      expect(needsRebalance(1, null), isFalse);
    });
    test('vão menor que o mínimo precisa', () => expect(needsRebalance(1, 1 + minGap / 2), isTrue));
    test('vizinhos com a mesma posição (empate) precisa', () => expect(needsRebalance(2, 2), isTrue));
    test('vizinhos fora de ordem (edições simultâneas) precisa', () => expect(needsRebalance(3, 2), isTrue));

    test('cabem cerca de 20 movimentos seguidos no mesmo vão antes de precisar', () {
      double above = 1, below = 2;
      var moves = 0;
      while (!needsRebalance(above, below)) {
        below = positionBetween(above, below);
        moves++;
      }
      expect(moves, inInclusiveRange(15, 25));
    });
  });
}
