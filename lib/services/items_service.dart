import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/item.dart';
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

  Stream<List<Item>> watchItems(String listId) {
    final query = _db.select(_db.localItems)
      ..where((i) => i.listId.equals(listId) & i.deletedAt.isNull())
      ..orderBy([(i) => OrderingTerm.asc(i.createdAt)]);
    return query.watch().map((rows) => rows.map(Item.fromLocal).toList());
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
        },
      );
    });
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
