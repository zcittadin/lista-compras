import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/shopping_list.dart';
import 'auth_service.dart';

/// Listas, local-first: a tela lê e grava no SQLite do celular; cada
/// mudança também entra na fila de pendências para subir ao Supabase.
///
/// Funciona sem internet. O que chega do servidor (outros membros, outros
/// aparelhos) é copiado para o banco local pelo `SyncService`.
///
/// Exclusão suave: apagar é gravar `deleted_at`; a leitura filtra essas linhas.
class ListsService {
  ListsService(
    this._db, {
    required this._currentUserId,
    this._now = DateTime.now,
  });

  static final instance = ListsService(
    AppDatabase.instance,
    currentUserId: () => AuthService.instance.currentUser?.id,
  );

  static const _uuid = Uuid();

  final AppDatabase _db;
  final String? Function() _currentUserId;
  final DateTime Function() _now;

  Stream<List<ShoppingList>> watchLists() {
    final query = _db.select(_db.localLists)
      ..where((l) => l.deletedAt.isNull())
      ..orderBy([(l) => OrderingTerm.asc(l.createdAt)]);
    return query.watch().map((rows) => rows.map(ShoppingList.fromLocal).toList());
  }

  /// Uma lista só: emite a versão atual a cada mudança, e `null` quando ela
  /// deixa de existir para o usuário (apagada pelo dono ou acesso removido).
  Stream<ShoppingList?> watchList(String id) {
    final query = _db.select(_db.localLists)
      ..where((l) => l.id.equals(id) & l.deletedAt.isNull());
    return query.watchSingleOrNull().map(
          (row) => row == null ? null : ShoppingList.fromLocal(row),
        );
  }

  // -------------------------------------------------------------------
  // Aviso de "lista compartilhada com você"
  // -------------------------------------------------------------------

  /// Chave (em `SyncCursors`) com os IDs das listas compartilhadas que o
  /// usuário já viu. Guardar ali evita uma migração de esquema, e o
  /// `clearAll` da troca de conta já a apaga junto.
  static const _seenKey = 'seen_shared_lists';

  /// Listas de OUTRAS pessoas compartilhadas com o usuário que ele ainda não
  /// viu (nem abriu, nem dispensou o aviso), na ordem em que foram criadas.
  ///
  /// Na primeira vez (instalação que já tinha listas), todas as compartilhadas
  /// existentes contam como vistas: o aviso é só para o que chegar depois.
  Stream<List<ShoppingList>> watchNewlyShared() {
    // Reavalia sempre que as listas ou os marcos mudam.
    return _db
        .customSelect('SELECT 1', readsFrom: {_db.localLists, _db.syncCursors})
        .watch()
        .asyncMap((_) => _newlyShared());
  }

  Future<List<ShoppingList>> _newlyShared() async {
    final me = _currentUserId();
    if (me == null) return const [];

    final shared = await (_db.select(_db.localLists)
          ..where((l) => l.deletedAt.isNull() & l.ownerId.equals(me).not())
          ..orderBy([(l) => OrderingTerm.asc(l.createdAt)]))
        .get();
    final sharedIds = {for (final l in shared) l.id};

    final stored = await _db.getCursor(_seenKey);
    if (stored == null) {
      await _db.setCursor(_seenKey, jsonEncode(sharedIds.toList()));
      return const [];
    }

    final seen = {for (final id in jsonDecode(stored) as List) id as String};
    // Esquece listas que sumiram (acesso removido, lista apagada): se ela for
    // compartilhada de novo no futuro, o aviso volta a aparecer.
    final kept = seen.intersection(sharedIds);
    if (kept.length != seen.length) {
      await _db.setCursor(_seenKey, jsonEncode(kept.toList()));
    }
    return [
      for (final l in shared)
        if (!kept.contains(l.id)) ShoppingList.fromLocal(l),
    ];
  }

  /// Marca como vistas (ao abrir a lista ou dispensar o aviso).
  Future<void> markSeen(Iterable<String> ids) async {
    final stored = await _db.getCursor(_seenKey);
    final seen = stored == null
        ? <String>{}
        : {for (final id in jsonDecode(stored) as List) id as String};
    if (seen.containsAll(ids)) return;
    await _db.setCursor(_seenKey, jsonEncode({...seen, ...ids}.toList()));
  }

  /// O id nasce no celular (UUID), como pede o modo offline.
  Future<void> createList({
    required String name,
    required ListCategory category,
  }) {
    final ownerId = _currentUserId();
    if (ownerId == null) throw StateError('Nenhum usuário logado.');
    final id = _uuid.v4();
    final now = _now().toUtc();
    final cleanName = name.trim();

    return _db.transaction(() async {
      await _db.into(_db.localLists).insert(
            LocalListsCompanion.insert(
              id: id,
              ownerId: ownerId,
              name: cleanName,
              category: Value(category.value),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _db.enqueue(
        table: 'lists',
        rowId: id,
        isInsert: true,
        fields: {
          'id': id,
          'owner_id': ownerId,
          'name': cleanName,
          'category': category.value,
          'created_at': now.toIso8601String(),
        },
      );
    });
  }

  Future<void> updateList(
    String id, {
    required String name,
    required ListCategory category,
  }) {
    final cleanName = name.trim();
    return _db.transaction(() async {
      await (_db.update(_db.localLists)..where((l) => l.id.equals(id))).write(
        LocalListsCompanion(
          name: Value(cleanName),
          category: Value(category.value),
          updatedAt: Value(_now().toUtc()),
        ),
      );
      await _db.enqueue(
        table: 'lists',
        rowId: id,
        isInsert: false,
        fields: {'name': cleanName, 'category': category.value},
      );
    });
  }

  Future<void> deleteList(String id) {
    final now = _now().toUtc();
    return _db.transaction(() async {
      await (_db.update(_db.localLists)..where((l) => l.id.equals(id))).write(
        LocalListsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      await _db.enqueue(
        table: 'lists',
        rowId: id,
        isInsert: false,
        fields: {'deleted_at': now.toIso8601String()},
      );
    });
  }
}
