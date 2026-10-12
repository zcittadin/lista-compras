import 'package:supabase_flutter/supabase_flutter.dart';

/// As operações que o `SyncService` faz no servidor. Existe como interface
/// para os testes trocarem o Supabase por uma versão falsa, sem rede.
///
/// Convenção de erros: se o servidor RESPONDEU com erro, lança
/// `PostgrestException`; qualquer outra exceção (socket, DNS, timeout)
/// significa que não houve comunicação.
abstract class RemoteGateway {
  /// Cria a linha, ou atualiza se o id já existir (`INSERT ... ON CONFLICT`).
  /// Assim reenviar uma criação cujo resultado não ficou claro não duplica.
  Future<void> upsert(String table, Map<String, dynamic> row);

  /// Atualiza só os campos de [fields] da linha [id]. Devolve `false` se nenhuma
  /// linha foi alterada (não existe ou a RLS não deixa o usuário vê-la).
  Future<bool> update(String table, String id, Map<String, dynamic> fields);

  /// Todas as linhas que o usuário pode ver (a RLS filtra no servidor).
  Future<List<Map<String, dynamic>>> selectAll(String table);
}

class SupabaseGateway implements RemoteGateway {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<void> upsert(String table, Map<String, dynamic> row) async {
    await _client.from(table).upsert(row, onConflict: 'id');
  }

  @override
  Future<bool> update(String table, String id, Map<String, dynamic> fields) async {
    // `.select('id')` faz o servidor devolver as linhas alteradas; sem ele
    // não dá para saber se o UPDATE atingiu alguma (a RLS filtra em silêncio).
    final changed = await _client.from(table).update(fields).eq('id', id).select('id');
    return changed.isNotEmpty;
  }

  @override
  Future<List<Map<String, dynamic>>> selectAll(String table) async {
    final rows = await _client.from(table).select();
    return List<Map<String, dynamic>>.from(rows);
  }
}
