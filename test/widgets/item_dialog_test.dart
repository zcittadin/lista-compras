import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/item.dart';
import 'package:lista_compras/widgets/item_dialog.dart';

Item draft({String? unit, num? quantity}) => Item(
      id: '',
      listId: 'l1',
      name: 'Arroz',
      checked: false,
      unit: unit,
      quantity: quantity,
    );

/// O que o diálogo devolveu quando foi fechado.
class OpenedDialog {
  ItemFormResult? result;
  bool closed = false;
}

Future<OpenedDialog> openDialog(WidgetTester tester, Item item, {bool isNew = true}) async {
  final opened = OpenedDialog();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              opened.result = await showDialog<ItemFormResult>(
                context: context,
                builder: (_) => ItemDialog(item: item, isNew: isNew),
              );
              opened.closed = true;
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return opened;
}

final _dropdown = find.byType(DropdownButtonFormField<String?>);

Future<void> pick(WidgetTester tester, String optionText) async {
  await tester.tap(_dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(optionText).last);
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.text('Salvar'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('o campo Unidade é uma lista de opções, não texto livre', (tester) async {
    await openDialog(tester, draft());

    expect(_dropdown, findsOneWidget);
    // Nome, Quantidade e Observação continuam sendo campos de texto.
    expect(find.byType(TextField), findsNWidgets(3));
  });

  testWidgets('oferece "Sem unidade" e as unidades comuns, com o nome por extenso', (tester) async {
    await openDialog(tester, draft());

    await tester.tap(_dropdown);
    await tester.pumpAndSettle();

    for (final text in [
      'Sem unidade',
      'un · unidade',
      'kg · quilo',
      'g · grama',
      'L · litro',
      'mL · mililitro',
      'dz · dúzia',
      'pct · pacote',
      'cx · caixa',
      'm · metro',
    ]) {
      expect(find.text(text), findsWidgets, reason: text);
    }
  });

  testWidgets('escolher uma unidade devolve o símbolo ao salvar', (tester) async {
    final opened = await openDialog(tester, draft());

    await tester.enterText(find.widgetWithText(TextField, 'Quantidade'), '2,5');
    await pick(tester, 'kg · quilo');
    await save(tester);

    expect(opened.result, (name: 'Arroz', quantity: 2.5, unit: 'kg', note: ''));
  });

  testWidgets('sem escolher nada, a unidade fica vazia', (tester) async {
    final opened = await openDialog(tester, draft());

    await save(tester);

    expect(opened.result?.unit, isNull);
  });

  testWidgets('a unidade do catálogo já vem escolhida', (tester) async {
    final opened = await openDialog(tester, draft(unit: 'kg'));

    expect(find.descendant(of: _dropdown, matching: find.text('kg')), findsOneWidget);
    await save(tester);

    expect(opened.result?.unit, 'kg');
  });

  testWidgets('é possível voltar para "Sem unidade"', (tester) async {
    final opened = await openDialog(tester, draft(unit: 'kg'), isNew: false);

    await pick(tester, 'Sem unidade');
    await save(tester);

    expect(opened.result?.unit, isNull);
  });

  testWidgets('trocar de unidade ao editar', (tester) async {
    final opened = await openDialog(tester, draft(unit: 'kg', quantity: 1), isNew: false);

    await pick(tester, 'g · grama');
    await save(tester);

    expect(opened.result?.unit, 'g');
    expect(opened.result?.quantity, 1);
  });

  testWidgets('unidade antiga com outra grafia ("Kg") vem padronizada', (tester) async {
    final opened = await openDialog(tester, draft(unit: 'Kg'), isNew: false);

    expect(find.descendant(of: _dropdown, matching: find.text('kg')), findsOneWidget);
    await save(tester);

    expect(opened.result?.unit, 'kg');
  });

  testWidgets('unidade antiga fora da lista ("lata") é mantida ao salvar sem mexer', (tester) async {
    final opened = await openDialog(tester, draft(unit: 'lata'), isNew: false);

    expect(find.descendant(of: _dropdown, matching: find.text('lata')), findsOneWidget);
    await save(tester);

    expect(opened.result?.unit, 'lata');
  });

  testWidgets('quem tinha "lata" pode trocar para uma unidade da lista', (tester) async {
    final opened = await openDialog(tester, draft(unit: 'lata'), isNew: false);

    await pick(tester, 'un · unidade');
    await save(tester);

    expect(opened.result?.unit, 'un');
  });

  testWidgets('cancelar não devolve nada', (tester) async {
    final opened = await openDialog(tester, draft(unit: 'kg'));

    await pick(tester, 'g · grama');
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(opened.closed, isTrue);
    expect(opened.result, isNull);
  });

  testWidgets('sem nome, não salva', (tester) async {
    final opened = await openDialog(tester, draft());

    await tester.enterText(find.widgetWithText(TextField, 'Nome'), '  ');
    await save(tester);

    expect(opened.closed, isFalse);
  });
}
