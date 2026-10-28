import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/item.dart';
import 'package:lista_compras/widgets/items_view.dart';

Item item(String name, {bool checked = false}) =>
    Item(id: name, listId: 'l1', name: name, checked: checked);

class Moved {
  Moved(this.item, this.afterId, this.beforeId);
  final String item;
  final String? afterId;
  final String? beforeId;

  @override
  String toString() => '$item entre $afterId e $beforeId';
}

class Harness {
  Harness(this.tester);

  final WidgetTester tester;
  final moves = <Moved>[];
  final toggled = <(String, bool)>[];
  final edited = <String>[];
  final deleted = <String>[];

  /// Se definido, a gravação do movimento só termina quando este completar.
  Completer<void>? moveGate;
  bool failMove = false;

  Widget build(List<Item> items) => MaterialApp(
        home: Scaffold(
          body: ItemsView(
            items: items,
            onToggle: (i, v) => toggled.add((i.id, v)),
            onEdit: (i) => edited.add(i.id),
            onDelete: (i) => deleted.add(i.id),
            onMove: (i, {afterId, beforeId}) async {
              moves.add(Moved(i.id, afterId, beforeId));
              await moveGate?.future;
              if (failMove) throw StateError('falhou');
            },
          ),
        ),
      );

  Future<void> show(List<Item> items) async {
    await tester.pumpWidget(build(items));
    await tester.pumpAndSettle();
  }

  /// Nomes na ordem em que aparecem na tela (de cima para baixo).
  List<String> visibleOrder() {
    final texts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>();
    final positions = <String, double>{};
    for (final name in texts) {
      final finder = find.text(name);
      if (finder.evaluate().length == 1 && name.length <= 3) positions[name] = tester.getTopLeft(finder).dy;
    }
    return (positions.keys.toList()..sort((a, b) => positions[a]!.compareTo(positions[b]!)));
  }

  /// Arrasta o item [name] pelo puxador, [steps] linhas para baixo (negativo = para cima).
  Future<TestGesture> startDrag(String name) async {
    final row = find.ancestor(of: find.text(name), matching: find.byType(Row)).first;
    final handle = find.descendant(of: row, matching: find.byIcon(Icons.drag_indicator));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    return gesture;
  }

