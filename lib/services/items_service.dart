import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/item.dart';

/// Acesso aos itens de uma lista no Supabase.
///
/// Mesma ideia do `ListsService`: UUID gerado no celular, exclusão suave
/// (`deleted_at`) e Realtime por `stream()`. A RLS garante que só membros
/// da lista leem e escrevem os itens dela.
class ItemsService {
  ItemsService._();
  static final instance = ItemsService._();

  static const _uuid = Uuid();

  SupabaseClient get _supabase => Supabase.instance.client;

  Stream<List<Item>> watchItems(String listId) {
    return _supabase
        .from('items')
        .stream(primaryKey: ['id'])
        .eq('list_id', listId)
        .order('created_at')
        .map(
          (rows) => rows
              .where((row) => row['deleted_at'] == null)
              .map(Item.fromMap)
              .toList(),
        );
  }

  /// `created_by` vem do `auth.uid()` por padrão no banco.
  Future<void> addItem(
    String listId, {
    required String name,
    num? quantity,
    String? unit,
    String? note,
  }) {
    return _supabase.from('items').insert({
      'id': _uuid.v4(),
      'list_id': listId,
      'name': name.trim(),
      'quantity': quantity,
      'unit': _emptyToNull(unit),
      'note': _emptyToNull(note),
    });
  }

  Future<void> updateItem(
    String id, {
    required String name,
    num? quantity,
    String? unit,
    String? note,
  }) {
    return _supabase.from('items').update({
      'name': name.trim(),
      'quantity': quantity,
      'unit': _emptyToNull(unit),
      'note': _emptyToNull(note),
    }).eq('id', id);
  }

  Future<void> setChecked(String id, bool checked) {
    return _supabase.from('items').update({'checked': checked}).eq('id', id);
  }

  Future<void> deleteItem(String id) {
    return _supabase
        .from('items')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id);
  }

  String? _emptyToNull(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}
