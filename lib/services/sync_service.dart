import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/app_database.dart';
import 'auth_service.dart';
import 'remote_gateway.dart';

/// Sincronização entre o SQLite local e o Supabase.
///
/// - ENVIA (`push`): percorre a fila de pendências e manda cada mudança ao
///   servidor, na ordem em que foram feitas.
/// - RECEBE: copia o servidor para o banco local, sem sobrescrever linhas com
///   mudança local ainda não enviada. O Realtime serve só de AVISO ("algo
///   mudou"); os dados vêm sempre de consultas REST, onde a RLS do servidor
///   decide o que o usuário pode ver. Nunca aplicamos o conteúdo de um evento
///   Realtime diretamente.
///
/// O envio é tentado: logo depois de cada alteração, ao abrir o app, ao voltar
/// ao primeiro plano, quando a conexão volta e a cada 30 segundos.
class SyncService with WidgetsBindingObserver {
  SyncService(
    this._db, {
    RemoteGateway? remote,
    this._currentUserId,
  }) : _remote = remote ?? SupabaseGateway();

  static final instance = SyncService(
    AppDatabase.instance,
    currentUserId: () => AuthService.instance.currentUser?.id,
  );

  /// Depois de tantas respostas de erro "talvez passageiras" do servidor,
  /// a entrada é dada como falha permanente (para não tentar para sempre).
  static const maxServerErrors = 10;

  /// Espera após uma alteração, para juntar várias edições seguidas num envio só.
  static const _pushDelay = Duration(milliseconds: 400);
  static const _retryEvery = Duration(seconds: 30);

  final AppDatabase _db;
  final RemoteGateway _remote;
  final String? Function()? _currentUserId;

  SupabaseClient get _supabase => Supabase.instance.client;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _pushTimer;
  Timer? _retryTimer;
  final ValueNotifier<bool> _online = ValueNotifier(true);

  /// `false` quando o aparelho está sem rede ou o servidor não responde.
  /// Alimenta a faixa "Sem conexão" das telas.
  ValueListenable<bool> get online => _online;

  RealtimeChannel? _channel;
  bool _started = false;
  bool _wasSubscribed = false;

  // -------------------------------------------------------------------
  // Ciclo de vida
  // -------------------------------------------------------------------

  /// Começa a sincronizar (idempotente). Chamar depois do login.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);

    // Antes de sincronizar, garante que o banco local é deste usuário.
    claimDatabase(_currentUserId?.call()).then((_) => syncNow(), onError: _logError);
    Connectivity().checkConnectivity().then((results) {
      if (results.every((r) => r == ConnectivityResult.none)) _online.value = false;
    }, onError: _logError);

    // Cada alteração do usuário agenda um envio.
    _subscriptions.add(_db.onEnqueued.listen((_) => _schedulePush()));

    // Conexão voltou (ex.: saiu do modo avião): envia e busca o que perdeu.
    _subscriptions.add(
      Connectivity().onConnectivityChanged.listen((results) {
        if (results.any((r) => r != ConnectivityResult.none)) {
          syncNow();
        } else {
          _online.value = false;
        }
      }, onError: _logError),
    );

    // Rede instável não gera evento de conexão: tenta de novo de tempos em tempos.
    _retryTimer = Timer.periodic(_retryEvery, (_) {
      push();
      // Se achamos que estamos sem conexão e não há nada a enviar, uma busca
      // serve de teste para descobrir que ela voltou.
      if (!_online.value) pullAll();
    });

