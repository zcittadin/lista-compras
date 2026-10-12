import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';
import 'package:lista_compras/models/shopping_list.dart';
import 'package:lista_compras/screens/sync_issues_screen.dart';
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

  /// Faz o servidor recusar (RLS) tudo o que for enviado e roda um envio.
  Future<void> pushRejected() async {
    remote.onSend = (_, _, _) => throw serverError('42501');
    await sync.push();
    remote.onSend = null;
  }

  group('estado de conexão', () {
    test('começa como conectado, cai com erro de rede e volta no primeiro sucesso', () async {
      await newList();
      expect(sync.online.value, isTrue);

      remote.onSend = (_, _, _) => throw const SocketException('sem rede');
      await sync.push();
      expect(sync.online.value, isFalse);

      remote.onSend = null;
      await sync.push();
      expect(sync.online.value, isTrue);
    });

    test('busca sem rede marca offline; busca com sucesso marca online', () async {
      remote.onQuery = (_, _) => throw const SocketException('sem rede');
      await sync.pullAll();
      expect(sync.online.value, isFalse);

      remote.onQuery = null;
      await sync.pullAll();
      expect(sync.online.value, isTrue);
    });

    test('o servidor recusar algo prova que há conexão', () async {
      await newList();
      remote.onSend = (_, _, _) => throw const SocketException('sem rede');
      await sync.push();
      expect(sync.online.value, isFalse);

      await pushRejected();
      expect(sync.online.value, isTrue);
    });
  });

  group('tentar de novo', () {
    test('devolve a entrada à fila e envia', () async {
      await newList();
      await pushRejected();
      final failed = (await db.failedEntries()).single;
      expect(failed.lastError, contains('42501'));

      await sync.retryFailed(failed);

      expect(await db.failedEntries(), isEmpty);
      expect(await db.pendingEntries(), isEmpty);
      expect(remote.calls.last, startsWith('upsert lists'));
    });

    test('se o servidor recusar de novo, volta a ser falha', () async {
      await newList();
      await pushRejected();
      final failed = (await db.failedEntries()).single;

      remote.onSend = (_, _, _) => throw serverError('42501');
      await sync.retryFailed(failed);

      expect(await db.failedEntries(), hasLength(1));
    });
  });

  group('descartar', () {
    test('criação recusada: a linha local é apagada', () async {
      final listId = await newList();
      await sync.push(); // a lista sobe
      await items.addItem(listId, name: 'Arroz');
      await pushRejected();
      final failed = (await db.failedEntries()).single;

      await sync.discardFailed(failed);

      expect(await items.watchItems(listId).first, isEmpty);
      expect(await db.select(db.localItems).get(), isEmpty);
      expect(await db.failedEntries(), isEmpty);
      expect(await lists.watchLists().first, hasLength(1)); // a lista fica
    });

    test('lista recusada: apaga também os itens dela e as entradas deles', () async {
      final listId = await newList();
      await items.addItem(listId, name: 'Arroz');
      await items.addItem(listId, name: 'Feijão');
      await pushRejected(); // lista e itens falham
      expect(await db.failedEntries(), hasLength(3));
      final listEntry = (await db.failedEntries()).firstWhere((e) => e.targetTable == 'lists');

      await sync.discardFailed(listEntry);

      expect(await db.select(db.localLists).get(), isEmpty);
      expect(await db.select(db.localItems).get(), isEmpty);
      expect(await db.failedEntries(), isEmpty);
      expect(await db.pendingEntries(), isEmpty);
    });

    test('alteração recusada: volta a versão do servidor', () async {
      remote.server['lists'] = [
        {
          'id': 'l1', 'owner_id': 'u2', 'name': 'Da esposa', 'category': 'mercado',
          'created_at': '2026-10-01T08:00:00+00:00', 'updated_at': '2026-10-01T08:00:00+00:00',
          'deleted_at': null,
        },
      ];
      remote.server['items'] = [
        {
          'id': 'i1', 'list_id': 'l1', 'name': 'Leite', 'quantity': null, 'unit': null,
          'note': null, 'checked': false, 'created_by': 'u2',
          'created_at': '2026-10-01T08:00:00+00:00', 'updated_at': '2026-10-01T08:00:00+00:00',
          'deleted_at': null,
        },
      ];
      await sync.pullAll();
      await items.setChecked('i1', true);
      await pushRejected();
      expect((await items.watchItems('l1').first).single.checked, isTrue); // só local

      await sync.discardFailed((await db.failedEntries()).single);

      expect((await items.watchItems('l1').first).single.checked, isFalse);
      expect(await db.failedEntries(), isEmpty);
    });

    test('alteração de uma linha que o servidor não mostra mais: a linha some', () async {
      final listId = await newList();
      await items.addItem(listId, name: 'Arroz');
      await sync.push();
      final itemId = (await items.watchItems(listId).first).single.id;
      await items.setChecked(itemId, true);
      remote.updateFindsRow = false;
      await sync.push(); // "não existe no servidor" -> falha
      remote.updateFindsRow = true;
      final failed = (await db.failedEntries()).single;

      remote.server['items'] = []; // o servidor não devolve a linha
      await sync.discardFailed(failed);

      expect(await items.watchItems(listId).first, isEmpty);
    });

    test('sem conexão, não descarta (a versão do servidor não pôde ser buscada)', () async {
      final listId = await newList();
      await items.addItem(listId, name: 'Arroz');
      await sync.push();
      final itemId = (await items.watchItems(listId).first).single.id;
      await items.setChecked(itemId, true);
      remote.updateFindsRow = false;
      await sync.push();
      final failed = (await db.failedEntries()).single;

      remote.onQuery = (_, _) => throw const SocketException('sem rede');
      await expectLater(sync.discardFailed(failed), throwsA(isA<SocketException>()));

      expect(await db.failedEntries(), hasLength(1));
      expect((await items.watchItems(listId).first).single.checked, isTrue);
    });
  });

  group('descrição para a tela de problemas', () {
    test('diz a ação e o nome da linha', () async {
      final listId = await newList();
      await items.addItem(listId, name: 'Arroz');
      await products.remember('Café');
      for (final e in await db.pendingEntries()) {
        await db.markSent(e);
      }
      final itemId = (await items.watchItems(listId).first).single.id;
      await items.setChecked(itemId, true);
      await items.deleteItem(itemId);
      await lists.updateList(listId, name: 'Semana', category: ListCategory.mercado);

      final entries = await db.pendingEntries();
      final byTable = {for (final e in entries) e.targetTable: e};

      expect(await sync.describe(byTable['items']!), 'Exclusão do item "Arroz"');
      expect(await sync.describe(byTable['lists']!), 'Alteração da lista "Semana"');
    });

    test('criação, e produto', () async {
      final listId = await newList();
      await items.addItem(listId, name: 'Arroz');
      await products.remember('Café');

      final descriptions = [
        for (final e in await db.pendingEntries()) await sync.describe(e),
      ];
      expect(descriptions, [
        'Criação da lista "Mercado"',
        'Criação do item "Arroz"',
        'Criação do produto "Café"',
      ]);
    });
  });

  group('explicação para o usuário', () {
    test('traduz os códigos mais comuns', () {
      expect(explainFailure('erro (código 42501)'), contains('permissão'));
      expect(explainFailure('A linha não existe no servidor ou você'), contains('permissão'));
      expect(explainFailure('x (código 23503)'), contains('não existe mais'));
      expect(explainFailure('x (código 23505)'), contains('igual'));
      expect(explainFailure('x (código XX000)'), contains('recusou'));
      expect(explainFailure(null), contains('recusou'));
    });
  });
}
