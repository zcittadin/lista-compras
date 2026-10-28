import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';

import '../generated_migrations/schema.dart';
import '../generated_migrations/schema_v1.dart' as v1;

/// Migrações do banco local. Os "retratos" de cada versão ficam em
/// `drift_schemas/` e os auxiliares em `test/generated_migrations/` (gerados por
/// `dart run drift_dev schema generate --data-classes --companions drift_schemas test/generated_migrations`).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('instalação nova: o esquema criado é o da versão 2', () async {
    final schema = await verifier.schemaAt(2);
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 2);
    await db.close();
  });

  test('atualização 1 → 2: o esquema resultante é idêntico ao de uma instalação nova', () async {
    final schema = await verifier.schemaAt(1);
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 2);
    await db.close();
  });

  group('atualização 1 → 2 com dados (o celular de vocês)', () {
    final base = DateTime.utc(2026, 10, 12, 10);

    Future<void> seedV1(QueryExecutor connection) async {
      final old = v1.DatabaseAtV1(connection);
      Future<void> item(String id, String listId, int minute, {bool checked = false}) =>
          old.into(old.localItems).insert(v1.LocalItemsCompanion.insert(
                id: id,
                listId: listId,
                name: 'Item $id',
                // Tipos crus do SQLite, como o app grava: booleano 0/1 e data
                // como texto ISO em UTC (build.yaml).
                checked: Value(checked ? 1 : 0),
                createdAt: base.add(Duration(minutes: minute)).toIso8601String(),
                updatedAt: base.toIso8601String(),
              ));

      // Lista A, inseridos fora de ordem; "a2" e "a2b" criados no mesmo instante.
      await item('a3', 'A', 3);
      await item('a1', 'A', 1, checked: true);
      await item('a2b', 'A', 2);
      await item('a2', 'A', 2);
      // Lista B tem a própria numeração.
      await item('b2', 'B', 9);
      await item('b1', 'B', 5);

      // Outras tabelas não podem ser afetadas.
      await old.into(old.outboxEntries).insert(v1.OutboxEntriesCompanion.insert(
            targetTable: 'items',
            rowId: 'a3',
            op: 'update',
            payload: '{"checked":true}',
          ));
      await old.into(old.syncCursors).insert(v1.SyncCursorsCompanion.insert(key: 'db_owner', value: 'u1'));
      await old.close();
    }

    test('numera as posições por lista, na ordem de criação, com desempate por id', () async {
      final schema = await verifier.schemaAt(1);
      await seedV1(schema.newConnection());

      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 2);

      final rows = await db.select(db.localItems).get();
      final position = {for (final r in rows) r.id: r.position};
      expect(position, {
        'a1': 1.0,
        'a2': 2.0, // mesmo instante que a2b: "a2" < "a2b"
        'a2b': 3.0,
        'a3': 4.0,
        'b1': 1.0,
        'b2': 2.0,
      });
      await db.close();
    });

    test('preserva todo o resto: itens, marcações, fila de pendências e marcos', () async {
      final schema = await verifier.schemaAt(1);
      await seedV1(schema.newConnection());

      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 2);

      final items = await db.select(db.localItems).get();
      expect(items, hasLength(6));
      expect(items.firstWhere((i) => i.id == 'a1').checked, isTrue);
      expect(items.firstWhere((i) => i.id == 'a3').name, 'Item a3');
      expect((await db.pendingEntries()).single.rowId, 'a3');
      expect(await db.getCursor('db_owner'), 'u1');
      await db.close();
    });

    test('banco sem itens também migra', () async {
      final schema = await verifier.schemaAt(1);
      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 2);
      expect(await db.select(db.localItems).get(), isEmpty);
      await db.close();
    });
  });
}
