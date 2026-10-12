import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';
import 'package:lista_compras/models/shopping_list.dart';
import 'package:lista_compras/services/lists_service.dart';
import 'package:lista_compras/services/sync_service.dart';

Map<String, dynamic> serverList(String id, String owner, {String? deletedAt}) => {
      'id': id,
      'owner_id': owner,
      'name': 'Lista $id',
      'category': 'mercado',
      'created_at': '2026-10-12T08:00:00+00:00',
      'updated_at': '2026-10-12T08:00:00+00:00',
      'deleted_at': deletedAt,
    };

void main() {
  late AppDatabase db;
  late ListsService lists;
  late SyncService sync;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    lists = ListsService(db, currentUserId: () => 'me');
    sync = SyncService(db);
  });
  tearDown(() => db.close());

  Future<List<String>> newlyShared() async =>
      [for (final l in await lists.watchNewlyShared().first) l.id];

  /// Simula a lista chegando do servidor (convite feito por outra pessoa).
  Future<void> receive(List<Map<String, dynamic>> rows) => sync.applyRemoteRows('lists', rows);

  test('no primeiro uso, listas compartilhadas que já existiam não geram aviso', () async {
    await receive([serverList('antiga', 'u2')]);

    expect(await newlyShared(), isEmpty);
  });

  test('lista compartilhada que chega depois gera aviso', () async {
    expect(await newlyShared(), isEmpty); // primeiro uso, sem listas
    await receive([serverList('nova', 'u2')]);

    expect(await newlyShared(), ['nova']);
  });

  test('listas do próprio usuário nunca geram aviso', () async {
    expect(await newlyShared(), isEmpty);
    await lists.createList(name: 'Minha', category: ListCategory.mercado);
    await receive([serverList('minha-no-servidor', 'me')]);

    expect(await newlyShared(), isEmpty);
  });

  test('abrir ou dispensar (markSeen) tira o aviso, e ele não volta', () async {
    expect(await newlyShared(), isEmpty);
    await receive([serverList('a', 'u2'), serverList('b', 'u3')]);
    expect(await newlyShared(), ['a', 'b']);

    await lists.markSeen(['a']);

    expect(await newlyShared(), ['b']);
    await receive([serverList('a', 'u2')]); // a lista é atualizada no servidor
    expect(await newlyShared(), ['b']);
  });

  test('lista apagada pelo dono não gera aviso', () async {
    expect(await newlyShared(), isEmpty);
    await receive([serverList('x', 'u2', deletedAt: '2026-10-12T09:00:00+00:00')]);

    expect(await newlyShared(), isEmpty);
  });

  test('removido e convidado de novo: o aviso volta a aparecer', () async {
    expect(await newlyShared(), isEmpty);
    await receive([serverList('x', 'u2')]);
    await lists.markSeen(['x']);
    expect(await newlyShared(), isEmpty);

    // Perdeu o acesso: a busca apaga a lista do banco local.
    await (db.delete(db.localLists)..where((l) => l.id.equals('x'))).go();
    expect(await newlyShared(), isEmpty); // e "esquece" que já tinha visto
    // Foi convidado de novo.
    await receive([serverList('x', 'u2')]);

    expect(await newlyShared(), ['x']);
  });

  test('o aviso acompanha as mudanças em tempo real', () async {
    expect(await newlyShared(), isEmpty);
    final expectation = expectLater(
      lists.watchNewlyShared().map((l) => [for (final x in l) x.id]),
      emitsThrough(['chegou']),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await receive([serverList('chegou', 'u2')]);
    await expectation;
  });

  test('sem usuário logado, não há aviso', () async {
    final anon = ListsService(db, currentUserId: () => null);
    await receive([serverList('x', 'u2')]);
    expect(await anon.watchNewlyShared().first, isEmpty);
  });

  test('trocar de conta (clearAll) recomeça do zero', () async {
    expect(await newlyShared(), isEmpty);
    await receive([serverList('x', 'u2')]);
    await lists.markSeen(['x']);

    await db.clearAll();
    expect(await newlyShared(), isEmpty); // novo "primeiro uso"
    await receive([serverList('y', 'u2')]);
    expect(await newlyShared(), ['y']);
  });
}
