import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';
import 'package:lista_compras/models/shopping_list.dart';
import 'package:lista_compras/services/items_service.dart';
import 'package:lista_compras/services/lists_service.dart';
import 'package:lista_compras/services/products_service.dart';
import 'package:lista_compras/services/sync_service.dart';
import '../support/fake_gateway.dart';

void main() {
  late AppDatabase db;
  late FakeGateway remote;
  late SyncService sync;
  late ListsService lists;
  late ItemsService items;
  late ProductsService products;

  var clock = DateTime.utc(2026, 10, 12, 10);
  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    remote = FakeGateway();
    sync = SyncService(db, remote: remote);
    lists = ListsService(db, currentUserId: () => 'u1', now: tick);
    items = ItemsService(db, currentUserId: () => 'u1', now: tick);
    products = ProductsService(db, currentUserId: () => 'u1', now: tick);
  });
  tearDown(() => db.close());

  Future<String> newList() async {
    await lists.createList(name: 'Mercado', category: ListCategory.mercado);
    return (await lists.watchLists().first).single.id;
  }

  test('envia a fila na ordem de criação (lista antes dos itens) e esvazia', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Arroz');
    await items.addItem(listId, name: 'Feijão');

    await sync.push();

    expect(remote.calls.length, 3);
    expect(remote.calls.first, startsWith('upsert lists'));
    expect(remote.calls.skip(1), everyElement(startsWith('upsert items')));
    expect(await db.pendingEntries(), isEmpty);
    expect(await db.failedEntries(), isEmpty);
  });

  test('envia criação com todos os campos e atualização só com os alterados', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Leite');
    await sync.push();
    final itemId = (await items.watchItems(listId).first).single.id;

    await items.setChecked(itemId, true);
    await sync.push();

    final created = remote.payloads[1];
    expect(created, containsPair('name', 'Leite'));
    expect(created, containsPair('list_id', listId));
    expect(created['created_at'], isNotNull);
    expect(remote.calls.last, 'update items $itemId');
    expect(remote.payloads.last, {'checked': true});
  });

  test('sem rede: mantém tudo na fila, não conta tentativa e para na primeira', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Arroz');
    remote.onSend = (_, _, _) => throw const SocketException('sem rede');

    await sync.push();

    expect(remote.calls, hasLength(1)); // parou na primeira
    final pending = await db.pendingEntries();
    expect(pending, hasLength(2));
    expect(pending.map((e) => e.attempts), everyElement(0));
    expect(await db.failedEntries(), isEmpty);
  });

  test('ao reconectar, o que ficou pendente sobe e nada duplica', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Arroz');
    remote.onSend = (_, _, _) => throw const SocketException('sem rede');
    await sync.push();

    remote.onSend = null;
    remote.calls.clear();
    await sync.push();

    expect(remote.calls, hasLength(2));
    expect(await db.pendingEntries(), isEmpty);
    await sync.push(); // nada novo para enviar
    expect(remote.calls, hasLength(2));
  });

  test('rejeição permanente (RLS) vira falha e não trava as demais', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Arroz');
    await items.addItem(listId, name: 'Feijão');
    remote.onSend = (op, table, row) {
      if (row['name'] == 'Arroz') throw serverError('42501');
    };

    await sync.push();

    final failed = await db.failedEntries();
    expect(failed, hasLength(1));
    expect(failed.single.lastError, contains('42501'));
    expect(remote.calls, hasLength(3)); // lista, Arroz (rejeitado), Feijão
    expect(await db.pendingEntries(), isEmpty); // Feijão subiu
  });

  test('erro passageiro do servidor conta tentativa, para a rodada e vira falha no limite', () async {
    await newList();
    remote.onSend = (_, _, _) => throw serverError('XX000');

    for (var i = 1; i < SyncService.maxServerErrors; i++) {
      await sync.push();
      final e = (await db.pendingEntries()).single;
      expect(e.attempts, i);
      expect(e.failed, isFalse);
    }

    await sync.push(); // a última tentativa permitida
    expect(await db.pendingEntries(), isEmpty);
    expect((await db.failedEntries()).single.attempts, SyncService.maxServerErrors);
  });

  test('atualização que não atinge linha nenhuma vira falha permanente', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Arroz');
    await sync.push();
    final itemId = (await items.watchItems(listId).first).single.id;

    remote.updateFindsRow = false;
    await items.setChecked(itemId, true);
    await sync.push();

    final failed = (await db.failedEntries()).single;
    expect(failed.rowId, itemId);
    expect(failed.lastError, contains('não existe'));
  });

  test('produto duplicado no servidor: descarta a cópia local', () async {
    await products.remember('Arroz');
    remote.onSend = (_, table, _) {
      if (table == 'products') throw serverError('23505');
    };

    await sync.push();

    expect(await db.select(db.localProducts).get(), isEmpty);
    expect(await db.pendingEntries(), isEmpty);
    expect(await db.failedEntries(), isEmpty);
  });

  test('chamadas simultâneas a push não enviam duas vezes', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Arroz');
    final gate = Completer<void>();
    remote.onSend = (_, _, _) => gate.future;

    final a = sync.push();
    final b = sync.push();
    gate.complete();
    await Future.wait([a, b]);

    expect(remote.calls, hasLength(2)); // lista + item, uma vez cada
  });

  test('edição feita durante o envio não se perde', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Arroz');
    final itemId = (await items.watchItems(listId).first).single.id;

    remote.onSend = (op, table, row) async {
      if (table == 'items' && op == 'upsert') {
        // O usuário marca o item enquanto a criação dele está sendo enviada.
        await items.setChecked(itemId, true);
      }
    };
    await sync.push();

    // A criação subiu e a marcação ficou na fila como `update` (o servidor já
    // tem a linha). No app, o aviso de "entrou algo na fila" agenda a próxima rodada.
    final left = (await db.pendingEntries()).single;
    expect(left.op, 'update');
    expect(left.rowId, itemId);

    remote.onSend = null;
    await sync.push();

    expect(remote.calls.last, 'update items $itemId');
    expect(remote.payloads.last, {'checked': true});
    expect(await db.pendingEntries(), isEmpty);
  });

  test('o que subiu volta do servidor sem sobrescrever o que ainda está pendente', () async {
    final listId = await newList();
    await items.addItem(listId, name: 'Arroz');
    await sync.push();
    final itemId = (await items.watchItems(listId).first).single.id;

    await items.setChecked(itemId, true); // pendente
    await sync.applyRemoteRows('items', [
      {
        'id': itemId,
        'list_id': listId,
        'name': 'Arroz',
        'quantity': null,
        'unit': null,
        'note': null,
        'checked': false, // servidor ainda com o valor antigo
        'created_by': 'u1',
        'created_at': '2026-10-12T10:00:00+00:00',
        'updated_at': '2026-10-12T10:00:00+00:00',
        'deleted_at': null,
      },
    ]);

    expect((await items.watchItems(listId).first).single.checked, isTrue);
  });
}