  Future<void> dragBy(String name, double dy) async {
    final gesture = await startDrag(name);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, dy / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  double get rowHeight => tester.getSize(find.ancestor(of: find.text('A'), matching: find.byType(ListTile))).height;
}

void main() {
  final abcd = [item('A'), item('B'), item('C'), item('D')];

  testWidgets('pendentes têm puxador; marcados não', (tester) async {
    final h = Harness(tester);
    await h.show([item('A'), item('B'), item('X', checked: true)]);

    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    final checkedRow = find.ancestor(of: find.text('X'), matching: find.byType(Row)).first;
    expect(find.descendant(of: checkedRow, matching: find.byIcon(Icons.drag_indicator)), findsNothing);
  });

  testWidgets('arrastar para baixo: onMove recebe os vizinhos certos e a tela já mostra a nova ordem', (tester) async {
    final h = Harness(tester);
    await h.show(abcd);

    await h.dragBy('A', h.rowHeight * 2.3); // A desce duas posições

    expect(h.moves.single.toString(), 'A entre C e D');
    expect(h.visibleOrder(), ['B', 'C', 'A', 'D']);
  });

  testWidgets('arrastar para o topo: sem vizinho acima', (tester) async {
    final h = Harness(tester);
    await h.show(abcd);

    await h.dragBy('D', -h.rowHeight * 3.5);

    expect(h.moves.single.toString(), 'D entre null e A');
    expect(h.visibleOrder(), ['D', 'A', 'B', 'C']);
  });

  testWidgets('arrastar para o fim: sem vizinho abaixo', (tester) async {
    final h = Harness(tester);
    await h.show(abcd);

    await h.dragBy('B', h.rowHeight * 2.6);

    expect(h.moves.single.toString(), 'B entre D e null');
  });

  testWidgets('soltar no mesmo lugar não grava nada', (tester) async {
    final h = Harness(tester);
    await h.show(abcd);

    await h.dragBy('B', 5);

    expect(h.moves, isEmpty);
    expect(h.visibleOrder(), ['A', 'B', 'C', 'D']);
  });

  testWidgets('os vizinhos são só os pendentes (marcados ficam fora da conta)', (tester) async {
    final h = Harness(tester);
    await h.show([item('A'), item('X', checked: true), item('B'), item('C')]);

    await h.dragBy('C', -h.rowHeight * 1.4); // C sobe uma posição entre os pendentes

    expect(h.moves.single.toString(), 'C entre A e B');
  });

  testWidgets('atualização que chega durante o arrasto não mexe na tela até soltar', (tester) async {
    final h = Harness(tester);
    await h.show(abcd);

    final gesture = await h.startDrag('A');
    // Passa da tolerância de toque (18 px) para o arrasto começar de fato.
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(Offset(0, h.rowHeight * 0.2));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Outro aparelho acrescenta "E" enquanto o usuário arrasta.
    await tester.pumpWidget(h.build([...abcd, item('E')]));
    await tester.pump();
    expect(find.text('E'), findsNothing);

    await gesture.up();
    await tester.pumpAndSettle();
    // Depois de solto e gravado, a próxima atualização traz tudo.
    await tester.pumpWidget(h.build([...abcd, item('E')]));
    await tester.pumpAndSettle();
    expect(find.text('E'), findsOneWidget);
  });

  testWidgets('enquanto o movimento grava, uma atualização antiga não desfaz a nova ordem', (tester) async {
    final h = Harness(tester)..moveGate = Completer<void>();
    await h.show(abcd);

    await h.dragBy('D', -h.rowHeight * 3.5);
    expect(h.visibleOrder(), ['D', 'A', 'B', 'C']);

    // Chega uma atualização da ordem antiga (antes de a gravação terminar).
    await tester.pumpWidget(h.build(abcd));
    await tester.pumpAndSettle();
    expect(h.visibleOrder(), ['D', 'A', 'B', 'C']); // não "pula" de volta

    h.moveGate!.complete();
    await tester.pumpAndSettle();
    // A atualização com a ordem gravada assume.
    await tester.pumpWidget(h.build([item('D'), item('A'), item('B'), item('C')]));
    await tester.pumpAndSettle();
    expect(h.visibleOrder(), ['D', 'A', 'B', 'C']);
  });

  testWidgets('se a gravação falhar, volta à ordem do banco e avisa', (tester) async {
    final h = Harness(tester)..failMove = true;
    await h.show(abcd);

    await h.dragBy('D', -h.rowHeight * 3.5);

    expect(h.visibleOrder(), ['A', 'B', 'C', 'D']);
    expect(find.text('Não foi possível mover o item.'), findsOneWidget);
  });

  group('seção de marcados', () {
    testWidgets('mostra a contagem (singular e plural) e começa aberta', (tester) async {
      final h = Harness(tester);
      await h.show([item('A'), item('X', checked: true)]);
      expect(find.text('1 item marcado'), findsOneWidget);
      expect(find.text('X'), findsOneWidget);

      await h.show([item('A'), item('X', checked: true), item('Y', checked: true)]);
      expect(find.text('2 itens marcados'), findsOneWidget);
    });

    testWidgets('tocar no cabeçalho recolhe e abre', (tester) async {
      final h = Harness(tester);
      await h.show([item('A'), item('X', checked: true)]);

      await tester.tap(find.text('1 item marcado'));
      await tester.pumpAndSettle();
      expect(find.text('X'), findsNothing);
      expect(find.text('A'), findsOneWidget);

      await tester.tap(find.text('1 item marcado'));
      await tester.pumpAndSettle();
      expect(find.text('X'), findsOneWidget);
    });

    testWidgets('sem marcados, não há cabeçalho', (tester) async {
      final h = Harness(tester);
      await h.show(abcd);
      expect(find.textContaining('marcado'), findsNothing);
    });
  });

  group('ações de sempre', () {
    testWidgets('marcar, editar e apagar continuam funcionando', (tester) async {
      final h = Harness(tester);
      await h.show(abcd);

      await tester.tap(find.byType(Checkbox).first);
      await tester.tap(find.text('B'));
      await tester.drag(find.text('C'), const Offset(-500, 0)); // deslizar para apagar
      await tester.pumpAndSettle();

      expect(h.toggled, [('A', true)]);
      expect(h.edited, ['B']);
      expect(h.deleted, ['C']);
      expect(h.moves, isEmpty); // deslizar não é arrastar
    });

    testWidgets('lista vazia mostra a mensagem', (tester) async {
      final h = Harness(tester);
      await h.show(const []);
      expect(find.textContaining('Lista vazia'), findsOneWidget);
    });

    testWidgets('só marcados: sem pendentes, mostra a seção', (tester) async {
      final h = Harness(tester);
      await h.show([item('X', checked: true)]);
      expect(find.text('1 item marcado'), findsOneWidget);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
    });
  });
}
