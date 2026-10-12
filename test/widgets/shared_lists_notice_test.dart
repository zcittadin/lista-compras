import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/shopping_list.dart';
import 'package:lista_compras/widgets/shared_lists_notice.dart';

const mercado = ShoppingList(id: 'l1', ownerId: 'u2', name: 'Mercado', category: ListCategory.mercado);
const feira = ShoppingList(id: 'l2', ownerId: 'u3', name: 'Feira', category: ListCategory.feira);

void main() {
  final opened = <String>[];
  final dismissed = <String>[];

  setUp(() {
    opened.clear();
    dismissed.clear();
  });

  Future<void> pump(
    WidgetTester tester,
    List<ShoppingList> lists, {
    Future<String?> Function(String)? ownerName,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharedListsNotice(
            lists: lists,
            ownerName: ownerName ?? (id) async => {'u2': 'Zander', 'u3': 'Daiane'}[id],
            onOpen: (l) => opened.add(l.id),
            onDismiss: (l) => dismissed.add(l.id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sem listas novas, não mostra nada', (tester) async {
    await pump(tester, const []);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('um cartão por lista, com o nome de quem compartilhou', (tester) async {
    await pump(tester, const [mercado, feira]);

    expect(find.byType(Card), findsNWidgets(2));
    expect(find.text('Nova lista compartilhada: Mercado'), findsOneWidget);
    expect(find.text('Zander compartilhou com você · toque para abrir'), findsOneWidget);
    expect(find.text('Daiane compartilhou com você · toque para abrir'), findsOneWidget);
  });

  testWidgets('sem o nome (ex.: offline), o aviso aparece mesmo assim', (tester) async {
    await pump(tester, const [mercado], ownerName: (_) async => null);

    expect(find.text('Nova lista compartilhada: Mercado'), findsOneWidget);
    expect(find.text('Toque para abrir'), findsOneWidget);
  });

  testWidgets('tocar no cartão abre a lista', (tester) async {
    await pump(tester, const [mercado, feira]);

    await tester.tap(find.text('Nova lista compartilhada: Feira'));

    expect(opened, ['l2']);
    expect(dismissed, isEmpty);
  });

  testWidgets('o X dispensa só aquele aviso', (tester) async {
    await pump(tester, const [mercado, feira]);

    await tester.tap(find.byTooltip('Dispensar').first);

    expect(dismissed, ['l1']);
    expect(opened, isEmpty);
  });
}
