import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/product.dart';
import 'package:lista_compras/services/products_service.dart';
import 'package:lista_compras/widgets/product_dialog.dart';

class DialogOutcome {
  bool? result;
  bool closed = false;
  final saved = <(String, String?)>[];
}

Future<DialogOutcome> openDialog(
  WidgetTester tester, {
  Product? product,
  Future<void> Function(String name, String? unit)? onSave,
}) async {
  final outcome = DialogOutcome();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              outcome.result = await showDialog<bool>(
                context: context,
                builder: (_) => ProductDialog(
                  product: product,
                  onSave: (name, unit) async {
                    outcome.saved.add((name, unit));
                    await onSave?.call(name, unit);
                  },
                ),
              );
              outcome.closed = true;
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return outcome;
}

final _dropdown = find.byType(DropdownButtonFormField<String?>);

Future<void> typeName(WidgetTester tester, String text) async {
  await tester.enterText(find.widgetWithText(TextField, 'Nome'), text);
  await tester.pump();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.text('Salvar'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('novo produto: salva nome e unidade escolhida e fecha', (tester) async {
    final outcome = await openDialog(tester);
    expect(find.text('Novo produto'), findsOneWidget);

    await typeName(tester, '  Arroz ');
    await tester.tap(_dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('kg · quilo').last);
    await tester.pumpAndSettle();
    await save(tester);

    expect(outcome.saved, [('Arroz', 'kg')]);
    expect(outcome.result, isTrue);
  });

  testWidgets('sem escolher unidade, salva sem unidade', (tester) async {
    final outcome = await openDialog(tester);

    await typeName(tester, 'Sal');
    await save(tester);

    expect(outcome.saved, [('Sal', null)]);
  });

  testWidgets('nome vazio: mostra o erro e não chama onSave', (tester) async {
    final outcome = await openDialog(tester);

    await typeName(tester, '   ');
    await save(tester);

    expect(find.text('Informe o nome.'), findsOneWidget);
    expect(outcome.saved, isEmpty);
    expect(outcome.closed, isFalse);
  });

  testWidgets('nome repetido: continua aberto com o erro (citando o que já existe), que some ao digitar', (tester) async {
    final outcome = await openDialog(
      tester,
      onSave: (name, _) => throw const DuplicateProductException('Arroz 🍚'),
    );

    await typeName(tester, 'Arroz');
    await save(tester);

    expect(find.text('Já existe um produto com este nome: Arroz 🍚'), findsOneWidget);
    expect(outcome.closed, isFalse);

    await typeName(tester, 'Arroz integral');
    expect(find.textContaining('Já existe um produto'), findsNothing);
  });

  testWidgets('outro erro ao salvar também é mostrado, sem fechar', (tester) async {
    final outcome = await openDialog(tester, onSave: (_, _) => throw StateError('falhou'));

    await typeName(tester, 'Arroz');
    await save(tester);

    expect(find.textContaining('Não foi possível salvar'), findsOneWidget);
    expect(outcome.closed, isFalse);
  });

  testWidgets('editar: vem com nome e unidade preenchidos', (tester) async {
    final outcome = await openDialog(
      tester,
      product: const Product(id: 'p1', name: 'Arroz', defaultUnit: 'Kg'),
    );

    expect(find.text('Editar produto'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Arroz'), findsOneWidget);
    // "Kg" antigo aparece padronizado.
    expect(find.descendant(of: _dropdown, matching: find.text('kg')), findsOneWidget);

    await save(tester);
    expect(outcome.saved, [('Arroz', 'kg')]);
  });

  testWidgets('editar: é possível limpar a unidade', (tester) async {
    final outcome = await openDialog(
      tester,
      product: const Product(id: 'p1', name: 'Arroz', defaultUnit: 'kg'),
    );

    await tester.tap(_dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sem unidade').last);
    await tester.pumpAndSettle();
    await save(tester);

    expect(outcome.saved, [('Arroz', null)]);
  });

  testWidgets('cancelar não chama onSave', (tester) async {
    final outcome = await openDialog(tester);

    await typeName(tester, 'Arroz');
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(outcome.saved, isEmpty);
    expect(outcome.closed, isTrue);
    expect(outcome.result, isNull);
  });
}