    // Realtime como aviso: qualquer mudança nas tabelas dispara uma busca
    // (REST) daquela tabela. Ser convidado ou removido só mexe em
    // `list_members` e não altera a linha da lista, então esse aviso busca
    // listas e itens.
    _channel = _supabase.channel('sync-changes');
    for (final table in ['lists', 'items', 'list_members']) {
      _channel!.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _schedulePull(table == 'list_members' ? ['lists', 'items'] : [table]),
      );
    }
    _channel!.subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        // Depois de uma reconexão, pode ter havido eventos que não recebemos.
        if (_wasSubscribed) syncNow();
        _wasSubscribed = true;
      } else if (error != null) {
        _logError(error);
      }
    });
  }

  static const _ownerKey = 'db_owner';

  /// Garante que o banco local pertence a [userId]. Se pertencia a outra
  /// conta (a sessão caiu sem passar por "Sair", por exemplo), apaga tudo
  /// antes que os dados de uma pessoa apareçam para outra.
  ///
  /// Um banco sem dono registrado (versões anteriores do app) é assumido
  /// como sendo de [userId].
  Future<void> claimDatabase(String? userId) async {
    if (userId == null) return;
    final owner = await _db.getCursor(_ownerKey);
    if (owner != null && owner != userId) {
      _logError('banco local era de outra conta: limpando');
      await _db.clearAll();
    }
    if (owner != userId) await _db.setCursor(_ownerKey, userId);
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
    _pullTimer?.cancel();
    _tablesToPull.clear();
    final channel = _channel;
    _channel = null;
    if (channel != null) _supabase.removeChannel(channel);
    _started = false;
    _wasSubscribed = false;
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

  Future<void>? _pushLoop;
  bool _pushAgain = false;

  /// Envia a fila de pendências. Só uma execução por vez: se chamada durante
  /// um envio, pede uma nova rodada ao final (para pegar o que entrou nesse
  /// meio tempo) e devolve o mesmo `Future`, que só completa quando o envio
  /// em andamento termina. Assim `await push()` sempre significa "a fila foi
  /// processada".
  Future<void> push() {
    final running = _pushLoop;
    if (running != null) {
      _pushAgain = true;
      return running;
    }
    final loop = _runPushLoop();
    _pushLoop = loop;
    loop.whenComplete(() {
      if (identical(_pushLoop, loop)) _pushLoop = null;
    });
    return loop;
  }

  Future<void> _runPushLoop() async {
    do {
      _pushAgain = false;
      await _pushOnce();
    } while (_pushAgain);
  }

  Future<void> _pushOnce() async {
    for (final entry in await _db.pendingEntries()) {
      try {
        await _send(entry);
        _online.value = true;
        await _db.markSent(entry);
      } on PostgrestException catch (e) {
        // O servidor respondeu com erro (então há conexão).
        _online.value = true;
        if (await _handleKnownRejection(entry, e)) continue;
        final permanent =
            _isPermanent(e) || entry.attempts + 1 >= maxServerErrors;
        _logError(
          '${entry.targetTable}/${entry.op} ${entry.rowId} rejeitado: '
          '${e.message} (código ${e.code})${permanent ? ' [definitivo]' : ''}',
        );
        await _db.markFailedAttempt(entry, '${e.message} (código ${e.code})', permanent: permanent);
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
        _online.value = false;
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
  // Falhas: o usuário decide o que fazer com o que o servidor recusou
  // -------------------------------------------------------------------

  /// Tenta enviar de novo uma entrada que falhou.
  Future<void> retryFailed(OutboxEntry entry) async {
    await _db.resetFailed(entry.id);
    await push();
  }

  /// Desiste de uma entrada que falhou e desfaz a mudança neste aparelho:
  /// - criação: a linha (e, no caso de uma lista, os itens dela) é apagada;
  /// - alteração: volta a versão do servidor (ou a linha some, se o usuário
  ///   não a enxerga mais).
  ///
  /// Para voltar a versão do servidor é preciso ter conexão; sem ela lança
  /// uma exceção e nada é alterado.
  Future<void> discardFailed(OutboxEntry entry) async {
    final table = entry.targetTable;

    if (entry.op == 'insert') {
      await _db.transaction(() async {
        if (table == 'lists') {
          final children = await (_db.select(_db.localItems)
                ..where((i) => i.listId.equals(entry.rowId)))
              .map((i) => i.id)
              .get();
          await _db.discardEntriesForRows('items', children);
          await _deleteLocal('items', children.toSet());
        }
        await _deleteLocal(table, {entry.rowId});
        await _db.discardEntry(entry.id);
      });
      return;
    }

    final rows = await _remote.selectByIds(table, [entry.rowId]);
    await _db.transaction(() async {
      await _db.discardEntry(entry.id);
      if (rows.isEmpty) await _deleteLocal(table, {entry.rowId});
    });
    if (rows.isNotEmpty) await applyRemoteRows(table, rows);
  }

  /// Texto para a tela de problemas, ex.: `Criação do item "Arroz"`.
  Future<String> describe(OutboxEntry entry) async {
    final payload = jsonDecode(entry.payload) as Map<String, dynamic>;
    final String? localName;
    switch (entry.targetTable) {
      case 'lists':
        localName = (await (_db.select(_db.localLists)..where((t) => t.id.equals(entry.rowId)))
                .getSingleOrNull())
            ?.name;
      case 'items':
        localName = (await (_db.select(_db.localItems)..where((t) => t.id.equals(entry.rowId)))
                .getSingleOrNull())
            ?.name;
      default:
        localName = (await (_db.select(_db.localProducts)..where((t) => t.id.equals(entry.rowId)))
                .getSingleOrNull())
            ?.name;
    }
    final name = localName ?? payload['name'] as String?;

    final what = switch (entry.targetTable) {
      'lists' => 'da lista',
      'items' => 'do item',
      _ => 'do produto',
    };
    final action = entry.op == 'insert'
        ? 'Criação'
        : payload.containsKey('deleted_at')
            ? 'Exclusão'
            : 'Alteração';
    return name == null ? '$action $what' : '$action $what "$name"';
  }

  // -------------------------------------------------------------------
  // Recebimento
  // -------------------------------------------------------------------

  /// Sobreposição ao buscar "o que mudou desde o último marco": uma linha
  /// gravada mas só confirmada (commit) depois do marco ainda seria pega.
  static const _cursorOverlap = Duration(minutes: 5);

  static const _allTables = ['lists', 'items', 'products'];
  static const _pullDelay = Duration(milliseconds: 300);

  final Set<String> _tablesToPull = {};
  Timer? _pullTimer;
  Future<void>? _pullLoop;

  /// Agenda a busca de [tables], juntando avisos seguidos numa busca só.
  void _schedulePull(Iterable<String> tables) {
    _tablesToPull.addAll(tables);
    _pullTimer?.cancel();
    _pullTimer = Timer(_pullDelay, () => pull(const []));
  }

  /// Busca tudo.
  Future<void> pullAll() => pull(_allTables);

  /// Atualiza o banco local com o servidor para as tabelas pedidas. Uma
  /// execução por vez; pedidos feitos durante ela entram numa nova rodada, e
  /// o `Future` devolvido só completa quando tudo o que foi pedido foi
  /// buscado (`await pullAll()` significa "dados atualizados").
  Future<void> pull(Iterable<String> tables) {
    _tablesToPull.addAll(tables);
    final running = _pullLoop;
    if (running != null) return running;
    final loop = _runPullLoop();
    _pullLoop = loop;
    loop.whenComplete(() {
      if (identical(_pullLoop, loop)) _pullLoop = null;
    });
    return loop;
  }

  Future<void> _runPullLoop() async {
    while (_tablesToPull.isNotEmpty) {
      // Ordem fixa: listas, itens, produtos.
      final batch = _allTables.where(_tablesToPull.contains).toList();
      _tablesToPull.clear();
      for (final table in batch) {
        await _guard(() => _pullTable(table));
      }
    }
  }

  /// Sincroniza uma tabela em três passos:
  ///
  /// 1. REMOVER o que sumiu: o servidor não avisa quando você perde o acesso
  ///    a uma lista (ser removido de `list_members` não altera a linha da
  ///    lista); a linha simplesmente deixa de ser devolvida. Por isso
  ///    comparamos os IDs visíveis com os locais e apagamos os que sumiram,
  ///    exceto os que têm mudança local pendente.
  /// 2. TRAZER O QUE MUDOU desde o último marco (`updated_at`).
  /// 3. TRAZER O QUE FALTA: linhas que ficaram visíveis agora (ex.: você foi
  ///    convidado para uma lista antiga) têm `updated_at` antigo e não
  ///    apareceriam no passo 2.
  Future<void> _pullTable(String table) async {
    // Fotografia do que existia ANTES de perguntar ao servidor: só entra na
    // limpeza o que já estava sincronizado. Uma linha criada aqui durante a
    // busca ainda não está no servidor e não pode ser apagada por engano.
    final pendingAtStart = await _db.pendingRowIds(table);
    final localAtStart = await _localIds(table);
    final cursor = await _db.getCursor('pull:$table');

    final serverIds = (await _remote.selectIds(table)).toSet();

    final gone = localAtStart.difference(pendingAtStart).difference(serverIds);
    if (gone.isNotEmpty) {
      await _db.transaction(() async {
        // Reconfere: o usuário pode ter editado uma dessas linhas agora.
        final pendingNow = await _db.pendingRowIds(table);
        final toDelete = gone.difference(pendingNow);
        _logError('$table: removendo ${toDelete.length} linha(s) que o servidor não mostra mais');
        await _deleteLocal(table, toDelete);
      });
    }

    final byId = <String, Map<String, dynamic>>{};
    if (cursor == null) {
      for (final r in await _remote.selectAll(table)) {
        byId[r['id'] as String] = r;
      }
    } else {
      final since = DateTime.parse(cursor).subtract(_cursorOverlap);
      for (final r in await _remote.selectUpdatedSince(table, since)) {
        byId[r['id'] as String] = r;
      }
      final missing = serverIds.difference(await _localIds(table)).difference(byId.keys.toSet());
      if (missing.isNotEmpty) {
        for (final r in await _remote.selectByIds(table, missing.toList())) {
          byId[r['id'] as String] = r;
        }
      }
    }

    final rows = byId.values.toList();
    await applyRemoteRows(table, rows);

    _online.value = true;

    // O marco só avança depois de aplicar com sucesso.
    final newest = rows
        .map((r) => _tsOrNull(r['updated_at']))
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (newest != null) {
      final old = cursor == null ? null : DateTime.parse(cursor);
      if (old == null || newest.isAfter(old)) {
        await _db.setCursor('pull:$table', newest.toUtc().toIso8601String());
      }
    }
  }

  Future<Set<String>> _localIds(String table) async {
    switch (table) {
      case 'lists':
        return (await _db.select(_db.localLists).map((r) => r.id).get()).toSet();
      case 'items':
        return (await _db.select(_db.localItems).map((r) => r.id).get()).toSet();
      case 'products':
        return (await _db.select(_db.localProducts).map((r) => r.id).get()).toSet();
    }
    throw ArgumentError('Tabela desconhecida: $table');
  }

  Future<void> _deleteLocal(String table, Set<String> ids) async {
    if (ids.isEmpty) return;
    final list = ids.toList();
    switch (table) {
      case 'lists':
        await (_db.delete(_db.localLists)..where((t) => t.id.isIn(list))).go();
      case 'items':
        await (_db.delete(_db.localItems)..where((t) => t.id.isIn(list))).go();
      case 'products':
        await (_db.delete(_db.localProducts)..where((t) => t.id.isIn(list))).go();
      default:
        throw ArgumentError('Tabela desconhecida: $table');
    }
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
      // Sem resposta do servidor (e não um erro dele): estamos sem conexão.
      if (e is! PostgrestException) _online.value = false;
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
