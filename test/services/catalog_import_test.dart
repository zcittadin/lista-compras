import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/services/catalog_import.dart';

CatalogPreview parse(String text, {List<String> existing = const []}) =>
    CatalogParser.parse(text, existingNames: existing);

List<String> names(Iterable<ImportEntry> entries) => [for (final e in entries) e.name];

void main() {
  group('leitura de bytes', () {
    test('UTF-8 simples', () {
      final r = CatalogParser.decode(Uint8List.fromList(utf8.encode('Açúcar 🍬\nFeijão')));
      expect(r.text, 'Açúcar 🍬\nFeijão');
      expect(r.legacyEncoding, isFalse);
    });

    test('UTF-8 com BOM: o BOM não vira parte do primeiro nome', () {
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('Arroz')]);
      expect(CatalogParser.decode(bytes).text, 'Arroz');
    });

    test('Windows-1252 (o "CSV" padrão do Excel em português) é reconhecido', () {
      // "Açúcar" e "Feijão" em Latin-1/Windows-1252: não é UTF-8 válido.
      final bytes = Uint8List.fromList([0x41, 0xE7, 0xFA, 0x63, 0x61, 0x72, 0x0A, 0x46, 0x65, 0x69, 0x6A, 0xE3, 0x6F]);
      final r = CatalogParser.decode(bytes);
      expect(r.text, 'Açúcar\nFeijão');
      expect(r.legacyEncoding, isTrue);
    });

    test('Windows-1252: aspas tipográficas e euro (0x80–0x9F)', () {
      final bytes = Uint8List.fromList([0x93, 0x4F, 0x6B, 0x94, 0x20, 0x80, 0x96]);
      expect(CatalogParser.decode(bytes).text, '“Ok” €–');
    });

    test('UTF-16 com BOM (o "Texto Unicode" do Excel), nas duas ordens de bytes', () {
      final le = Uint8List.fromList([0xFF, 0xFE, ...'Pão'.codeUnits.expand((u) => [u & 0xFF, u >> 8])]);
      final be = Uint8List.fromList([0xFE, 0xFF, ...'Pão'.codeUnits.expand((u) => [u >> 8, u & 0xFF])]);
      expect(CatalogParser.decode(le).text, 'Pão');
      expect(CatalogParser.decode(be).text, 'Pão');
    });

    test('planilha do Excel (.xlsx) ou documento do Office: mensagem explica como exportar CSV', () {
      final xlsx = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00]);
      final xls = Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]);
      for (final bytes in [xlsx, xls]) {
        expect(
          () => CatalogParser.decode(bytes),
          throwsA(isA<CatalogImportException>().having((e) => e.message, 'message', contains('CSV'))),
        );
      }
    });

    test('PDF e arquivos binários também são recusados', () {
      final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\n'));
      final binary = Uint8List.fromList([0x41, 0x00, 0x42, 0x00, 0xFF, 0x10]);
      expect(() => CatalogParser.decode(pdf), throwsA(isA<CatalogImportException>()));
      expect(() => CatalogParser.decode(binary), throwsA(isA<CatalogImportException>()));
    });

    test('vazio dá texto vazio', () {
      expect(CatalogParser.decode(Uint8List(0)).text, '');
    });

    test('arquivo grande demais é recusado com mensagem para o usuário', () {
      final big = Uint8List(CatalogParser.maxBytes + 1);
      expect(
        () => CatalogParser.decode(big),
        throwsA(isA<CatalogImportException>().having((e) => e.message, 'message', contains('1 MB'))),
      );
    });
  });

  group('lista simples (um nome por linha)', () {
    test('lê os nomes, ignora linhas em branco e apara espaços', () {
      final p = parse('Arroz\n\n  Feijão  \n\t\nMacarrão');
      expect(names(p.toImport), ['Arroz', 'Feijão', 'Macarrão']);
      expect(p.delimiter, isNull);
      expect(p.hadHeader, isFalse);
    });

    test('vírgula dentro do nome não parte a linha quando poucas linhas a têm', () {
      final p = parse('Arroz, tipo 1\nFeijão\nMacarrão\nLeite');
      expect(names(p.toImport), ['Arroz, tipo 1', 'Feijão', 'Macarrão', 'Leite']);
      expect(p.delimiter, isNull);
    });

    test('aceita finais de linha do Windows, do Unix e do Mac antigo', () {
      for (final eol in ['\r\n', '\n', '\r']) {
        expect(names(parse('Arroz${eol}Feijão${eol}Leite').toImport), ['Arroz', 'Feijão', 'Leite'], reason: eol);
      }
    });

    test('mantém acentos e emojis', () {
      expect(names(parse('Açúcar 🍬\nArroz 🍚').toImport), ['Açúcar 🍬', 'Arroz 🍚']);
    });

    test('limpa caracteres de controle e espaços repetidos', () {
      final p = parse('Arroz\u0000  tipo\u0007 1\nLeite integral');
      expect(names(p.toImport), ['Arroz tipo 1', 'Leite integral']);
    });

    test('texto vazio ou só espaços não dá nenhuma linha', () {
      expect(parse('').isEmpty, isTrue);
      expect(parse('  \n\n \t ').isEmpty, isTrue);
    });
  });

  group('CSV com colunas', () {
    test('cabeçalho nome;unidade (padrão do Excel em português)', () {
      final p = parse('nome;unidade\nArroz;kg\nLeite;L\nOvos;dz');
      expect(p.hadHeader, isTrue);
      expect(p.delimiter, ';');
      expect([for (final e in p.toImport) (e.name, e.unit)], [('Arroz', 'kg'), ('Leite', 'L'), ('Ovos', 'dz')]);
    });

    test('cabeçalho com vírgula e outros nomes de coluna', () {
      final p = parse('Produto,Medida\nArroz,Kg\nCafé,g');
      expect(p.hadHeader, isTrue);
      expect(p.delimiter, ',');
      expect([for (final e in p.toImport) (e.name, e.unit)], [('Arroz', 'kg'), ('Café', 'g')]);
    });

    test('colunas em outra ordem e extras são tratadas pelo cabeçalho', () {
      final p = parse('codigo;unidade;nome;preco\n1;kg;Arroz;5,90\n2;L;Leite;4,50');
      expect([for (final e in p.toImport) (e.name, e.unit)], [('Arroz', 'kg'), ('Leite', 'L')]);
    });

    test('separado por tab', () {
      final p = parse('nome\tunidade\nArroz\tkg');
      expect(p.delimiter, '\t');
      expect([for (final e in p.toImport) (e.name, e.unit)], [('Arroz', 'kg')]);
    });

    test('sem cabeçalho: primeira coluna é o nome e a segunda a unidade', () {
      final p = parse('Arroz;kg\nLeite;L\nSal;');
      expect(p.hadHeader, isFalse);
      expect([for (final e in p.toImport) (e.name, e.unit)], [('Arroz', 'kg'), ('Leite', 'L'), ('Sal', null)]);
    });

    test('cabeçalho só com o nome', () {
      final p = parse('nome\nArroz\nFeijão');
      expect(p.hadHeader, isTrue);
      expect(names(p.toImport), ['Arroz', 'Feijão']);
    });

    test('só o cabeçalho: nada para importar', () {
      final p = parse('nome;unidade\n');
      expect(p.hadHeader, isTrue);
      expect(p.isEmpty, isTrue);
    });

    test('campos entre aspas: separador dentro do nome, aspas duplicadas e quebra de linha', () {
      final p = parse('nome;unidade\n"Arroz; tipo 1";kg\n"Leite ""Tipo A""";L\n"Suco\nde uva";mL');
      expect(names(p.toImport), ['Arroz; tipo 1', 'Leite "Tipo A"', 'Suco de uva']);
      expect([for (final e in p.toImport) e.unit], ['kg', 'L', 'mL']);
    });

    test('aspas sem fechar não derrubam a leitura', () {
      final p = parse('nome;unidade\n"Arroz;kg\nLeite;L');
      expect(p.entries, isNotEmpty);
    });

    test('vírgula como separador não parte nomes com ponto e vírgula entre aspas', () {
      final p = parse('nome,unidade\n"Arroz; tipo 1",kg');
      expect(names(p.toImport), ['Arroz; tipo 1']);
    });
  });

  group('unidade', () {
    test('reconhece símbolos, nomes por extenso e variações', () {
      final p = parse('nome;unidade\nA;Kg\nB;quilos\nC;LT\nD;und.\nE;pacote\nF;duzia\nG;mt\nH;ML');
      expect([for (final e in p.toImport) e.unit], ['kg', 'kg', 'L', 'un', 'pct', 'dz', 'm', 'mL']);
    });

    test('unidade desconhecida é ignorada, mas o produto entra e a linha é sinalizada', () {
      final p = parse('nome;unidade\nSardinha;lata\nArroz;kg');
      final sardinha = p.toImport.first;
      expect(sardinha.status, EntryStatus.fresh);
      expect(sardinha.unit, isNull);
      expect(sardinha.ignoredUnit, 'lata');
      expect(names(p.unknownUnits), ['Sardinha']);
    });

    test('sem unidade na linha: unidade nula e nenhum aviso', () {
      final p = parse('nome;unidade\nSal;');
      expect(p.toImport.single.unit, isNull);
      expect(p.toImport.single.ignoredUnit, isNull);
    });
  });

  group('linhas inválidas', () {
    test('sem nome', () {
      final p = parse('nome;unidade\n;kg\nArroz;kg');
      expect(p.invalid.single.status, EntryStatus.nameEmpty);
      expect(names(p.toImport), ['Arroz']);
    });

    test('nome acima do limite do banco, e o limite exato é aceito', () {
      final p = parse('${'x' * 120}\n${'y' * 121}');
      expect(p.toImport.single.name, 'x' * 120);
      expect(p.invalid.single.status, EntryStatus.nameTooLong);
      expect(p.invalid.single.name.length, lessThan(60)); // truncado para mostrar na tela
    });
  });

  group('duplicatas', () {
    test('repetição dentro do arquivo: vale a primeira, ignorando maiúsculas e emojis', () {
      final p = parse('Arroz\narroz\nArroz 🍚\nFeijão');
      expect(names(p.toImport), ['Arroz', 'Feijão']);
      expect(p.duplicatesInFile.map((e) => e.existingName), ['Arroz', 'Arroz']);
    });

    test('já existe no catálogo: ignorado, citando o nome que existe', () {
      final p = parse('Arroz\nFeijão', existing: ['Arroz 🍚']);
      expect(names(p.toImport), ['Feijão']);
      expect(p.alreadyExist.single.existingName, 'Arroz 🍚');
    });

    test('acentos contam: "Acucar" não é "Açúcar"', () {
      final p = parse('Acucar', existing: ['Açúcar']);
      expect(names(p.toImport), ['Acucar']);
    });

    test('importar de novo o mesmo arquivo não traz nada novo', () {
      final first = parse('nome;unidade\nArroz;kg\nLeite;L');
      final again = parse('nome;unidade\nArroz;kg\nLeite;L', existing: names(first.toImport));
      expect(again.toImport, isEmpty);
      expect(again.alreadyExist, hasLength(2));
    });
  });

  group('numeração das linhas', () {
    test('conta o cabeçalho e as linhas em branco', () {
      final p = parse('nome;unidade\nArroz;kg\n\n;kg\nFeijão;kg');
      expect([for (final e in p.entries) (e.line, e.status)], [
        (2, EntryStatus.fresh),
        (4, EntryStatus.nameEmpty),
        (5, EntryStatus.fresh),
      ]);
    });

    test('um campo com quebra de linha entre aspas desloca as linhas seguintes', () {
      final p = parse('nome;unidade\n"Suco\nde uva";mL\nArroz;kg');
      expect([for (final e in p.entries) e.line], [2, 4]);
    });
  });

  group('limites', () {
    test('2000 linhas é aceito', () {
      final text = List.generate(CatalogParser.maxRows, (i) => 'Produto $i').join('\n');
      expect(parse(text).toImport, hasLength(CatalogParser.maxRows));
    });

    test('mais que isso é recusado', () {
      final text = List.generate(CatalogParser.maxRows + 5, (i) => 'Produto $i').join('\n');
      expect(() => parse(text), throwsA(isA<CatalogImportException>()));
    });
  });

  group('exportar e importar de volta', () {
    const products = [
      (name: 'Arroz 🍚', unit: 'kg'),
      (name: 'Água mineral 💧', unit: 'mL'),
      (name: 'Sal', unit: null),
      (name: 'Arroz; tipo "1"', unit: 'kg'),
    ];

    test('o CSV tem cabeçalho e protege separadores e aspas', () {
      final csv = buildCatalogCsv(products);
      expect(csv.split('\n').first, 'nome;unidade');
      expect(csv, contains('"Arroz; tipo ""1""";kg'));
      expect(csv, contains('Sal;\n'));
    });

    test('ida e volta preserva nomes, emojis e unidades', () {
      final p = parse(buildCatalogCsv(products));
      expect(p.hadHeader, isTrue);
      expect([for (final e in p.toImport) (name: e.name, unit: e.unit)], products);
    });

    test('os bytes têm BOM (Excel) e voltam pelo leitor de arquivos', () {
      final bytes = catalogCsvBytes(products);
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);

      final decoded = CatalogParser.decode(bytes);
      final p = parse(decoded.text);
      expect(decoded.legacyEncoding, isFalse);
      expect([for (final e in p.toImport) (name: e.name, unit: e.unit)], products);
    });

    test('catálogo vazio exporta só o cabeçalho', () {
      expect(buildCatalogCsv(const []), 'nome;unidade\n');
    });
  });

  group('contagens da pré-visualização', () {
    test('cada categoria é separada', () {
      final p = parse(
        'nome;unidade\nArroz;kg\narroz;kg\nFeijão;kg\n;kg\nSardinha;lata\nLeite;L',
        existing: ['Leite'],
      );
      expect(names(p.toImport), ['Arroz', 'Feijão', 'Sardinha']);
      expect(p.duplicatesInFile, hasLength(1));
      expect(p.invalid, hasLength(1));
      expect(p.alreadyExist, hasLength(1));
      expect(p.unknownUnits, hasLength(1));
    });
  });
}
