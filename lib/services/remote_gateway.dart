import 'package:supabase_flutter/supabase_flutter.dart';

/// As operações que o `SyncService` faz no servidor. Existe como interface
/// para os testes trocarem o Supabase por uma versão falsa, sem rede.
///
/// Convenção de erros: se o servidor RESPONDEU com erro, lança
/// `PostgrestException`; qualquer outra exceção (socket, DNS, timeout)
/// significa que não houve comunicação.
abstract class RemoteGateway {
  /// Cria a linha, ou atualiza se o id já existir (`INSERT ... ON CONFLICT`).
  /// Assim reenviar uma criação cujo resultado ficou incerto não duplica.
  Future<void> upsert(String table, Map<String, dynamic> row);

  /// Como [upsert], para várias linhas numa só requisição. É atômico: se o
  /// servidor recusar UMA linha, nenhuma é gravada. Quem chama, nesse caso,
  /// envia uma a uma para descobrir qual foi recusada.
  Future<void> upsertMany(String table, List<Map<String, dynamic>> rows);

  /// Atualiza só os campos de [fields] da linha [id]. Devolve `false` se nenhuma
  /// linha foi alterada (não existe ou a RLS não deixa o usuário vê-la).
  Future<bool> update(String table, String id, Map<String, dynamic> fields);

  /// Todas as linhas que o usuário pode ver (a RLS filtra no servidor).
  Future<List<Map<String, dynamic>>> selectAll(String table);

  /// Só os IDs das linhas visíveis para o usuário. Serve para descobrir o que
  /// deixou de ser visível (removido da lista, por exemplo): o servidor não
  /// avisa isso, só deixa de devolver a linha.
  Future<List<String>> selectIds(String table);

  /// Linhas alteradas em [since] ou depois (por `updated_at`).
  Future<List<Map<String, dynamic>>> selectUpdatedSince(String table, DateTime since);

  /// As linhas com esses IDs (as que o usuário não puder ver não voltam).
  Future<List<Map<String, dynamic>>> selectByIds(String table, List<String> ids);
}

class SupabaseGateway implements RemoteGateway {
  SupabaseClient get _client => Supabase.instance.client;

  /// O Supabase devolve no máximo 1000 linhas por consulta (padrão do projeto).
  static const _pageSize = 1000;

  /// Ids por consulta em `selectByIds` (para a URL não ficar enorme).
  static const _idChunk = 100;

  @override
  Future<void> upsert(String table, Map<String, dynamic> row) async {
    await _client.from(table).upsert(row, onConflict: 'id');
  }

  @override
  Future<void> upsertMany(String table, List<Map<String, dynamic>> rows) async {
    // `defaultToNull: false`: uma coluna que falta numa linha (mas existe em
    // outras) usa o padrão do banco, em vez de virar NULL.
    await _client.from(table).upsert(rows, onConflict: 'id', defaultToNull: false);
  }

  @override
  Future<bool> update(String table, String id, Map<String, dynamic> fields) async {
    // `.select('id')` faz o servidor devolver as linhas alteradas; sem ele
    // não dá para saber se o UPDATE atingiu alguma (a RLS filtra em silêncio).
    final changed = await _client.from(table).update(fields).eq('id', id).select('id');
    return changed.isNotEmpty;
  }

  @override
  Future<List<Map<String, dynamic>>> selectAll(String table) {
    return _paged((from, to) => _client.from(table).select().order('id').range(from, to));
  }

  @override
  Future<List<String>> selectIds(String table) async {
    final rows = await _paged(
      (from, to) => _client.from(table).select('id').order('id').range(from, to),
    );
    return [for (final r in rows) r['id'] as String];
  }

  @override
  Future<List<Map<String, dynamic>>> selectUpdatedSince(String table, DateTime since) {
    final iso = since.toUtc().toIso8601String();
    return _paged(
      (from, to) =>
          _client.from(table).select().gte('updated_at', iso).order('id').range(from, to),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> selectByIds(String table, List<String> ids) async {
    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < ids.length; i += _idChunk) {
      final chunk = ids.sublist(i, i + _idChunk > ids.length ? ids.length : i + _idChunk);
      result.addAll(await _client.from(table).select().inFilter('id', chunk));
    }
    return result;
  }

  /// Busca página por página até acabar. A ordem por `id` mantém as páginas estáveis.
  Future<List<Map<String, dynamic>>> _paged(
    Future<List<Map<String, dynamic>>> Function(int from, int to) fetch,
  ) async {
    final all = <Map<String, dynamic>>[];
    for (var from = 0;; from += _pageSize) {
      final page = await fetch(from, from + _pageSize - 1);
      all.addAll(page);
      if (page.length < _pageSize) return all;
    }
  }
}
