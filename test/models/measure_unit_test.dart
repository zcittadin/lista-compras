import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/item.dart';
import 'package:lista_compras/models/measure_unit.dart';

Item itemWith({num? quantity, String? unit}) => Item(
      id: 'i',
      listId: 'l',
      name: 'Arroz',
      checked: false,
      quantity: quantity,
      unit: unit,
    );

void main() {
  group('MeasureUnit.parse', () {
    test('reconhece o símbolo ignorando maiúsculas e espaços', () {
      expect(MeasureUnit.parse('kg'), MeasureUnit.kg);
      expect(MeasureUnit.parse('Kg'), MeasureUnit.kg);
      expect(MeasureUnit.parse(' KG '), MeasureUnit.kg);
      expect(MeasureUnit.parse('l'), MeasureUnit.l);
      expect(MeasureUnit.parse('ml'), MeasureUnit.ml);
      expect(MeasureUnit.parse('UN'), MeasureUnit.un);
    });

    test('devolve null para vazio, nulo ou desconhecido', () {
      expect(MeasureUnit.parse(null), isNull);
      expect(MeasureUnit.parse(''), isNull);
      expect(MeasureUnit.parse('  '), isNull);
      expect(MeasureUnit.parse('lata'), isNull);
    });

    test('reconhece nomes por extenso e variações comuns', () {
      expect(MeasureUnit.parse('quilos'), MeasureUnit.kg);
      expect(MeasureUnit.parse('Quilograma'), MeasureUnit.kg);
      expect(MeasureUnit.parse('gramas'), MeasureUnit.g);
      expect(MeasureUnit.parse('LT'), MeasureUnit.l);
      expect(MeasureUnit.parse('litros'), MeasureUnit.l);
      expect(MeasureUnit.parse('Und.'), MeasureUnit.un);
      expect(MeasureUnit.parse('unidades'), MeasureUnit.un);
      expect(MeasureUnit.parse('dúzia'), MeasureUnit.dz);
      expect(MeasureUnit.parse('duzia'), MeasureUnit.dz);
      expect(MeasureUnit.parse('Pacote'), MeasureUnit.pct);
      expect(MeasureUnit.parse('caixa'), MeasureUnit.cx);
      expect(MeasureUnit.parse('mt'), MeasureUnit.m);
      expect(MeasureUnit.parse('metros'), MeasureUnit.m);
    });

    test('todo apelido aponta para uma única unidade', () {
      // Se dois apelidos iguais existissem em unidades diferentes, o último
      // venceria em silêncio.
      final all = <String>[
        for (final u in MeasureUnit.values) u.symbol.toLowerCase(),
        for (final aliases in MeasureUnit.aliasesForTest.values) ...aliases,
      ];
      expect(all.toSet().length, all.length);
    });

    test('todo símbolo é único mesmo sem diferenciar maiúsculas', () {
      final keys = MeasureUnit.values.map((u) => u.symbol.toLowerCase()).toSet();
      expect(keys.length, MeasureUnit.values.length);
    });

    test('display padroniza o que reconhece e preserva o resto', () {
      expect(MeasureUnit.display('Kg'), 'kg');
      expect(MeasureUnit.display('ML'), 'mL');
      expect(MeasureUnit.display(' lata '), 'lata');
    });
  });

  group('Item.quantityLabel', () {
    test('mostra a unidade padronizada', () {
      expect(itemWith(quantity: 2, unit: 'Kg').quantityLabel, '2 kg');
      expect(itemWith(quantity: 0.5, unit: 'l').quantityLabel, '0.5 L');
    });

    test('mantém unidades antigas que não estão no enum', () {
      expect(itemWith(quantity: 3, unit: 'lata').quantityLabel, '3 lata');
    });

    test('sem quantidade não mostra nada, mesmo com unidade', () {
      expect(itemWith(unit: 'kg').quantityLabel, '');
    });

    test('quantidade sem unidade mostra só o número', () {
      expect(itemWith(quantity: 3).quantityLabel, '3');
      expect(itemWith(quantity: 3, unit: '  ').quantityLabel, '3');
    });
  });
}
