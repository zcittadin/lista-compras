import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/product.dart';
import 'auth_service.dart';

/// Catálogo pessoal de produtos (tabela `products`), usado no autocompletar.
///
/// Local-first como listas e itens: lê do SQLite e mantém uma cópia em
/// memória para as sugestões; mudanças vão para a fila de pendências.
/// O catálogo é só do usuário (a RLS usa `owner_id = auth.uid()`).
class ProductsService {
  ProductsService(
    this._db, {
    required this._currentUserId,
    this._now = DateTime.now,
  });

  static final instance = ProductsService(
    AppDatabase.instance,
    currentUserId: () => AuthService.instance.currentUser?.id,
  );

  static const _uuid = Uuid();

  final AppDatabase _db;
  final String? Function() _currentUserId;
  final DateTime Function() _now;

  List<Product> _cache = [];

  /// Produtos conhecidos, em ordem alfabética.
  List<Product> get products => _cache;

  Future<void> load() async {
    final rows = await (_db.select(_db.localProducts)
          ..where((p) => p.deletedAt.isNull()))
        .get();
    _cache = rows.map(Product.fromLocal).toList()..sort(_byName);
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
  Future<void> remember(String name, {String? unit}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final cleanUnit = unit?.trim();
    final newUnit = (cleanUnit == null || cleanUnit.isEmpty) ? null : cleanUnit;
    final now = _now().toUtc();

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
      await _db.transaction(() async {
        await (_db.update(_db.localProducts)..where((p) => p.id.equals(existing.id)))
            .write(LocalProductsCompanion(
          defaultUnit: Value(newUnit),
          updatedAt: Value(now),
        ));
        await _db.enqueue(
          table: 'products',
          rowId: existing.id,
          isInsert: false,
          fields: {'default_unit': newUnit},
        );
      });
      return;
    }

    final ownerId = _currentUserId();
    if (ownerId == null) throw StateError('Nenhum usuário logado.');
    final product = Product(id: _uuid.v4(), name: trimmed, defaultUnit: newUnit);
    _cache = [..._cache, product]..sort(_byName);

    await _db.transaction(() async {
      await _db.into(_db.localProducts).insert(
            LocalProductsCompanion.insert(
              id: product.id,
              ownerId: ownerId,
              name: product.name,
              defaultUnit: Value(newUnit),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _db.enqueue(
        table: 'products',
        rowId: product.id,
        isInsert: true,
        fields: {
          'id': product.id,
          'owner_id': ownerId,
          'name': product.name,
          'default_unit': newUnit,
          'created_at': now.toIso8601String(),
        },
      );
    });
  }

  static int _byName(Product a, Product b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
