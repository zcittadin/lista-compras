import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/measure_unit.dart';
import 'package:lista_compras/services/catalog_import.dart';

import '../support/mojibake.dart';

/// Garante que o catálogo inicial que acompanha o projeto (`docs/catalogo_inicial.csv`)
/// é válido para o importador: sem linhas ruins, sem repetidos e só com unidades do app.
void main() {
  final file = File('docs/catalogo_inicial.csv');

  test('o arquivo existe e é lido como UTF-8', () {
    expect(file.existsSync(), isTrue);
    final decoded = CatalogParser.decode(file.readAsBytesSync());
    expect(decoded.legacyEncoding, isFalse);
  });

  test('importa limpo: cabeçalho, sem linhas inválidas, repetidos nem unidades desconhecidas', () {
    final text = CatalogParser.decode(file.readAsBytesSync()).text;
    final preview = CatalogParser.parse(text);

    expect(preview.hadHeader, isTrue);
    expect(preview.delimiter, ';');
    expect(preview.invalid, isEmpty);
    expect(preview.duplicatesInFile.map((e) => '${e.line}: ${e.name}'), isEmpty);
    expect(preview.unknownUnits.map((e) => '${e.line}: ${e.name}'), isEmpty);
    expect(preview.toImport.length, greaterThan(100));
  });

  test('toda linha tem unidade, e é uma das oferecidas pelo app', () {
    final preview = CatalogParser.parse(CatalogParser.decode(file.readAsBytesSync()).text);
    final symbols = MeasureUnit.values.map((u) => u.symbol).toSet();

    for (final e in preview.toImport) {
      expect(e.unit, isNotNull, reason: 'linha ${e.line}: ${e.name} sem unidade');
      expect(symbols, contains(e.unit), reason: 'linha ${e.line}: ${e.name}');
    }
  });

  group('cópia com os acentos corrompidos (UTF-8 lido como ANSI e regravado)', () {
    final originalText = CatalogParser.decode(file.readAsBytesSync()).text;
    final original = CatalogParser.parse(originalText);
    final accentedLines = originalText.split('\n').where((l) => l.runes.any((r) => r > 127)).length;

    List<(String, String?)> pairs(CatalogPreview p) => [for (final e in p.toImport) (e.name, e.unit)];

    Uint8List corrupted({bool bom = false, bool crlf = false}) {
      var text = mojibake(CatalogParser.decode(file.readAsBytesSync()).text);
      if (crlf) text = text.replaceAll('\n', '\r\n');
      return Uint8List.fromList([if (bom) ...[0xEF, 0xBB, 0xBF], ...utf8.encode(text)]);
    }

    for (final (label, bom, crlf) in [
      ('UTF-8 sem BOM', false, false),
      ('com BOM', true, false),
      ('com finais de linha do Windows (CRLF)', false, true),
      ('com BOM e CRLF', true, true),
    ]) {
      test('$label: importa idêntico ao arquivo original', () {
        final decoded = CatalogParser.decode(corrupted(bom: bom, crlf: crlf));
        final preview = CatalogParser.parse(decoded.text);

        expect(decoded.legacyEncoding, isFalse);
        expect(preview.repairedLines, accentedLines); // exatamente as linhas que têm acento
        expect(pairs(preview), pairs(original));
        expect(preview.invalid, isEmpty);
        expect(preview.unknownUnits, isEmpty);
      });
    }

    test('nenhum nome fica com letras de acento quebradas', () {
      final preview = CatalogParser.parse(CatalogParser.decode(corrupted()).text);
      for (final e in preview.toImport) {
        expect(e.name, isNot(contains('Ã')), reason: e.name);
        expect(e.name, isNot(contains('Â')), reason: e.name);
      }
    });
  });

  test('importar duas vezes: na segunda tudo já existe', () {
    final text = CatalogParser.decode(file.readAsBytesSync()).text;
    final first = CatalogParser.parse(text);
    final second = CatalogParser.parse(text, existingNames: first.toImport.map((e) => e.name));

    expect(second.toImport, isEmpty);
    expect(second.alreadyExist.length, first.toImport.length);
  });
}
