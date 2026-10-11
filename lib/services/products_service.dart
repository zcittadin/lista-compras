import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/product.dart';

/// Catálogo pessoal de produtos (tabela `products`), usado no autocompletar.
///
/// Diferente de listas e itens, o catálogo é só do usuário (a RLS usa
/// `owner_id = auth.uid()`), então não precisa de Realtime: carregamos uma
/// vez ao abrir a lista e mantemos uma cópia em memória.
class ProductsService {
  ProductsService._();
  static final instance = ProductsService._();

  static const _uuid = Uuid();

  SupabaseClient get _supabase => Supabase.instance.client;

  List<Product> _cache = [];

  /// Produtos conhecidos, em ordem alfabética.
  List<Product> get products => _cache;

  Future<void> load() async {
    final rows = await _supabase
        .from('products')
        .select()
        .isFilter('deleted_at', null)
        .order('name');
    _cache = rows.map(Product.fromMap).toList();
  }

  Product? find(String name) {
    final key = name.trim().toLowerCase();
    for (final p in _cache) {
      if (p.name.toLowerCase() == key) return p;
    }
    return null;
  }

  /// Salva o produto no catálogo (ignora maiúsculas no nome).
  ///
  /// Se já existe e veio uma unidade diferente da padrão, a unidade padrão é
  /// atualizada: a última unidade que você usou vira a sugestão. Unidade
  /// vazia nunca apaga a padrão.
  ///
  /// Para produtos novos, `ignoreDuplicates` vira `ON CONFLICT DO NOTHING`:
  /// se o par (owner_id, name) já existe, o banco simplesmente não faz nada.
  Future<void> remember(String name, {String? unit}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final cleanUnit = unit?.trim();
    final newUnit = (cleanUnit == null || cleanUnit.isEmpty) ? null : cleanUnit;

    final existing = find(trimmed);
    if (existing != null) {
      if (newUnit == null || newUnit == existing.defaultUnit) return;
      _cache = [
        for (final p in _cache)
          if (p.id == existing.id)
            Product(id: p.id, name: p.name, defaultUnit: newUnit)
          else
            p,
      ];
      await _supabase
          .from('products')
          .update({'default_unit': newUnit}).eq('id', existing.id);
      return;
    }

    final product = Product(id: _uuid.v4(), name: trimmed, defaultUnit: newUnit);
    _cache = [..._cache, product]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    await _supabase.from('products').upsert({
      'id': product.id,
      'name': product.name,
      'default_unit': product.defaultUnit,
    }, onConflict: 'owner_id,name', ignoreDuplicates: true);
  }
}
