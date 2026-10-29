import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/widgets/last_update_text.dart';

void main() {
  final at = DateTime(2026, 10, 29, 18, 27);

  Future<void> pump(
    WidgetTester tester, {
    String? userId = 'u2',
    Future<String?> Function(String)? nameOf,
    String? Function(String)? cached,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: LastUpdateText(
        at: at,
        userId: userId,
        currentUserId: 'u1',
        nameOf: nameOf ?? (id) async => 'Daiane',
        cachedName: cached ?? (_) => null,
      ),
    ));
  }

  testWidgets('mostra a data e depois o nome buscado', (tester) async {
    await pump(tester);
    expect(find.text('Última atualização 29/10/2026 18:27'), findsOneWidget);
    await tester.pump();
    expect(find.text('Última atualização 29/10/2026 18:27 por Daiane'), findsOneWidget);
  });

  testWidgets('nome em cache aparece de imediato', (tester) async {
    await pump(tester, cached: (_) => 'Daiane');
    expect(find.text('Última atualização 29/10/2026 18:27 por Daiane'), findsOneWidget);
  });

  testWidgets('o próprio usuário aparece como "você", sem buscar nada', (tester) async {
    await pump(tester, userId: 'u1', nameOf: (_) => throw StateError('não devia buscar'));
    expect(find.text('Última atualização 29/10/2026 18:27 por você'), findsOneWidget);
  });

  testWidgets('sem rede (nome nulo) fica só a data', (tester) async {
    await pump(tester, nameOf: (_) async => null);
    await tester.pump();
    expect(find.text('Última atualização 29/10/2026 18:27'), findsOneWidget);
  });
}
