import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Map<String, dynamic> payloadOf(OutboxEntry e) =>
      jsonDecode(e.payload) as Map<String, dynamic>;

  group('fila de pendências', () {
    test('cria uma entrada por linha e mantém a ordem de criação', () async {
      await db.enqueue(table: 'lists', rowId: 'l1', isInsert: true, fields: {'name': 'Mercado'});
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'Arroz'});

      final pending = await db.pendingEntries();
      expect(pending.map((e) => e.rowId), ['l1', 'i1']);
      expect(pending.map((e) => e.op), ['insert', 'insert']);
    });

    test('funde edições da mesma linha, mantendo só os campos alterados', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: false, fields: {'checked': true});
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: false, fields: {'name': 'Feijão'});

      final pending = await db.pendingEntries();
      expect(pending, hasLength(1));
      expect(pending.single.op, 'update');
      expect(payloadOf(pending.single), {'checked': true, 'name': 'Feijão'});
      expect(pending.single.revision, 2);
    });

    test('a edição mais recente de um campo vence', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: false, fields: {'checked': true});
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: false, fields: {'checked': false});

      expect(payloadOf((await db.pendingEntries()).single), {'checked': false});
    });

    test('criação ainda não enviada continua sendo criação após editar', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'Leite', 'checked': false});
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: false, fields: {'checked': true});

      final e = (await db.pendingEntries()).single;
      expect(e.op, 'insert');
      expect(payloadOf(e), {'name': 'Leite', 'checked': true});
    });

    test('linhas diferentes não se misturam, nem tabelas com o mesmo id', () async {
      await db.enqueue(table: 'items', rowId: 'x', isInsert: false, fields: {'a': 1});
      await db.enqueue(table: 'lists', rowId: 'x', isInsert: false, fields: {'b': 2});

      expect(await db.pendingEntries(), hasLength(2));
    });

    test('markSent remove a entrada enviada', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'Pão'});
      final entry = (await db.pendingEntries()).single;

      await db.markSent(entry);

      expect(await db.pendingEntries(), isEmpty);
    });

    test('edição durante o envio não se perde: fica na fila como update', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'Pão'});
      final inFlight = (await db.pendingEntries()).single; // "enviando" a revisão 1

      // O usuário edita enquanto o envio está em andamento.
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: false, fields: {'checked': true});
      await db.markSent(inFlight); // o envio termina

      final left = (await db.pendingEntries()).single;
      expect(left.op, 'update'); // o servidor já tem a linha
      expect(payloadOf(left)['checked'], true);
    });

    test('falha permanente tira a entrada da fila de envio', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'Pão'});
      final entry = (await db.pendingEntries()).single;

      await db.markFailedAttempt(entry, 'RLS', permanent: true);

      expect(await db.pendingEntries(), isEmpty);
      final failed = (await db.failedEntries()).single;
      expect(failed.lastError, 'RLS');
      expect(failed.attempts, 1);
    });

    test('falha temporária (rede) mantém a entrada na fila e conta a tentativa', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'Pão'});
      final entry = (await db.pendingEntries()).single;

      await db.markFailedAttempt(entry, 'sem rede', permanent: false);

      final again = (await db.pendingEntries()).single;
      expect(again.attempts, 1);
      expect(again.failed, isFalse);
    });

    test('nova edição do usuário dá outra chance a uma entrada que falhou', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'Pão'});
      await db.markFailedAttempt((await db.pendingEntries()).single, 'RLS', permanent: true);

      await db.enqueue(table: 'items', rowId: 'i1', isInsert: false, fields: {'note': 'integral'});

      final e = (await db.pendingEntries()).single;
      expect(e.failed, isFalse);
      expect(e.attempts, 0);
      expect(e.lastError, isNull);
    });

    test('pendingRowIds lista só as linhas pendentes da tabela pedida', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'a'});
      await db.enqueue(table: 'lists', rowId: 'l1', isInsert: true, fields: {'name': 'b'});

      expect(await db.pendingRowIds('items'), {'i1'});
    });

    test('contadores de pendentes e de falhas acompanham a fila', () async {
      await db.enqueue(table: 'items', rowId: 'i1', isInsert: true, fields: {'name': 'a'});
      await db.enqueue(table: 'items', rowId: 'i2', isInsert: true, fields: {'name': 'b'});
      expect(await db.watchPendingCount().first, 2);

      await db.markFailedAttempt((await db.pendingEntries()).first, 'x', permanent: true);
      expect(await db.watchPendingCount().first, 1);
      expect(await db.watchFailedCount().first, 1);
    });
  });

  group('marcos e limpeza', () {
    test('guarda e atualiza marcos', () async {
      expect(await db.getCursor('items'), isNull);
      await db.setCursor('items', '2026-10-11T10:00:00Z');
      await db.setCursor('items', '2026-10-11T11:00:00Z');
      expect(await db.getCursor('items'), '2026-10-11T11:00:00Z');
    });

    test('guarda e lê listas e itens', () async {
      final now = DateTime.utc(2026, 10, 11);
      await db.into(db.localLists).insert(LocalListsCompanion.insert(
            id: 'l1',
            ownerId: 'u1',
            name: 'Mercado',
            createdAt: now,
            updatedAt: now,
          ));
      await db.into(db.localItems).insert(LocalItemsCompanion.insert(
            id: 'i1',
            listId: 'l1',
            name: 'Arroz',
            createdAt: now,
            updatedAt: now,
            quantity: const Value(2.5),
          ));

      final item = await db.select(db.localItems).getSingle();
      expect(item.name, 'Arroz');
      expect(item.quantity, 2.5);
      expect(item.checked, isFalse);
      expect(item.deletedAt, isNull);
    });

    test('clearAll apaga tudo (troca de conta)', () async {
      final now = DateTime.utc(2026, 10, 11);
      await db.into(db.localLists).insert(LocalListsCompanion.insert(
            id: 'l1', ownerId: 'u1', name: 'Mercado', createdAt: now, updatedAt: now));
      await db.enqueue(table: 'lists', rowId: 'l1', isInsert: true, fields: {'name': 'Mercado'});
      await db.setCursor('lists', 'x');

      await db.clearAll();

      expect(await db.select(db.localLists).get(), isEmpty);
      expect(await db.pendingEntries(), isEmpty);
      expect(await db.getCursor('lists'), isNull);
    });
  });
}
