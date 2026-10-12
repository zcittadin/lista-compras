import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/app_database.dart';
import 'remote_gateway.dart';

/// Sincronização entre o SQLite local e o Supabase.
///
/// - ENVIA (`push`): percorre a fila de pendências e manda cada mudança ao
///   servidor, na ordem em que foram feitas.
/// - RECEBE: copia o servidor para o banco local (busca inicial + Realtime),
///   sem sobrescrever linhas com mudança local ainda não enviada.
///
/// O envio é tentado: logo depois de cada alteração, ao abrir o app, ao voltar
/// ao primeiro plano, quando a conexão volta e a cada 30 segundos.
class SyncService with WidgetsBindingObserver {
  SyncService(this._db, {RemoteGateway? remote})
      : _remote = remote ?? SupabaseGateway();

  static final instance = SyncService(AppDatabase.instance);

  /// Depois de tantas respostas de erro "talvez passageiras" do servidor,
  /// a entrada é dada como falha permanente (para não tentar para sempre).
  static const maxServerErrors = 10;

  /// Espera após uma alteração, para juntar várias edições seguidas num envio só.
  static const _pushDelay = Duration(milliseconds: 400);
  static const _retryEvery = Duration(seconds: 30);

  final AppDatabase _db;
  final RemoteGateway _remote;

  SupabaseClient get _supabase => Supabase.instance.client;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _pushTimer;
  Timer? _retryTimer;
  bool _started = false;
  String? _membershipStamp;

  // -------------------------------------------------------------------
  // Ciclo de vida
  // -------------------------------------------------------------------

  /// Começa a sincronizar (idempotente). Chamar depois do login.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);

    syncNow();

    // Cada alteração do usuário agenda um envio.
    _subscriptions.add(_db.onEnqueued.listen((_) => _schedulePush()));

    // Conexão voltou (ex.: saiu do modo avião): envia e busca o que perdeu.
    _subscriptions.add(
      Connectivity().onConnectivityChanged.listen((results) {
        if (results.any((r) => r != ConnectivityResult.none)) syncNow();
      }, onError: _logError),
    );

    // Rede instável não gera evento de conexão: tenta de novo de tempos em tempos.
    _retryTimer = Timer.periodic(_retryEvery, (_) => push());

    // Realtime: `.stream()` emite a tabela inteira a cada mudança.
    for (final table in ['lists', 'items']) {
      _subscriptions.add(
        _supabase.from(table).stream(primaryKey: ['id']).listen(
              (rows) => _guard(() => applyRemoteRows(table, rows)),
              onError: _logError,
            ),
      );
    }

    // Ser convidado só insere em `list_members` e não muda a linha da lista,
    // então nem `lists` nem `items` avisam. Quando as participações mudam,
    // busca tudo de novo.
    _subscriptions.add(
      _supabase
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
    if (_started) WidgetsBinding.instance.removeObserver(this);
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _pushTimer?.cancel();
    _retryTimer?.cancel();
    _started = false;
    _membershipStamp = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) syncNow();
  }

  /// Envia o que está pendente e depois busca as novidades do servidor.
  Future<void> syncNow() async {
    await push();
    await pullAll();
  }

  void _schedulePush() {
    _pushTimer?.cancel();
    _pushTimer = Timer(_pushDelay, push);
  }

  // -------------------------------------------------------------------
  // Envio
  // -------------------------------------------------------------------

  bool _pushing = false;
  bool _pushAgain = false;

  /// Envia a fila de pendências. Só uma execução por vez: se chamada durante
  /// um envio, pede uma nova rodada ao final (para pegar o que entrou nesse meio tempo).
  Future<void> push() async {
    if (_pushing) {
      _pushAgain = true;
      return;
    }
    _pushing = true;
    try {
      do {
        _pushAgain = false;
        await _pushOnce();
      } while (_pushAgain);
    } finally {
      _pushing = false;
    }
  }

  Future<void> _pushOnce() async {
    for (final entry in await _db.pendingEntries()) {
      try {
        await _send(entry);
        await _db.markSent(entry);
      } on PostgrestException catch (e) {
        // O servidor respondeu com erro.
        if (await _handleKnownRejection(entry, e)) continue;
        final permanent =
            _isPermanent(e) || entry.attempts + 1 >= maxServerErrors;
        _logError(
          '${entry.targetTable}/${entry.op} ${entry.rowId} rejeitado: '
          '${e.message} (código ${e.code})${permanent ? ' [definitivo]' : ''}',
        );
        await _db.markFailedAttempt(entry, e.message, permanent: permanent);
        // Rejeição definitiva não trava as demais; um erro passageiro, sim
        // (preserva a ordem: a lista tem de subir antes dos itens dela).
        if (!permanent) return;
      } on _RowNotFound catch (e) {
        _logError('${entry.targetTable}/${entry.op} ${entry.rowId}: $e');
        await _db.markFailedAttempt(entry, e.toString(), permanent: true);
      } catch (e) {
        // Sem comunicação (modo avião, DNS, timeout): não é culpa da entrada,
        // então não conta tentativa. Para por aqui e tenta de novo depois.
        _logError(e);
        return;
      }
    }
  }

  Future<void> _send(OutboxEntry entry) async {
    final fields = jsonDecode(entry.payload) as Map<String, dynamic>;
    if (entry.op == 'insert') {
      await _remote.upsert(entry.targetTable, fields);
      return;
    }
    final changed = await _remote.update(entry.targetTable, entry.rowId, fields);
    if (!changed) {
      throw const _RowNotFound(
        'A linha não existe no servidor ou você não tem mais acesso a ela.',
      );
    }
  }

  /// Erros do servidor que significam "não adianta tentar de novo":
  /// dados inválidos (22), restrições, como chave estrangeira e unicidade (23),
  /// permissão/RLS e SQL (42), exceção levantada pelo banco (P0) e
  /// requisição malformada (PGRST1xx/2xx).
  static bool _isPermanent(PostgrestException e) {
    final code = e.code ?? '';
    return code.startsWith('22') ||
        code.startsWith('23') ||
        code.startsWith('42') ||
        code.startsWith('P0') ||
        code.startsWith('PGRST1') ||
        code.startsWith('PGRST2');
  }

  /// Casos em que a rejeição se resolve sozinha. Devolve `true` se tratou.
  Future<bool> _handleKnownRejection(OutboxEntry entry, PostgrestException e) async {
    // Produto com este nome já existe no servidor (criado em outro aparelho,
    // por exemplo): descarta a cópia local e a busca traz a verdadeira.
    if (entry.targetTable == 'products' && entry.op == 'insert' && e.code == '23505') {
      await _db.transaction(() async {
        await (_db.delete(_db.localProducts)..where((p) => p.id.equals(entry.rowId))).go();
        await _db.discardEntry(entry.id);
      });
      unawaited(pullAll());
      return true;
    }
    return false;
  }

  // -------------------------------------------------------------------
  // Recebimento
  // -------------------------------------------------------------------

  /// Busca tudo o que o usuário pode ver (a RLS filtra no servidor).
  Future<void> pullAll() {
    return _guard(() async {
      for (final table in ['lists', 'items', 'products']) {
        await applyRemoteRows(table, await _remote.selectAll(table));
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

  // -------------------------------------------------------------------

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

/// O UPDATE não atingiu nenhuma linha.
class _RowNotFound implements Exception {
  const _RowNotFound(this.message);
  final String message;

  @override
  String toString() => message;
}
