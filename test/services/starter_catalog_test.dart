import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/measure_unit.dart';
import 'package:lista_compras/services/catalog_import.dart';

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

  test('importar duas vezes: na segunda tudo já existe', () {
    final text = CatalogParser.decode(file.readAsBytesSync()).text;
    final first = CatalogParser.parse(text);
    final second = CatalogParser.parse(text, existingNames: first.toImport.map((e) => e.name));

    expect(second.toImport, isEmpty);
    expect(second.alreadyExist.length, first.toImport.length);
  });
}
