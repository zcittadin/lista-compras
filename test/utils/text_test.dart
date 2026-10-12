import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/utils/text.dart';

void main() {
  group('foldForSearch', () {
    test('tira acentos e cedilha e passa para minúsculas', () {
      expect(foldForSearch('Açúcar'), 'acucar');
      expect(foldForSearch('FEIJÃO'), 'feijao');
      expect(foldForSearch('Pão de Queijo'), 'pao de queijo');
      expect(foldForSearch('Maçã'), 'maca');
      expect(foldForSearch('Café'), 'cafe');
      expect(foldForSearch('Jalapeño'), 'jalapeno');
    });

    test('não altera o que não tem acento', () {
      expect(foldForSearch('arroz 5kg'), 'arroz 5kg');
      expect(foldForSearch(''), '');
    });

    test('ordena em português: "Açúcar" vem antes de "Arroz"', () {
      final names = ['Feijão', 'Arroz', 'Açúcar', 'banana', 'Água'];
      names.sort((a, b) => foldForSearch(a).compareTo(foldForSearch(b)));
      expect(names, ['Açúcar', 'Água', 'Arroz', 'banana', 'Feijão']);
    });

    test('ignora emojis', () {
      expect(foldForSearch('Açúcar 🍬'), 'acucar');
      expect(foldForSearch('Alface 🥬'), 'alface');
    });

    test('ordena sem o emoji atrapalhar', () {
      final names = ['Arroz carioca', 'Arroz 🍚', 'Arroz', 'Amaciante 👕'];
      names.sort((a, b) => foldForSearch(a).compareTo(foldForSearch(b)));
      expect(names.first, 'Amaciante 👕');
      // "Arroz" e "Arroz 🍚" ficam juntos, antes de "Arroz carioca".
      expect(names.indexOf('Arroz carioca'), 3);
    });
  });

  group('stripEmoji', () {
    test('remove emojis simples, compostos, bandeiras e tons de pele', () {
      expect(stripEmoji('Arroz 🍚'), 'Arroz ');
      expect(stripEmoji('Cerveja 🍺🍻'), 'Cerveja ');
      expect(stripEmoji('Amaciante 👕👖🩳👚'), 'Amaciante ');
      expect(stripEmoji('Feijão 🫘'), 'Feijão '); // emoji recente
      expect(stripEmoji('Família 👨‍👩‍👧'), 'Família '); // sequência com ZWJ
      expect(stripEmoji('Brasil 🇧🇷'), 'Brasil '); // bandeira
      expect(stripEmoji('Joia 👍🏽'), 'Joia '); // tom de pele
      expect(stripEmoji('Coração ❤️'), 'Coração '); // com seletor de variação
      expect(stripEmoji('Café ☕'), 'Café ');
    });

    test('não mexe em letras, acentos, dígitos nem símbolos comuns', () {
      expect(stripEmoji('Pão 5kg #1 (grande) - A&B'), 'Pão 5kg #1 (grande) - A&B');
      expect(stripEmoji('Água'), 'Água');
    });
  });

  group('nameKey (identidade do nome do produto)', () {
    test('ignora maiúsculas, espaços sobrando e emojis', () {
      expect(nameKey('Arroz'), 'arroz');
      expect(nameKey('  ARROZ  '), 'arroz');
      expect(nameKey('Arroz 🍚'), 'arroz');
      expect(nameKey('🍚 Arroz'), 'arroz');
      expect(nameKey('Arroz   integral 🍚'), 'arroz integral');
      expect(nameKey('Cerveja 🍺🍻'), nameKey('cerveja'));
    });

    test('acentos contam (como no servidor)', () {
      expect(nameKey('Açúcar'), isNot(nameKey('Acucar')));
    });

    test('nome só de emojis não colide com outros nomes só de emojis', () {
      expect(nameKey('🍚'), '🍚');
      expect(nameKey('🍚'), isNot(nameKey('🍺')));
    });
  });
}
