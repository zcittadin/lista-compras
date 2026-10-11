import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/shopping_list.dart';

/// Acesso às listas no Supabase.
///
/// Realtime: `stream()` abre uma conexão WebSocket e emite a lista completa
/// sempre que uma linha da tabela muda. A RLS continua valendo: o servidor
/// só envia as listas que o usuário pode ver (as suas e as compartilhadas).
///
/// Exclusão suave: apagar é gravar `deleted_at`; as telas filtram essas linhas.
class ListsService {
  ListsService._();
  static final instance = ListsService._();

  static const _uuid = Uuid();

  SupabaseClient get _supabase => Supabase.instance.client;

  Stream<List<ShoppingList>> watchLists() {
    return _supabase
        .from('lists')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .map(
          (rows) => rows
              .where((row) => row['deleted_at'] == null)
              .map(ShoppingList.fromMap)
              .toList(),
        );
  }

  /// O id nasce no celular (UUID), como pede o plano do modo offline.
  /// O `owner_id` vem do `auth.uid()` por padrão no banco.
  Future<void> createList({
    required String name,
    required ListCategory category,
  }) {
    return _supabase.from('lists').insert({
      'id': _uuid.v4(),
      'name': name.trim(),
      'category': category.value,
    });
  }

  Future<void> updateList(
    String id, {
    required String name,
    required ListCategory category,
  }) {
    return _supabase
        .from('lists')
        .update({'name': name.trim(), 'category': category.value})
        .eq('id', id);
  }

  Future<void> deleteList(String id) {
    return _supabase
        .from('lists')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id);
  }
}
