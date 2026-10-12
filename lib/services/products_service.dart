import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/product.dart';
import '../utils/text.dart';
import 'auth_service.dart';

/// Já existe um produto ativo com esse nome, ignorando maiúsculas e emojis
/// ("Arroz" × "Arroz 🍚").
class DuplicateProductException implements Exception {
  const DuplicateProductException(this.name);

  /// O nome do produto que já existe (pode diferir do digitado só por emojis).
  final String name;

  @override
  String toString() => 'Já existe um produto chamado "$name".';
}

/// Catálogo pessoal de produtos (tabela `products`).
///
/// Serve de sugestão ao digitar um item e é gerenciado na tela do catálogo.
/// Local-first como listas e itens: lê do SQLite e mantém uma cópia em
/// memória para as sugestões; mudanças vão para a fila de pendências.
/// O catálogo é só do usuário (a RLS usa `owner_id = auth.uid()`).
///
/// Os itens guardam o nome como texto, sem vínculo com o produto: renomear
/// ou apagar um produto não altera itens já criados.
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

  /// Limite de `products.name` no banco (`char_length between 1 and 120`).
  static const maxNameLength = 120;

  final AppDatabase _db;
  final String? Function() _currentUserId;
  final DateTime Function() _now;

  List<Product> _cache = [];

  /// Produtos conhecidos, em ordem alfabética (usados nas sugestões).
  List<Product> get products => _cache;

  Future<void> load() async {
    _cache = await _activeProducts();
  }

  /// Os produtos ativos, em ordem alfabética, atualizados a cada mudança.
  Stream<List<Product>> watchProducts() {
    final query = _db.select(_db.localProducts)..where((p) => p.deletedAt.isNull());
    return query.watch().map((rows) => rows.map(Product.fromLocal).toList()..sort(_byName));
  }

  Product? find(String name) {
    final key = _key(name);
    for (final p in _cache) {
      if (_key(p.name) == key) return p;
    }
    return null;
  }

  // -------------------------------------------------------------------
  // Gerenciamento (tela do catálogo)
  // -------------------------------------------------------------------

  /// Cria um produto. Lança [DuplicateProductException] se o nome já existe.
  Future<void> create(String name, {String? unit}) async {
    final cleanName = _cleanName(name);
    await _ensureNameFree(cleanName);
    final ownerId = _currentUserId();
    if (ownerId == null) throw StateError('Nenhum usuário logado.');

    final id = _uuid.v4();
    final now = _now().toUtc();
    final cleanUnit = _cleanUnit(unit);

    await _db.transaction(() async {
      await _db.into(_db.localProducts).insert(
            LocalProductsCompanion.insert(
              id: id,
              ownerId: ownerId,
              name: cleanName,
              defaultUnit: Value(cleanUnit),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _db.enqueue(
        table: 'products',
        rowId: id,
        isInsert: true,
        fields: {
          'id': id,
          'owner_id': ownerId,
          'name': cleanName,
          'default_unit': cleanUnit,
          'created_at': now.toIso8601String(),
        },
      );
    });
    await load();
  }

  /// Altera nome e unidade padrão. Lança [DuplicateProductException] se o novo
  /// nome já pertence a OUTRO produto (mudar só maiúsculas do próprio nome é permitido).
  Future<void> update(String id, {required String name, String? unit}) async {
    final cleanName = _cleanName(name);
    // Só confere duplicidade se a identidade do nome mudou. Assim, um produto
    // que já convive com outro parecido (de antes desta regra) continua
    // editável, por exemplo para trocar a unidade.
    final current = await (_db.select(_db.localProducts)..where((p) => p.id.equals(id)))
        .getSingleOrNull();
    if (current == null || _key(current.name) != _key(cleanName)) {
      await _ensureNameFree(cleanName, exceptId: id);
    }
    final cleanUnit = _cleanUnit(unit);

    await _db.transaction(() async {
      await (_db.update(_db.localProducts)..where((p) => p.id.equals(id))).write(
        LocalProductsCompanion(
          name: Value(cleanName),
          defaultUnit: Value(cleanUnit),
          updatedAt: Value(_now().toUtc()),
        ),
      );
      // Sempre os dois campos: limpar a unidade precisa enviar null.
      await _db.enqueue(
        table: 'products',
        rowId: id,
        isInsert: false,
        fields: {'name': cleanName, 'default_unit': cleanUnit},
      );
    });
    await load();
  }

  /// Apaga (exclusão suave). Pode ser desfeito com [restore].
  Future<void> delete(String id) async {
    final now = _now().toUtc();
    await _db.transaction(() async {
      await (_db.update(_db.localProducts)..where((p) => p.id.equals(id))).write(
        LocalProductsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      await _db.enqueue(
        table: 'products',
        rowId: id,
        isInsert: false,
        fields: {'deleted_at': now.toIso8601String()},
      );
    });
    await load();
  }

  /// Desfaz [delete]. Lança [DuplicateProductException] se, nesse meio tempo,
  /// outro produto ativo passou a ter o mesmo nome.
  Future<void> restore(String id) async {
    final row = await (_db.select(_db.localProducts)..where((p) => p.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    await _ensureNameFree(row.name, exceptId: id);

    await _db.transaction(() async {
      await (_db.update(_db.localProducts)..where((p) => p.id.equals(id))).write(
        LocalProductsCompanion(deletedAt: const Value(null), updatedAt: Value(_now().toUtc())),
      );
      await _db.enqueue(
        table: 'products',
        rowId: id,
        isInsert: false,
        fields: {'deleted_at': null},
      );
    });
    await load();
  }

  // -------------------------------------------------------------------
  // Aprendizado automático (ao salvar um item)
  // -------------------------------------------------------------------

  /// Garante que [name] está no catálogo, criando-o se não estiver (inclusive
  /// um produto que tenha sido apagado: digitar o nome de novo o recria).
  ///
  /// Um produto que já existe NÃO é alterado: a unidade padrão é a que foi
  /// definida no catálogo. [unit] só vale para um produto novo.
  Future<void> remember(String name, {String? unit}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > maxNameLength) return;
    if (find(trimmed) != null) return;
    try {
      await create(trimmed, unit: unit);
    } on DuplicateProductException {
      // Criado em outro lugar nesse meio tempo: nada a fazer.
    }
  }

  // -------------------------------------------------------------------

  Future<List<Product>> _activeProducts() async {
    final rows = await (_db.select(_db.localProducts)..where((p) => p.deletedAt.isNull())).get();
    return rows.map(Product.fromLocal).toList()..sort(_byName);
  }

  /// Confere no banco (não na cópia em memória, que pode estar defasada).
  /// A comparação é feita em Dart porque o SQLite só ignora maiúsculas ASCII
  /// ("Á" × "á") e não sabe o que é um emoji.
  ///
  /// Isto é mais rígido que o índice do servidor, que só compara o texto
  /// (`lower(name)`): o servidor continua barrando textos idênticos, mas
  /// "Arroz" e "Arroz 🍚" só são barrados aqui.
  Future<void> _ensureNameFree(String name, {String? exceptId}) async {
    final key = _key(name);
    for (final p in await _activeProducts()) {
      if (p.id != exceptId && _key(p.name) == key) throw DuplicateProductException(p.name);
    }
  }

  String _cleanName(String name) {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError('O nome não pode ser vazio.');
    if (clean.length > maxNameLength) {
      throw ArgumentError('O nome pode ter no máximo $maxNameLength caracteres.');
    }
    return clean;
  }

  String? _cleanUnit(String? unit) {
    final clean = unit?.trim();
    return (clean == null || clean.isEmpty) ? null : clean;
  }

  /// Identidade do nome: ignora maiúsculas e emojis (veja [nameKey]).
  static String _key(String name) => nameKey(name);

  /// Ordem alfabética em português: sem diferenciar maiúsculas nem acentos.
  static int _byName(Product a, Product b) {
    final byFolded = foldForSearch(a.name).compareTo(foldForSearch(b.name));
    return byFolded != 0 ? byFolded : _key(a.name).compareTo(_key(b.name));
  }
}
