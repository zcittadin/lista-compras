import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/app_database.dart';

/// Sincronização entre o SQLite local e o Supabase.
///
/// Fase B (atual): só RECEBE. Copia para o banco local o que está no servidor
/// (busca inicial + Realtime). Linhas com mudança local ainda não enviada
/// nunca são sobrescritas. O ENVIO da fila de pendências vem na fase C.
class SyncService {
  SyncService(this._db);

  static final instance = SyncService(AppDatabase.instance);

  final AppDatabase _db;

  SupabaseClient get _remote => Supabase.instance.client;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _started = false;
  String? _membershipStamp;

  /// Começa a sincronizar (idempotente). Chamar depois do login.
  void start() {
    if (_started) return;
    _started = true;

    pullAll();

    // Realtime: `.stream()` emite a tabela inteira a cada mudança.
    for (final table in ['lists', 'items']) {
      _subscriptions.add(
        _remote.from(table).stream(primaryKey: ['id']).listen(
              (rows) => _guard(() => applyRemoteRows(table, rows)),
              onError: _logError,
            ),
      );
    }

    // Ser convidado só insere em `list_members` e não muda a linha da lista,
    // então nem `lists` nem `items` avisam. Quando as participações mudam,
    // busca tudo de novo.
    _subscriptions.add(
      _remote
          .from('list_members')
          .stream(primaryKey: ['list_id', 'user_id'])
          .map((rows) {
            final keys = [for (final r in rows) '${r['list_id']}:${r['user_id']}']..sort();
            return keys.join(',');
          })
          .listen((stamp) {
            final changed = _membershipStamp != null && stamp != _membershipStamp;
            _membershipStamp = stamp;
            if (changed) pullAll();
          }, onError: _logError),
    );
  }

  /// Para de sincronizar (ao sair da conta).
  void stop() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _started = false;
    _membershipStamp = null;
  }

  /// Busca tudo o que o usuário pode ver (a RLS filtra no servidor).
  Future<void> pullAll() {
    return _guard(() async {
      for (final table in ['lists', 'items', 'products']) {
        final rows = await _remote.from(table).select();
        await applyRemoteRows(table, rows);
      }
    });
  }

  /// Copia [rows] (como vieram do Supabase) para o banco local, pulando as
  /// linhas que têm mudança local pendente: o que o usuário fez aqui tem
  /// prioridade até subir ao servidor.
  @visibleForTesting
  Future<void> applyRemoteRows(String table, List<Map<String, dynamic>> rows) {
    return _db.transaction(() async {
      final pending = await _db.pendingRowIds(table);
      final incoming = rows.where((r) => !pending.contains(r['id'])).toList();
      if (incoming.isEmpty) return;

      await _db.batch((b) {
        switch (table) {
          case 'lists':
            b.insertAllOnConflictUpdate(_db.localLists, incoming.map(_listRow));
          case 'items':
            b.insertAllOnConflictUpdate(_db.localItems, incoming.map(_itemRow));
          case 'products':
            b.insertAllOnConflictUpdate(_db.localProducts, incoming.map(_productRow));
          default:
            throw ArgumentError('Tabela desconhecida: $table');
        }
      });
    });
  }

  static DateTime _ts(Object? v) => DateTime.parse(v as String).toUtc();
  static DateTime? _tsOrNull(Object? v) => v == null ? null : _ts(v);

  static LocalListsCompanion _listRow(Map<String, dynamic> m) => LocalListsCompanion(
        id: Value(m['id'] as String),
        ownerId: Value(m['owner_id'] as String),
        name: Value(m['name'] as String),
        category: Value(m['category'] as String),
        createdAt: Value(_ts(m['created_at'])),
        updatedAt: Value(_ts(m['updated_at'])),
        deletedAt: Value(_tsOrNull(m['deleted_at'])),
      );

  static LocalItemsCompanion _itemRow(Map<String, dynamic> m) => LocalItemsCompanion(
        id: Value(m['id'] as String),
        listId: Value(m['list_id'] as String),
        name: Value(m['name'] as String),
        quantity: Value((m['quantity'] as num?)?.toDouble()),
        unit: Value(m['unit'] as String?),
        note: Value(m['note'] as String?),
        checked: Value(m['checked'] as bool),
        createdBy: Value(m['created_by'] as String?),
        createdAt: Value(_ts(m['created_at'])),
        updatedAt: Value(_ts(m['updated_at'])),
        deletedAt: Value(_tsOrNull(m['deleted_at'])),
      );

  static LocalProductsCompanion _productRow(Map<String, dynamic> m) => LocalProductsCompanion(
        id: Value(m['id'] as String),
        ownerId: Value(m['owner_id'] as String),
        name: Value(m['name'] as String),
        defaultUnit: Value(m['default_unit'] as String?),
        category: Value(m['category'] as String?),
        createdAt: Value(_ts(m['created_at'])),
        updatedAt: Value(_ts(m['updated_at'])),
        deletedAt: Value(_tsOrNull(m['deleted_at'])),
      );

  /// Sem rede é esperado: erros aqui não podem derrubar o app.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _logError(e);
    }
  }

  void _logError(Object error, [StackTrace? stack]) =>
      debugPrint('SyncService: $error');
}
