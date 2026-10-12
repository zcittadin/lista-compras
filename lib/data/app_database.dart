import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

// ---------------------------------------------------------------------
// Tabelas espelho: cópia local do que está no Supabase. As colunas têm os
// mesmos nomes (em camelCase aqui, snake_case no SQL) para facilitar o
// vai-e-vem. A tela lê sempre daqui, nunca direto do servidor.
// ---------------------------------------------------------------------

class LocalLists extends Table {
  TextColumn get id => text()();
  TextColumn get ownerId => text()();
  TextColumn get name => text()();
  TextColumn get category => text().withDefault(const Constant('mercado'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class LocalItems extends Table {
  TextColumn get id => text()();
  TextColumn get listId => text()();
  TextColumn get name => text()();
  RealColumn get quantity => real().nullable()();
  TextColumn get unit => text().nullable()();
  TextColumn get note => text().nullable()();
  BoolColumn get checked => boolean().withDefault(const Constant(false))();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class LocalProducts extends Table {
  TextColumn get id => text()();
  TextColumn get ownerId => text()();
  TextColumn get name => text()();
  TextColumn get defaultUnit => text().nullable()();
  TextColumn get category => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------
// Fila de pendências (outbox): o que foi feito aqui e ainda não subiu.
//
// Há no máximo UMA entrada por linha (tabela + id). Edições seguidas da
// mesma linha são fundidas na mesma entrada, que guarda só os campos
// alterados. Assim, se outra pessoa mudar outro campo da mesma linha
// enquanto você está offline, as duas mudanças sobrevivem.
// ---------------------------------------------------------------------

class OutboxEntries extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Nome da tabela no Supabase: 'lists', 'items' ou 'products'.
  TextColumn get targetTable => text()();
  TextColumn get rowId => text()();

  /// 'insert' (linha criada offline) ou 'update' (linha que já existe no servidor).
  TextColumn get op => text()();

  /// JSON {coluna_do_servidor: valor}, pronto para enviar ao Supabase.
  /// Datas já vêm como texto ISO-8601 em UTC.
  TextColumn get payload => text()();

  /// Sobe a cada fusão. Serve para não apagar da fila uma entrada que foi
  /// editada de novo enquanto o envio anterior estava em andamento.
  IntColumn get revision => integer().withDefault(const Constant(1))();

  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();

  /// Rejeitada de forma permanente (ex.: RLS): não é reenviada sozinha.
  BoolColumn get failed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {targetTable, rowId},
      ];
}

/// Marcos da sincronização incremental (ex.: último `updated_at` baixado por tabela).
class SyncCursors extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
  tables: [LocalLists, LocalItems, LocalProducts, OutboxEntries, SyncCursors],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Banco de verdade (arquivo SQLite no celular).
  AppDatabase.open() : super(driftDatabase(name: 'lista_compras'));

  @override
  int get schemaVersion => 1;

  // -------------------------------------------------------------------
  // Fila de pendências
  // -------------------------------------------------------------------

  /// Registra uma mudança para subir depois, fundindo com a entrada que já
  /// existir para a mesma linha. [fields] usa os nomes das colunas do servidor.
  ///
  /// Quem chama deve fazer isto na mesma transação que grava a linha local.
  Future<void> enqueue({
    required String table,
    required String rowId,
    required bool isInsert,
    required Map<String, Object?> fields,
  }) {
    return transaction(() async {
      final existing = await (select(outboxEntries)
            ..where((e) => e.targetTable.equals(table) & e.rowId.equals(rowId)))
          .getSingleOrNull();

      if (existing == null) {
        await into(outboxEntries).insert(
          OutboxEntriesCompanion.insert(
            targetTable: table,
            rowId: rowId,
            op: isInsert ? 'insert' : 'update',
            payload: jsonEncode(fields),
          ),
        );
        return;
      }

      final merged = {
        ...(jsonDecode(existing.payload) as Map<String, dynamic>),
        ...fields,
      };
      await (update(outboxEntries)..where((e) => e.id.equals(existing.id))).write(
        OutboxEntriesCompanion(
          // Uma criação que ainda não subiu continua sendo criação.
          op: Value(existing.op == 'insert' || isInsert ? 'insert' : 'update'),
          payload: Value(jsonEncode(merged)),
          revision: Value(existing.revision + 1),
          // Nova edição do usuário: dá uma chance nova a uma entrada que falhou.
          attempts: const Value(0),
          failed: const Value(false),
          lastError: const Value(null),
        ),
      );
    });
  }

  /// Entradas a enviar, na ordem em que nasceram (listas antes dos seus itens).
  Future<List<OutboxEntry>> pendingEntries() {
    return (select(outboxEntries)
          ..where((e) => e.failed.equals(false))
          ..orderBy([(e) => OrderingTerm.asc(e.id)]))
        .get();
  }

  Future<List<OutboxEntry>> failedEntries() {
    return (select(outboxEntries)..where((e) => e.failed.equals(true))).get();
  }

  /// Quantas mudanças aguardam envio (para o indicador da tela).
  Stream<int> watchPendingCount() {
    final count = outboxEntries.id.count();
    return (selectOnly(outboxEntries)
          ..addColumns([count])
          ..where(outboxEntries.failed.equals(false)))
        .map((row) => row.read(count) ?? 0)
        .watchSingle();
  }

  Stream<int> watchFailedCount() {
    final count = outboxEntries.id.count();
    return (selectOnly(outboxEntries)
          ..addColumns([count])
          ..where(outboxEntries.failed.equals(true)))
        .map((row) => row.read(count) ?? 0)
        .watchSingle();
  }

  /// IDs das linhas de [table] com mudanças ainda não enviadas. O recebimento
  /// do servidor não deve sobrescrever essas linhas.
  Future<Set<String>> pendingRowIds(String table) async {
    final rows = await (select(outboxEntries)
          ..where((e) => e.targetTable.equals(table)))
        .get();
    return {for (final r in rows) r.rowId};
  }

  /// Chamar após enviar [entry] com sucesso.
  ///
  /// Se a entrada foi editada durante o envio (revisão diferente), ela fica
  /// na fila como 'update': o servidor já tem a linha, falta só o resto.
  Future<void> markSent(OutboxEntry entry) {
    return transaction(() async {
      final deleted = await (delete(outboxEntries)
            ..where((e) => e.id.equals(entry.id) & e.revision.equals(entry.revision)))
          .go();
      if (deleted == 0) {
        await (update(outboxEntries)..where((e) => e.id.equals(entry.id))).write(
          const OutboxEntriesCompanion(op: Value('update')),
        );
      }
    });
  }

  /// Chamar quando o envio de [entry] falhou. Erro de rede: [permanent] falso
  /// (tenta de novo depois). Rejeição do servidor: [permanent] verdadeiro.
  Future<void> markFailedAttempt(
    OutboxEntry entry,
    String error, {
    required bool permanent,
  }) {
    return (update(outboxEntries)
          ..where((e) => e.id.equals(entry.id) & e.revision.equals(entry.revision)))
        .write(
      OutboxEntriesCompanion(
        attempts: Value(entry.attempts + 1),
        lastError: Value(error),
        failed: Value(permanent),
      ),
    );
  }

  /// Descarta uma entrada que falhou (o usuário desistiu dela).
  Future<void> discardEntry(int id) {
    return (delete(outboxEntries)..where((e) => e.id.equals(id))).go();
  }

  // -------------------------------------------------------------------
  // Marcos da sincronização
  // -------------------------------------------------------------------

  Future<String?> getCursor(String key) async {
    final row = await (select(syncCursors)..where((c) => c.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setCursor(String key, String value) {
    return into(syncCursors).insertOnConflictUpdate(
      SyncCursorsCompanion.insert(key: key, value: value),
    );
  }

  // -------------------------------------------------------------------

  /// Apaga tudo. Usado ao sair da conta, para os dados de um usuário não
  /// aparecerem para o próximo.
  Future<void> clearAll() {
    return transaction(() async {
      for (final table in allTables) {
        await delete(table).go();
      }
    });
  }
}
