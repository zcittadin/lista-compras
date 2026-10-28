import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/item.dart';
import '../utils/ordering.dart';
import 'auth_service.dart';

/// Itens de uma lista, local-first (mesma ideia do `ListsService`):
/// grava no SQLite e na fila de pendências; o `SyncService` cuida do servidor.
class ItemsService {
  ItemsService(
    this._db, {
    required this._currentUserId,
    this._now = DateTime.now,
  });

  static final instance = ItemsService(
    AppDatabase.instance,
    currentUserId: () => AuthService.instance.currentUser?.id,
  );

  static const _uuid = Uuid();

  final AppDatabase _db;
  final String? Function() _currentUserId;
  final DateTime Function() _now;

  /// Itens na ordem manual (posição). Desempate fixo, igual em todos os
  /// aparelhos: data de criação e id. Itens ainda sem posição (vindos de um
  /// servidor sem a migração 0003) ficam no fim.
  Stream<List<Item>> watchItems(String listId) {
    final query = _db.select(_db.localItems)
      ..where((i) => i.listId.equals(listId) & i.deletedAt.isNull())
      ..orderBy(_order);
    return query.watch().map((rows) => rows.map(Item.fromLocal).toList());
  }

  static List<OrderClauseGenerator<$LocalItemsTable>> get _order => [
        (i) => OrderingTerm.asc(i.position.isNull()),
        (i) => OrderingTerm.asc(i.position),
        (i) => OrderingTerm.asc(i.createdAt),
        (i) => OrderingTerm.asc(i.id),
      ];

  /// Posição para um item novo: depois do último da lista.
  Future<double> _endPosition(String listId) async {
    final max = _db.localItems.position.max();
    final row = await (_db.selectOnly(_db.localItems)
          ..addColumns([max])
          ..where(_db.localItems.listId.equals(listId)))
        .getSingle();
    return positionBetween(row.read(max), null);
  }

  /// `created_at` é enviado pelo celular para preservar a ordem em que o
  /// item foi digitado, mesmo que ele só suba ao servidor mais tarde.
  Future<void> addItem(
    String listId, {
    required String name,
    num? quantity,
    String? unit,
    String? note,
  }) {
    final id = _uuid.v4();
    final now = _now().toUtc();
    final cleanName = name.trim();
    final cleanUnit = _emptyToNull(unit);
    final cleanNote = _emptyToNull(note);

    return _db.transaction(() async {
      // Item novo vai para o fim da lista.
      final position = await _endPosition(listId);
      await _db.into(_db.localItems).insert(
            LocalItemsCompanion.insert(
              id: id,
              listId: listId,
              name: cleanName,
              quantity: Value(quantity?.toDouble()),
              unit: Value(cleanUnit),
              note: Value(cleanNote),
              createdBy: Value(_currentUserId()),
              createdAt: now,
              updatedAt: now,
              position: Value(position),
            ),
          );
      await _db.enqueue(
        table: 'items',
        rowId: id,
        isInsert: true,
        fields: {
          'id': id,
          'list_id': listId,
          'name': cleanName,
          'quantity': quantity,
          'unit': cleanUnit,
          'note': cleanNote,
          'checked': false,
          'created_at': now.toIso8601String(),
          'position': position,
        },
      );
    });
  }

  /// Move [itemId] para entre [afterId] (o item que deve ficar logo acima) e
  /// [beforeId] (o que deve ficar logo abaixo). `null` = início ou fim.
  ///
  /// Em geral só a posição deste item muda (a média entre os vizinhos), o que
  /// vira uma única alteração na fila. Se não houver mais espaço entre os
  /// vizinhos (muitos movimentos para o mesmo lugar) ou se algum item da lista
  /// ainda não tiver posição, a lista inteira é renumerada (rebalanceada).
  Future<void> moveItem(String listId, String itemId, {String? afterId, String? beforeId}) {
    return _db.transaction(() async {
      Future<double?> positionOf(String? id) async {
        if (id == null) return null;
        final row = await (_db.select(_db.localItems)..where((i) => i.id.equals(id))).getSingleOrNull();
        return row?.position;
      }

      final hasUnpositioned = await (_db.select(_db.localItems)
                ..where((i) => i.listId.equals(listId) & i.position.isNull())
                ..limit(1))
              .getSingleOrNull() !=
          null;
      final above = await positionOf(afterId);
      final below = await positionOf(beforeId);

      if (hasUnpositioned || needsRebalance(above, below)) {
        await _rebalance(listId, itemId, afterId: afterId);
        return;
      }
      await _setPosition(itemId, positionBetween(above, below));
    });
  }

  /// Renumera a lista (1, 2, 3...) na ordem atual, já com [itemId] logo depois
  /// de [afterId] (ou no início, se `null`). Inclui marcados e apagados, para
  /// que todos continuem no lugar relativo deles.
  Future<void> _rebalance(String listId, String itemId, {String? afterId}) async {
    final rows = await (_db.select(_db.localItems)
          ..where((i) => i.listId.equals(listId))
          ..orderBy(_order))
        .get();
    final ids = [for (final r in rows) if (r.id != itemId) r.id];
    final insertAt = afterId == null ? 0 : ids.indexOf(afterId) + 1;
    ids.insert(insertAt, itemId);

    final current = {for (final r in rows) r.id: r.position};
    for (var i = 0; i < ids.length; i++) {
      final position = (i + 1).toDouble();
      if (current[ids[i]] != position) await _setPosition(ids[i], position);
    }
  }

  Future<void> _setPosition(String itemId, double position) async {
    await (_db.update(_db.localItems)..where((i) => i.id.equals(itemId))).write(
      LocalItemsCompanion(position: Value(position), updatedAt: Value(_now().toUtc())),
    );
    await _db.enqueue(
      table: 'items',
      rowId: itemId,
      isInsert: false,
      fields: {'position': position},
    );
  }

  Future<void> updateItem(
    String id, {
    required String name,
    num? quantity,
    String? unit,
    String? note,
  }) {
    final cleanName = name.trim();
    final cleanUnit = _emptyToNull(unit);
    final cleanNote = _emptyToNull(note);

    return _db.transaction(() async {
      await (_db.update(_db.localItems)..where((i) => i.id.equals(id))).write(
        LocalItemsCompanion(
          name: Value(cleanName),
          quantity: Value(quantity?.toDouble()),
          unit: Value(cleanUnit),
          note: Value(cleanNote),
          updatedAt: Value(_now().toUtc()),
        ),
      );
      await _db.enqueue(
        table: 'items',
        rowId: id,
        isInsert: false,
        fields: {
          'name': cleanName,
          'quantity': quantity,
          'unit': cleanUnit,
          'note': cleanNote,
        },
      );
    });
  }

  Future<void> setChecked(String id, bool checked) {
    return _db.transaction(() async {
      await (_db.update(_db.localItems)..where((i) => i.id.equals(id))).write(
        LocalItemsCompanion(checked: Value(checked), updatedAt: Value(_now().toUtc())),
      );
      await _db.enqueue(
        table: 'items',
        rowId: id,
        isInsert: false,
        fields: {'checked': checked},
      );
    });
  }

  Future<void> deleteItem(String id) {
    final now = _now().toUtc();
    return _db.transaction(() async {
      await (_db.update(_db.localItems)..where((i) => i.id.equals(id))).write(
        LocalItemsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      await _db.enqueue(
        table: 'items',
        rowId: id,
        isInsert: false,
        fields: {'deleted_at': now.toIso8601String()},
      );
    });
  }

  String? _emptyToNull(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}
