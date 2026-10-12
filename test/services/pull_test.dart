import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';
import 'package:lista_compras/models/shopping_list.dart';
import 'package:lista_compras/services/items_service.dart';
import 'package:lista_compras/services/lists_service.dart';
import 'package:lista_compras/services/sync_service.dart';

import '../support/fake_gateway.dart';

Map<String, dynamic> serverList(String id, String name, String updatedAt) => {
      'id': id,
      'owner_id': 'u2',
      'name': name,
      'category': 'mercado',
      'created_at': '2026-10-01T08:00:00+00:00',
      'updated_at': updatedAt,
      'deleted_at': null,
    };

Map<String, dynamic> serverItem(String id, String listId, String name, String updatedAt) => {
      'id': id,
      'list_id': listId,
      'name': name,
      'quantity': null,
      'unit': null,
      'note': null,
      'checked': false,
      'created_by': 'u2',
      'created_at': '2026-10-01T08:00:00+00:00',
      'updated_at': updatedAt,
      'deleted_at': null,
    };

void main() {
  late AppDatabase db;
  late FakeGateway remote;
  late SyncService sync;
  late ListsService lists;
  late ItemsService items;

  var clock = DateTime.utc(2026, 10, 12, 10);
  DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    remote = FakeGateway();
    sync = SyncService(db, remote: remote);
    lists = ListsService(db, currentUserId: () => 'u1', now: tick);
    items = ItemsService(db, currentUserId: () => 'u1', now: tick);
  });
  tearDown(() => db.close());

  Future<List<String>> listNames() async =>
      (await lists.watchLists().first).map((l) => l.name).toList();

  test('primeira busca traz tudo e grava o marco com o updated_at mais novo', () async {
    remote.server['lists'] = [
      serverList('l1', 'A', '2026-10-12T10:00:00+00:00'),
      serverList('l2', 'B', '2026-10-12T11:30:00+00:00'),
    ];

    await sync.pullAll();

    expect(await listNames(), ['A', 'B']);
    expect(remote.calls, contains('selectAll lists'));
    expect(
      DateTime.parse((await db.getCursor('pull:lists'))!),
      DateTime.utc(2026, 10, 12, 11, 30),
    );
  });

  test('busca seguinte é incremental: só aplica o que mudou e avança o marco', () async {
    remote.server['lists'] = [serverList('l1', 'A', '2026-10-12T10:00:00+00:00')];
    await sync.pullAll();
    remote.calls.clear();

    remote.server['lists'] = [
      serverList('l1', 'A', '2026-10-12T10:00:00+00:00'),
      serverList('l2', 'Nova', '2026-10-12T12:00:00+00:00'),
    ];
    await sync.pullAll();

    expect(remote.calls, contains('selectUpdatedSince lists'));
    expect(remote.calls, isNot(contains('selectAll lists')));
    expect(await listNames(), ['A', 'Nova']);
    expect(
      DateTime.parse((await db.getCursor('pull:lists'))!),
      DateTime.utc(2026, 10, 12, 12),
    );
  });

  test('busca seletiva: um aviso sobre itens só consulta itens', () async {
    remote.server['lists'] = [serverList('l1', 'A', '2026-10-12T10:00:00+00:00')];
    remote.server['items'] = [serverItem('i1', 'l1', 'Pão', '2026-10-12T10:00:00+00:00')];
    await sync.pullAll();
    remote.calls.clear();

    await sync.pull(['items']);

    expect(remote.calls, isNotEmpty);
    expect(remote.calls.every((c) => c.endsWith(' items')), isTrue);
  });

  test('uma lista que o servidor não mostra é apagada mesmo vinda "do nada" para o banco local', () async {
    // Simula uma linha indevida que tenha entrado no banco local (por qualquer
    // caminho): a próxima busca, que confia só no que a RLS devolve, a remove.
    remote.server['lists'] = [serverList('l1', 'Minha', '2026-10-12T10:00:00+00:00')];
    await sync.pullAll();
    await sync.applyRemoteRows('lists', [serverList('x9', 'De outra pessoa', '2026-10-12T10:00:00+00:00')]);
    expect(await listNames(), ['Minha', 'De outra pessoa']);

    await sync.pullAll();

    expect(await listNames(), ['Minha']);
  });

  test('sem novidades, não pede linhas específicas', () async {
    remote.server['lists'] = [serverList('l1', 'A', '2026-10-12T10:00:00+00:00')];
    await sync.pullAll();
    remote.calls.clear();

    await sync.pullAll();

    expect(remote.calls, isNot(contains('selectByIds lists')));
  });

  test('lista antiga que ficou visível agora (convite) é trazida com seus itens', () async {
    remote.server['lists'] = [serverList('l1', 'Minha', '2026-10-12T10:00:00+00:00')];
    await sync.pullAll();

    // Convidado para uma lista criada há muito tempo: updated_at bem anterior
    // ao marco, então a busca incremental sozinha não a enxergaria.
    remote.server['lists'] = [
      serverList('l1', 'Minha', '2026-10-12T10:00:00+00:00'),
      serverList('l9', 'Da esposa', '2026-09-01T08:00:00+00:00'),
    ];
    remote.server['items'] = [serverItem('i9', 'l9', 'Leite', '2026-09-01T08:05:00+00:00')];
    await sync.pullAll();

    expect(await listNames(), containsAll(['Minha', 'Da esposa']));
    expect((await items.watchItems('l9').first).map((i) => i.name), ['Leite']);
  });

  test('perdeu o acesso a uma lista: ela e os itens dela somem do celular', () async {
    remote.server['lists'] = [
      serverList('l1', 'Minha', '2026-10-12T10:00:00+00:00'),
      serverList('l2', 'Compartilhada', '2026-10-12T10:00:00+00:00'),
    ];
    remote.server['items'] = [
      serverItem('i1', 'l1', 'Arroz', '2026-10-12T10:00:00+00:00'),
      serverItem('i2', 'l2', 'Leite', '2026-10-12T10:00:00+00:00'),
    ];
    await sync.pullAll();
    expect(await listNames(), ['Minha', 'Compartilhada']);

    // O dono removeu você: a RLS deixa de devolver a lista e os itens dela.
    remote.server['lists'] = [serverList('l1', 'Minha', '2026-10-12T10:00:00+00:00')];
    remote.server['items'] = [serverItem('i1', 'l1', 'Arroz', '2026-10-12T10:00:00+00:00')];
    await sync.pullAll();

    expect(await listNames(), ['Minha']);
    expect(await items.watchItems('l2').first, isEmpty);
    expect(await db.select(db.localItems).get(), hasLength(1)); // apagado de fato
  });

  test('o que foi criado aqui e ainda não subiu nunca é apagado pela limpeza', () async {
    await lists.createList(name: 'Offline', category: ListCategory.outro);
    final id = (await lists.watchLists().first).single.id;
    await items.addItem(id, name: 'Pão');
    remote.server['lists'] = []; // o servidor não conhece nada ainda

    await sync.pullAll();

    expect(await listNames(), ['Offline']);
    expect(await items.watchItems(id).first, hasLength(1));
  });

  test('entrada que falhou também protege a linha local', () async {
    await lists.createList(name: 'Rejeitada', category: ListCategory.outro);
    final entry = (await db.pendingEntries()).single;
    await db.markFailedAttempt(entry, 'RLS', permanent: true);
    remote.server['lists'] = [];

    await sync.pullAll();

    expect(await listNames(), ['Rejeitada']);
  });

  test('linha com edição pendente não é sobrescrita pelo que veio do servidor', () async {
    remote.server['lists'] = [serverList('l1', 'Original', '2026-10-12T10:00:00+00:00')];
    remote.server['items'] = [serverItem('i1', 'l1', 'Pão', '2026-10-12T10:00:00+00:00')];
    await sync.pullAll();

    await items.setChecked('i1', true);
    remote.server['items'] = [serverItem('i1', 'l1', 'Pão', '2026-10-12T12:00:00+00:00')];
    await sync.pullAll();

    expect((await items.watchItems('l1').first).single.checked, isTrue);
  });

  test('sem rede: o banco local e o marco ficam como estavam', () async {
    remote.server['lists'] = [serverList('l1', 'A', '2026-10-12T10:00:00+00:00')];
    await sync.pullAll();
    final cursor = await db.getCursor('pull:lists');

    remote.onQuery = (_, _) => throw const SocketException('sem rede');
    await sync.pullAll(); // não pode lançar nem apagar nada

    expect(await listNames(), ['A']);
    expect(await db.getCursor('pull:lists'), cursor);
  });

  test('uma busca por vez: chamadas simultâneas viram uma rodada extra, não duas ao mesmo tempo', () async {
    remote.server['lists'] = [serverList('l1', 'A', '2026-10-12T10:00:00+00:00')];

    await Future.wait([sync.pullAll(), sync.pullAll(), sync.pullAll()]);

    // Primeira rodada completa + no máximo uma repetição (selectAll só na 1ª).
    expect(remote.calls.where((c) => c == 'selectAll lists'), hasLength(1));
    expect(remote.calls.where((c) => c == 'selectIds lists').length, lessThanOrEqualTo(2));
  });
}
