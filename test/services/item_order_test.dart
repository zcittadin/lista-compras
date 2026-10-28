import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';
import 'package:lista_compras/models/shopping_list.dart';
import 'package:lista_compras/services/items_service.dart';
import 'package:lista_compras/services/lists_service.dart';
import 'package:lista_compras/services/sync_service.dart';

void main() {
  late AppDatabase db;
  late ListsService lists;
  late ItemsService items;
  late String listId;

  var clock = DateTime.utc(2026, 10, 18, 10);
  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    lists = ListsService(db, currentUserId: () => 'u1', now: tick);
    items = ItemsService(db, currentUserId: () => 'u1', now: tick);
    await lists.createList(name: 'Mercado', category: ListCategory.mercado);
    listId = (await lists.watchLists().first).single.id;
  });
  tearDown(() => db.close());

  Future<List<String>> names() async => [for (final i in await items.watchItems(listId).first) i.name];
  Future<String> idOf(String name) async =>
      (await items.watchItems(listId).first).firstWhere((i) => i.name == name).id;
  Future<void> addAll(List<String> names) async {
    for (final n in names) {
      await items.addItem(listId, name: n);
    }
  }

  /// Simula o que a tela faz ao soltar: move [name] para entre os vizinhos
  /// [after] (acima) e [before] (abaixo), pelos nomes.
  Future<void> move(String name, {String? after, String? before}) async => items.moveItem(
        listId,
        await idOf(name),
        afterId: after == null ? null : await idOf(after),
        beforeId: before == null ? null : await idOf(before),
      );

  Future<void> sendAll() async {
    for (final e in await db.pendingEntries()) {
      await db.markSent(e);
    }
  }

  Map<String, dynamic> payloadOf(OutboxEntry e) => jsonDecode(e.payload) as Map<String, dynamic>;

  group('itens novos', () {
    test('entram no fim, com posições crescentes, e a posição vai para o servidor', () async {
      await addAll(['Pão', 'Leite', 'Ovos']);

      final all = await items.watchItems(listId).first;
      expect(all.map((i) => i.name), ['Pão', 'Leite', 'Ovos']);
      expect(all.map((i) => i.position), [1, 2, 3]);
      final inserts = (await db.pendingEntries()).where((e) => e.targetTable == 'items');
      expect(inserts.map((e) => payloadOf(e)['position']), [1, 2, 3]);
    });

    test('depois de mover para o fim, o próximo novo vai depois dele', () async {
      await addAll(['A', 'B', 'C']);
      await move('A', after: 'C');
      await items.addItem(listId, name: 'D');
      expect(await names(), ['B', 'C', 'A', 'D']);
    });
  });

  group('mover', () {
    setUp(() async {
      await addAll(['Pão', 'Leite', 'Ovos', 'Café']);
      await sendAll(); // já estão no servidor
    });

    test('para o meio: só a posição do item movido muda, numa única pendência', () async {
      await move('Café', after: 'Pão', before: 'Leite');

      expect(await names(), ['Pão', 'Café', 'Leite', 'Ovos']);
      final entry = (await db.pendingEntries()).single;
      expect(entry.op, 'update');
      expect(payloadOf(entry), {'position': 1.5});
    });

    test('para o topo e para o fim', () async {
      await move('Ovos', before: 'Pão');
      expect(await names(), ['Ovos', 'Pão', 'Leite', 'Café']);

      await move('Pão', after: 'Café');
      expect(await names(), ['Ovos', 'Leite', 'Café', 'Pão']);
    });

    test('mover várias vezes o mesmo item gera uma só pendência (a última posição vale)', () async {
      await move('Café', before: 'Pão');
      await move('Café', after: 'Leite', before: 'Ovos');

      final entry = (await db.pendingEntries()).single;
      expect(payloadOf(entry).keys, ['position']);
      expect(await names(), ['Pão', 'Leite', 'Café', 'Ovos']);
    });

    test('mover um item que ainda não subiu continua sendo uma criação, já com a posição nova', () async {
      await items.addItem(listId, name: 'Sal');
      await move('Sal', before: 'Pão');

      final entry = (await db.pendingEntries()).single;
      expect(entry.op, 'insert');
      expect(payloadOf(entry)['position'], lessThan(1));
      expect((await names()).first, 'Sal');
    });

    test('marcados mantêm a posição e voltam a ela ao desmarcar', () async {
      await items.setChecked(await idOf('Leite'), true);
      // Na tela, os pendentes são Pão, Ovos, Café: mover Café para entre Pão e Ovos
      // o coloca, na ordem completa, entre Leite (marcado) e Ovos.
      await move('Café', after: 'Pão', before: 'Ovos');
      await items.setChecked(await idOf('Leite'), false);

      expect(await names(), ['Pão', 'Leite', 'Café', 'Ovos']);
    });
  });

  group('rebalancear', () {
    test('muitos movimentos para o mesmo vão renumeram a lista sem mudar a ordem', () async {
      await addAll(['A', 'B', 'Z']);
      await sendAll();

      // Põe itens sempre logo abaixo de "A": o vão entre A e o vizinho de baixo
      // vai encolhendo até não caber mais.
      var below = 'B';
      final expected = ['A'];
      for (var i = 0; i < 30; i++) {
        final name = 'N$i';
        await items.addItem(listId, name: name);
        await move(name, after: 'A', before: below);
        below = name;
      }
      for (var i = 29; i >= 0; i--) {
        expected.add('N$i');
      }
      expected.addAll(['B', 'Z']);

      expect(await names(), expected);
      final positions = [for (final i in await items.watchItems(listId).first) i.position!];
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i] - positions[i - 1], greaterThanOrEqualTo(1e-6));
      }
    });

    test('rebalancear inclui marcados e apagados, sem tirá-los do lugar relativo', () async {
      await addAll(['A', 'B', 'C', 'X', 'D']); // posições 1..5
      await items.setChecked(await idOf('B'), true);
      await items.deleteItem(await idOf('X'));
      await sendAll();
      // C e D empatados (posição 3): entre eles não há espaço.
      await (db.update(db.localItems)..where((i) => i.name.equals('D')))
          .write(const LocalItemsCompanion(position: Value(3)));

      await move('A', after: 'C', before: 'D'); // vizinhos empatados → renumera

      final rows = await (db.select(db.localItems)..orderBy([(i) => OrderingTerm.asc(i.position)])).get();
      // B (marcado) e X (apagado) continuam na lista renumerada, nos lugares relativos.
      expect(rows.map((r) => r.name), ['B', 'C', 'A', 'D', 'X']);
      expect(rows.map((r) => r.position), [1, 2, 3, 4, 5]);
    });

    test('itens sem posição (servidor sem a migração) ganham posição no primeiro movimento', () async {
      // Itens chegando de um servidor antigo, sem a coluna `position`.
      final sync = SyncService(db);
      await sync.applyRemoteRows('items', [
        for (final (id, minute) in [('x1', 1), ('x2', 2), ('x3', 3)])
          {
            'id': id,
            'list_id': listId,
            'name': 'Item $id',
            'quantity': null,
            'unit': null,
            'note': null,
            'checked': false,
            'created_by': 'u2',
            'created_at': '2026-10-18T09:0$minute:00+00:00',
            'updated_at': '2026-10-18T09:00:00+00:00',
            'deleted_at': null,
          },
      ]);
      expect(await names(), ['Item x1', 'Item x2', 'Item x3']); // por data, no fim

      await move('Item x3', before: 'Item x1');

      final all = await items.watchItems(listId).first;
      expect(all.map((i) => i.name), ['Item x3', 'Item x1', 'Item x2']);
      expect(all.every((i) => i.position != null), isTrue);
    });
  });

  group('empates', () {
    test('mesma posição: desempate por data de criação, igual em qualquer aparelho', () async {
      await addAll(['Primeiro', 'Segundo']);
      await (db.update(db.localItems)).write(const LocalItemsCompanion(position: Value(5)));

      expect(await names(), ['Primeiro', 'Segundo']);
    });
  });
}
