import 'package:flutter_test/flutter_test.dart';

import 'package:lista_compras/main.dart';

void main() {
  testWidgets('sem configuração, mostra instruções', (tester) async {
    await tester.pumpWidget(const ListaComprasApp());
    expect(find.textContaining('Configuração ausente'), findsOneWidget);
  });
}
