import 'dart:async';

import 'package:lista_compras/services/remote_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PostgrestException serverError(String code) =>
    PostgrestException(message: 'erro $code', code: code);

/// Servidor falso: guarda tabelas em memória, registra as chamadas e permite
/// simular falhas (lançando em [onSend] ou em [onQuery]).
class FakeGateway implements RemoteGateway {
  final calls = <String>[];
  final payloads = <Map<String, dynamic>>[];

  /// Linhas "no servidor", por tabela. Os testes de busca preenchem isto.
  final server = <String, List<Map<String, dynamic>>>{
    'lists': [],
    'items': [],
    'products': [],
  };

  /// Chamado a cada envio (upsert/update); pode lançar para simular falhas.
  FutureOr<void> Function(String op, String table, Map<String, dynamic> row)? onSend;

  /// Chamado a cada consulta de leitura; pode lançar (ex.: sem rede).
  FutureOr<void> Function(String query, String table)? onQuery;

  bool updateFindsRow = true;

  @override
  Future<void> upsert(String table, Map<String, dynamic> row) async {
    calls.add('upsert $table ${row['id']}');
    payloads.add(row);
    await onSend?.call('upsert', table, row);
  }

  /// Tudo ou nada, como no servidor: [onSend] é chamado por linha e, se lançar,
  /// o lote inteiro falha.
  @override
  Future<void> upsertMany(String table, List<Map<String, dynamic>> rows) async {
    calls.add('upsertMany $table ${rows.length}');
    payloads.addAll(rows);
    for (final row in rows) {
      await onSend?.call('upsert', table, row);
    }
  }

  @override
  Future<bool> update(String table, String id, Map<String, dynamic> fields) async {
    calls.add('update $table $id');
    payloads.add(fields);
    await onSend?.call('update', table, fields);
    return updateFindsRow;
  }

  Future<List<Map<String, dynamic>>> _read(String query, String table) async {
    calls.add('$query $table');
    await onQuery?.call(query, table);
    return server[table]!;
  }

  @override
  Future<List<Map<String, dynamic>>> selectAll(String table) =>
      _read('selectAll', table);

  @override
  Future<List<String>> selectIds(String table) async =>
      [for (final r in await _read('selectIds', table)) r['id'] as String];

  @override
  Future<List<Map<String, dynamic>>> selectUpdatedSince(String table, DateTime since) async => [
        for (final r in await _read('selectUpdatedSince', table))
          if (!DateTime.parse(r['updated_at'] as String).isBefore(since)) r,
      ];

  @override
  Future<List<Map<String, dynamic>>> selectByIds(String table, List<String> ids) async => [
        for (final r in await _read('selectByIds', table))
          if (ids.contains(r['id'])) r,
      ];
}
