import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';
import 'package:lista_compras/models/shopping_list.dart';
import 'package:lista_compras/services/items_service.dart';
import 'package:lista_compras/services/lists_service.dart';
import 'package:lista_compras/services/products_service.dart';
import 'package:lista_compras/services/sync_service.dart';

void main() {
  late AppDatabase db;
  late ListsService lists;
  late ItemsService items;
  late ProductsService products;
  late SyncService sync;

  // Relógio que anda 1 ms a cada leitura: dá uma ordem de criação previsível.
  var clock = DateTime.utc(2026, 10, 12, 10);
  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    lists = ListsService(db, currentUserId: () => 'u1', now: tick);
    items = ItemsService(db, currentUserId: () => 'u1', now: tick);
    products = ProductsService(db, currentUserId: () => 'u1', now: tick);
    sync = SyncService(db);
  });
  tearDown(() => db.close());

  Map<String, dynamic> payloadOf(OutboxEntry e) =>
      jsonDecode(e.payload) as Map<String, dynamic>;

  Future<String> firstListId() async =>
      (await lists.watchLists().first).single.id;

  Future<String> createListAndGetId() async {
    await lists.createList(name: 'Mercado', category: ListCategory.mercado);
    return firstListId();
  }

  group('listas', () {
    test('criar grava no banco local e na fila como criação', () async {
      await lists.createList(name: '  Feira  ', category: ListCategory.feira);

      final list = (await lists.watchLists().first).single;
      expect(list.name, 'Feira');
      expect(list.ownerId, 'u1');
      expect(list.category, ListCategory.feira);

      final e = (await db.pendingEntries()).single;
      expect(e.targetTable, 'lists');
      expect(e.op, 'insert');
      expect(e.rowId, list.id);
      expect(payloadOf(e), containsPair('owner_id', 'u1'));
      expect(payloadOf(e), containsPair('name', 'Feira'));
      expect(payloadOf(e)['created_at'], isNotNull);
    });

    test('sem usuário logado, criar falha e não grava nada', () async {
      final anon = ListsService(db, currentUserId: () => null);
      expect(
        () => anon.createList(name: 'X', category: ListCategory.outro),
        throwsStateError,
      );
      expect(await db.select(db.localLists).get(), isEmpty);
    });

    test('renomear uma lista ainda não enviada mantém uma única criação', () async {
      final id = await createListAndGetId();
      await lists.updateList(id, name: 'Semana', category: ListCategory.padaria);

      expect((await lists.watchLists().first).single.name, 'Semana');
      final e = (await db.pendingEntries()).single;
      expect(e.op, 'insert');
      expect(payloadOf(e), containsPair('name', 'Semana'));
      expect(payloadOf(e), containsPair('category', 'padaria'));
    });

    test('apagar esconde a lista e enfileira deleted_at', () async {
      final id = await createListAndGetId();
      await lists.deleteList(id);

      expect(await lists.watchLists().first, isEmpty);
      // A linha continua no banco (exclusão suave).
      expect(await db.select(db.localLists).get(), hasLength(1));
      expect(payloadOf((await db.pendingEntries()).single)['deleted_at'], isNotNull);
    });

    test('lista na ordem de criação', () async {
      await lists.createList(name: 'A', category: ListCategory.mercado);
      await lists.createList(name: 'B', category: ListCategory.mercado);
      await lists.createList(name: 'C', category: ListCategory.mercado);

      expect((await lists.watchLists().first).map((l) => l.name), ['A', 'B', 'C']);
    });
  });

  group('uma lista só', () {
    test('watchList acompanha renomeações e emite null quando a lista some', () async {
      final id = await createListAndGetId();

      final expectation = expectLater(
        lists.watchList(id),
        emitsInOrder([
          predicate<ShoppingList?>((l) => l?.name == 'Mercado'),
          predicate<ShoppingList?>((l) => l?.name == 'Semana'),
          isNull,
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await lists.updateList(id, name: 'Semana', category: ListCategory.mercado);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await lists.deleteList(id);
      await expectation;
    });
  });

  group('itens', () {
    test('adicionar grava local e na fila, sem quantidade padrão', () async {
      final listId = await createListAndGetId();
      await items.addItem(listId, name: ' Arroz ', unit: '', note: ' ');

      final item = (await items.watchItems(listId).first).single;
      expect(item.name, 'Arroz');
      expect(item.quantity, isNull);
      expect(item.unit, isNull);
      expect(item.note, isNull);
      expect(item.checked, isFalse);

      final e = (await db.pendingEntries()).last;
      expect(e.targetTable, 'items');
      expect(e.op, 'insert');
      expect(payloadOf(e), containsPair('list_id', listId));
      expect(payloadOf(e), containsPair('checked', false));
      expect(payloadOf(e)['quantity'], isNull);
    });

    test('mantém a ordem em que foram digitados', () async {
      final listId = await createListAndGetId();
      for (final n in ['Pão', 'Leite', 'Ovos', 'Café']) {
        await items.addItem(listId, name: n);
      }
      expect(
        (await items.watchItems(listId).first).map((i) => i.name),
        ['Pão', 'Leite', 'Ovos', 'Café'],
      );
    });

    test('só mostra itens da lista pedida e não os apagados', () async {
      final listId = await createListAndGetId();
      await lists.createList(name: 'Outra', category: ListCategory.outro);
      final otherId = (await lists.watchLists().first).last.id;

      await items.addItem(listId, name: 'A');
      await items.addItem(listId, name: 'B');
      await items.addItem(otherId, name: 'C');
      final b = (await items.watchItems(listId).first).last;
      await items.deleteItem(b.id);

      expect((await items.watchItems(listId).first).map((i) => i.name), ['A']);
      expect((await items.watchItems(otherId).first).map((i) => i.name), ['C']);
    });

    test('marcar e editar um item já enviado viram uma única atualização por campos', () async {
      final listId = await createListAndGetId();
      await items.addItem(listId, name: 'Arroz');
      for (final e in await db.pendingEntries()) {
        await db.markSent(e); // simula: já subiu ao servidor
      }
      final id = (await items.watchItems(listId).first).single.id;

      await items.setChecked(id, true);
      await items.updateItem(id, name: 'Arroz integral', quantity: 2, unit: 'kg');

      final e = (await db.pendingEntries()).single;
      expect(e.op, 'update');
      expect(payloadOf(e), {
        'checked': true,
        'name': 'Arroz integral',
        'quantity': 2,
        'unit': 'kg',
        'note': null,
      });
      final item = (await items.watchItems(listId).first).single;
      expect(item.checked, isTrue);
      expect(item.quantityLabel, '2 kg');
    });
  });

  group('catálogo de produtos', () {
    test('lembrar um produto novo grava local e na fila', () async {
      await products.remember('Arroz', unit: 'kg');

      expect(products.find('arroz')?.defaultUnit, 'kg');
      final e = (await db.pendingEntries()).single;
      expect(e.targetTable, 'products');
      expect(e.op, 'insert');
      expect(payloadOf(e), containsPair('default_unit', 'kg'));
      expect(payloadOf(e), containsPair('owner_id', 'u1'));
    });

    test('não duplica ignorando maiúsculas e carrega do banco local', () async {
      await products.remember('Arroz');
      await products.remember('ARROZ');
      expect(await db.select(db.localProducts).get(), hasLength(1));

      final fresh = ProductsService(db, currentUserId: () => 'u1');
      expect(fresh.products, isEmpty);
      await fresh.load();
      expect(fresh.products.map((p) => p.name), ['Arroz']);
    });

    test('produto já existente: unidade nova vira a padrão, vazia não apaga', () async {
      await products.remember('Arroz');
      for (final e in await db.pendingEntries()) {
        await db.markSent(e);
      }

      await products.remember('Arroz', unit: '  ');
      expect(await db.pendingEntries(), isEmpty);

      await products.remember('Arroz', unit: 'kg');
      expect(products.find('Arroz')?.defaultUnit, 'kg');
      final e = (await db.pendingEntries()).single;
      expect(e.op, 'update');
      expect(payloadOf(e), {'default_unit': 'kg'});
    });
  });

  group('recebimento do servidor', () {
    Map<String, dynamic> serverList(String id, String name, {String? deletedAt}) => {
          'id': id,
          'owner_id': 'u2',
          'name': name,
          'category': 'mercado',
          'created_at': '2026-10-12T09:00:00.123456+00:00',
          'updated_at': '2026-10-12T09:00:00.123456+00:00',
          'deleted_at': deletedAt,
        };

    Map<String, dynamic> serverItem(String id, String listId, String name,
            {bool checked = false, num? quantity}) =>
        {
          'id': id,
          'list_id': listId,
          'name': name,
          'quantity': quantity,
          'unit': null,
          'note': null,
          'checked': checked,
          'created_by': 'u2',
          'created_at': '2026-10-12T09:01:00+00:00',
          'updated_at': '2026-10-12T09:01:00+00:00',
          'deleted_at': null,
        };

    test('copia listas e itens que vieram do servidor', () async {
      await sync.applyRemoteRows('lists', [serverList('l1', 'Da esposa')]);
      await sync.applyRemoteRows('items', [serverItem('i1', 'l1', 'Leite', quantity: 2)]);

      final list = (await lists.watchLists().first).single;
      expect(list.name, 'Da esposa');
      expect(list.ownerId, 'u2');
      final item = (await items.watchItems('l1').first).single;
      expect(item.name, 'Leite');
      expect(item.quantity, 2);
      // Receber do servidor não cria pendência.
      expect(await db.pendingEntries(), isEmpty);
    });

    test('atualiza linhas sem pendência (última versão do servidor vence)', () async {
      await sync.applyRemoteRows('lists', [serverList('l1', 'Antigo')]);
      await sync.applyRemoteRows('lists', [serverList('l1', 'Novo')]);

      expect((await lists.watchLists().first).single.name, 'Novo');
    });

    test('não sobrescreve linha com mudança local pendente', () async {
      await sync.applyRemoteRows('lists', [serverList('l1', 'Lista')]);
      await sync.applyRemoteRows('items', [serverItem('i1', 'l1', 'Pão')]);

      await items.setChecked('i1', true); // mudança local ainda não enviada
      await sync.applyRemoteRows('items', [
        serverItem('i1', 'l1', 'Pão', checked: false), // servidor ainda não sabe
        serverItem('i2', 'l1', 'Ovos'), // linha nova: deve entrar
      ]);

      final all = await items.watchItems('l1').first;
      expect(all.firstWhere((i) => i.id == 'i1').checked, isTrue);
      expect(all.map((i) => i.name), containsAll(['Pão', 'Ovos']));
    });

    test('item apagado no servidor some da tela', () async {
      await sync.applyRemoteRows('lists', [serverList('l1', 'Lista')]);
      await sync.applyRemoteRows('items', [serverItem('i1', 'l1', 'Pão')]);
      expect(await items.watchItems('l1').first, hasLength(1));

      await sync.applyRemoteRows('items', [
        {...serverItem('i1', 'l1', 'Pão'), 'deleted_at': '2026-10-12T10:00:00+00:00'},
      ]);

      expect(await items.watchItems('l1').first, isEmpty);
    });

    test('tabela desconhecida é rejeitada', () async {
      expect(
        () => sync.applyRemoteRows('outra', [
          {'id': 'x'},
        ]),
        throwsArgumentError,
      );
    });
  });
}
