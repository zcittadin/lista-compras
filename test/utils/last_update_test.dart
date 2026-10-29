import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/utils/last_update.dart';

void main() {
  final at = DateTime(2026, 10, 29, 18, 27); // fuso local

  test('data e hora com zeros à esquerda, e o nome', () {
    expect(formatLastUpdate(at, by: 'Zander'), 'Última atualização 29/10/2026 18:27 por Zander');
    expect(formatLastUpdate(DateTime(2026, 1, 5, 7, 3)), 'Última atualização 05/01/2026 07:03');
  });

  test('converte de UTC para o fuso do aparelho', () {
    final utc = at.toUtc();
    expect(formatLastUpdate(utc), formatLastUpdate(at));
  });
}
