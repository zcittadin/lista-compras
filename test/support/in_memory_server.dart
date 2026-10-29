import 'dart:io';

import 'package:lista_compras/services/remote_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Um "Supabase" em memória, com o comportamento que a sincronização usa:
/// upsert por id, update por campos, `updated_at` e `updated_by` carimbados
/// (como o trigger do servidor; `updated_at` só cresce) e visibilidade por usuário (como a RLS).
///
/// Vários aparelhos de teste compartilham o mesmo [InMemoryServer], cada um
/// por meio do seu [ServerGateway].
class InMemoryServer {
  final tables = <String, Map<String, Map<String, dynamic>>>{
    'lists': {},
    'items': {},
    'products': {},
  };

  var _tick = 0;

  /// Relógio do servidor: cada gravação recebe um instante maior que o anterior.
  String now() => DateTime.utc(2026, 10, 12, 10).add(Duration(seconds: ++_tick)).toIso8601String();

  /// Linhas de [table] que [user] pode ver. `lists`: dono ou membro; `items`:
  /// quem vê a lista; `products`: só o dono. [members] diz quem participa de cada lista.
  final members = <String, Set<String>>{}; // listId -> userIds

  bool canSee(String user, String table, Map<String, dynamic> row) {
    switch (table) {
      case 'lists':
        return row['owner_id'] == user || (members[row['id']]?.contains(user) ?? false);
      case 'items':
        final list = tables['lists']![row['list_id']];
        return list != null && canSee(user, 'lists', list);
      default:
        return row['owner_id'] == user;
    }
  }

  void share(String listId, String user) => members.putIfAbsent(listId, () => {}).add(user);

  void unshare(String listId, String user) => members[listId]?.remove(user);

  Map<String, dynamic> _defaults(String table, String user) {
    switch (table) {
      case 'lists':
        return {'owner_id': user, 'category': 'mercado', 'deleted_at': null};
      case 'items':
        return {
          'quantity': null, 'unit': null, 'note': null, 'checked': false,
          'created_by': user, 'deleted_at': null,
        };
      default:
        return {'owner_id': user, 'default_unit': null, 'category': null, 'deleted_at': null};
    }
  }

  /// O trigger de `updated_at` (e, em listas e itens, `updated_by` - migração 0004).
  Map<String, dynamic> _stamp(String table, String user) =>
      {'updated_at': now(), if (table != 'products') 'updated_by': user};

  /// A migração 0002: no máximo um produto ATIVO por (dono, nome sem diferenciar
  /// maiúsculas). Produtos apagados não contam.
  void _checkProductUnique(Map<String, dynamic> row) {
    if (row['deleted_at'] != null) return;
    final name = (row['name'] as String).toLowerCase();
    for (final other in tables['products']!.values) {
      if (other['id'] != row['id'] &&
          other['owner_id'] == row['owner_id'] &&
          other['deleted_at'] == null &&
          (other['name'] as String).toLowerCase() == name) {
        throw PostgrestException(
          message: 'duplicate key value violates unique constraint "products_owner_name_active_idx"',
          code: '23505',
        );
      }
    }
  }

  void upsert(String user, String table, Map<String, dynamic> row) {
    final id = row['id'] as String;
    final existing = tables[table]![id];
    final merged = existing == null
        ? {..._defaults(table, user), 'created_at': now(), ...row, ..._stamp(table, user)}
        : {...existing, ...row, ..._stamp(table, user)};
    if (table == 'products') _checkProductUnique(merged);
    // Trigger da migração 0003: item criado sem posição vai para o fim da lista.
    if (table == 'items' && existing == null && merged['position'] == null) {
      final positions = [
        for (final r in tables['items']!.values)
          if (r['list_id'] == merged['list_id'] && r['position'] != null) (r['position'] as num).toDouble(),
      ];
      merged['position'] = (positions.isEmpty ? 0.0 : positions.reduce((a, b) => a > b ? a : b)) + 1;
    }
    tables[table]![id] = merged;
  }

  /// Atômico: se uma linha for recusada, nenhuma fica gravada.
  void upsertMany(String user, String table, List<Map<String, dynamic>> rows) {
    final snapshot = Map<String, Map<String, dynamic>>.of(tables[table]!);
    try {
      for (final row in rows) {
        upsert(user, table, row);
      }
    } catch (_) {
      tables[table]!
        ..clear()
        ..addAll(snapshot);
      rethrow;
    }
  }

  bool update(String user, String table, String id, Map<String, dynamic> fields) {
    final row = tables[table]![id];
    if (row == null || !canSee(user, table, row)) return false;
    final merged = {...row, ...fields, ..._stamp(table, user)};
    if (table == 'products') _checkProductUnique(merged);
    tables[table]![id] = merged;
    return true;
  }
}

class ServerGateway implements RemoteGateway {
  ServerGateway(this.server, this.user);

  final InMemoryServer server;
  final String user;

  /// Quando `false`, toda chamada falha como se não houvesse rede.
  bool online = true;

  /// Se definido, é chamado DEPOIS de o servidor aplicar um envio e ANTES de a
  /// resposta voltar: lançar aqui simula a conexão caindo no pior momento.
  void Function()? afterApply;

  void _requireNetwork() {
    if (!online) throw const SocketException('sem rede');
  }

  @override
  Future<void> upsert(String table, Map<String, dynamic> row) async {
    _requireNetwork();
    server.upsert(user, table, row);
    afterApply?.call();
  }

  /// Quantas requisições de lote o servidor recebeu (para os testes).
  int manyCalls = 0;

  @override
  Future<void> upsertMany(String table, List<Map<String, dynamic>> rows) async {
    _requireNetwork();
    manyCalls++;
    server.upsertMany(user, table, rows);
    afterApply?.call();
  }

  @override
  Future<bool> update(String table, String id, Map<String, dynamic> fields) async {
    _requireNetwork();
    final changed = server.update(user, table, id, fields);
    afterApply?.call();
    return changed;
  }

  List<Map<String, dynamic>> _visible(String table) => [
        for (final r in server.tables[table]!.values)
          if (server.canSee(user, table, r)) r,
      ];

  @override
  Future<List<Map<String, dynamic>>> selectAll(String table) async {
    _requireNetwork();
    return _visible(table);
  }

  @override
  Future<List<String>> selectIds(String table) async {
    _requireNetwork();
    return [for (final r in _visible(table)) r['id'] as String];
  }

  @override
  Future<List<Map<String, dynamic>>> selectUpdatedSince(String table, DateTime since) async {
    _requireNetwork();
    return [
      for (final r in _visible(table))
        if (!DateTime.parse(r['updated_at'] as String).isBefore(since)) r,
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> selectByIds(String table, List<String> ids) async {
    _requireNetwork();
    return [
      for (final r in _visible(table))
        if (ids.contains(r['id'])) r,
    ];
  }
}
