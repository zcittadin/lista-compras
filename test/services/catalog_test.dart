import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/data/app_database.dart';
import 'package:lista_compras/screens/sync_issues_screen.dart';
import 'package:lista_compras/services/products_service.dart';

import '../support/device.dart';
import '../support/in_memory_server.dart';

void main() {
  group('gerenciamento do catálogo (um aparelho)', () {
    late AppDatabase db;
    late ProductsService products;

    var clock = DateTime.utc(2026, 10, 12, 10);
    DateTime tick() => clock = clock.add(const Duration(milliseconds: 1));

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      products = ProductsService(db, currentUserId: () => 'u1', now: tick);
    });
    tearDown(() => db.close());

    Map<String, dynamic> payloadOf(OutboxEntry e) => jsonDecode(e.payload) as Map<String, dynamic>;
    Future<List<String>> names() async =>
        (await products.watchProducts().first).map((p) => p.name).toList();

    group('criar', () {
      test('grava local e na fila, limpando espaços', () async {
        await products.create('  Arroz  ', unit: ' kg ');

        final p = (await products.watchProducts().first).single;
        expect(p.name, 'Arroz');
        expect(p.defaultUnit, 'kg');
        final e = (await db.pendingEntries()).single;
        expect(e.op, 'insert');
        expect(payloadOf(e), containsPair('name', 'Arroz'));
        expect(payloadOf(e), containsPair('default_unit', 'kg'));
        expect(payloadOf(e), containsPair('owner_id', 'u1'));
      });

      test('unidade vazia vira null', () async {
        await products.create('Arroz', unit: '  ');
        expect((await products.watchProducts().first).single.defaultUnit, isNull);
      });

      test('atualiza as sugestões (cache) na hora', () async {
        await products.create('Arroz', unit: 'kg');
        expect(products.find('arroz')?.defaultUnit, 'kg');
        expect(products.products.map((p) => p.name), ['Arroz']);
      });

      test('recusa nome repetido ignorando maiúsculas e acentos, sem gravar nada', () async {
        await products.create('Arroz');
        await products.create('Açúcar');

        for (final dup in ['arroz', 'ARROZ', ' Arroz ', 'açúcar', 'AÇÚCAR']) {
          await expectLater(
            products.create(dup),
            throwsA(isA<DuplicateProductException>()),
            reason: dup,
          );
        }
        expect(await names(), ['Açúcar', 'Arroz']);
        expect(await db.pendingEntries(), hasLength(2));
      });

      test('"Acucar" sem acento é outro produto (o servidor também o trata assim)', () async {
        await products.create('Açúcar');
        await products.create('Acucar'); // não lança
        expect(await names(), hasLength(2));
      });

      test('recusa nome vazio ou acima de 120 caracteres', () async {
        await expectLater(products.create('   '), throwsArgumentError);
        await expectLater(products.create('x' * 121), throwsArgumentError);
        await products.create('x' * 120); // o limite exato é aceito
        expect(await names(), hasLength(1));
      });
    });

    group('nomes com emoji', () {
      test('"Arroz" é recusado se já existe "Arroz 🍚", e vice-versa', () async {
        await products.create('Arroz 🍚', unit: 'kg');

        await expectLater(
          products.create('Arroz'),
          throwsA(
            isA<DuplicateProductException>().having((e) => e.name, 'name', 'Arroz 🍚'), // diz qual já existe
          ),
        );

        await products.delete(products.find('Arroz 🍚')!.id);
        await products.create('Arroz');
        await expectLater(
          products.create('Arroz 🍚'),
          throwsA(isA<DuplicateProductException>()),
        );
        expect(await names(), ['Arroz']);
      });

      test('emojis diferentes no mesmo nome também são o mesmo produto', () async {
        await products.create('Cerveja 🍺');
        await expectLater(products.create('Cerveja 🍻'), throwsA(isA<DuplicateProductException>()));
        await expectLater(products.create('🍺 cerveja'), throwsA(isA<DuplicateProductException>()));
      });

      test('nomes diferentes com emoji continuam sendo produtos diferentes', () async {
        await products.create('Arroz 🍚');
        await products.create('Arroz integral 🍚');
        await products.create('Feijão 🫘');
        expect(await names(), hasLength(3));
      });

      test('renomear para um nome que só difere por emoji é recusado', () async {
        await products.create('Arroz 🍚');
        await products.create('Feijão');

        await expectLater(
          products.update(products.find('Feijão')!.id, name: 'Arroz'),
          throwsA(isA<DuplicateProductException>()),
        );
      });

      test('acrescentar ou trocar o emoji do próprio nome é permitido', () async {
        await products.create('Arroz');
        final id = products.find('Arroz')!.id;

        await products.update(id, name: 'Arroz 🍚');
        await products.update(id, name: 'Arroz 🍙');

        expect(await names(), ['Arroz 🍙']);
      });

      test('produtos que já eram "duplicados" (de antes) continuam editáveis', () async {
        // Simula o catálogo antigo: "Arroz" e "Arroz 🍚" lado a lado.
        final now = DateTime.utc(2026, 10, 11);
        for (final (id, name) in [('p1', 'Arroz'), ('p2', 'Arroz 🍚')]) {
          await db.into(db.localProducts).insert(
                LocalProductsCompanion.insert(
                  id: id,
                  ownerId: 'u1',
                  name: name,
                  createdAt: now,
                  updatedAt: now,
                ),
              );
        }

        // Trocar só a unidade não é "mudar de nome": não pode ser barrado.
        await products.update('p1', name: 'Arroz', unit: 'kg');

        final p1 = (await products.watchProducts().first).firstWhere((p) => p.id == 'p1');
        expect(p1.defaultUnit, 'kg');
        // E dá para apagar um deles para resolver a duplicidade.
        await products.delete('p1');
        expect(await names(), ['Arroz 🍚']);
      });

      test('digitar "Arroz" num item não cria outro produto se existe "Arroz 🍚"', () async {
        await products.create('Arroz 🍚', unit: 'kg');

        await products.remember('Arroz');

        expect(await names(), ['Arroz 🍚']);
        // E a unidade padrão do produto "enfeitado" é reaproveitada.
        expect(products.find('Arroz')?.defaultUnit, 'kg');
      });

      test('a ordenação ignora acento e emoji', () async {
        await products.create('Arroz carioca');
        await products.create('Açúcar 🍬');
        await products.create('Amaciante 👕👖');

        expect(await names(), ['Açúcar 🍬', 'Amaciante 👕👖', 'Arroz carioca']);
      });
    });

    group('importar', () {
      test('cria os produtos novos, com unidade, e enfileira cada um', () async {
        final n = await products.importProducts([
          (name: 'Arroz', unit: 'kg'),
          (name: 'Leite', unit: 'L'),
          (name: 'Sal', unit: null),
        ]);

        expect(n, 3);
        expect(await names(), ['Arroz', 'Leite', 'Sal']);
        expect(products.find('Leite')?.defaultUnit, 'L'); // cache atualizado
        final entries = await db.pendingEntries();
        expect(entries, hasLength(3));
        expect(entries.map((e) => e.op), everyElement('insert'));
        expect(payloadOf(entries.first), containsPair('owner_id', 'u1'));
      });

      test('pula o que já existe (ignorando maiúsculas e emojis), repetido, vazio e longo', () async {
        await products.create('Arroz 🍚');

        final n = await products.importProducts([
          (name: 'arroz', unit: 'kg'), // já existe
          (name: 'Feijão', unit: 'kg'),
          (name: 'feijão', unit: 'kg'), // repetido na lista
          (name: '   ', unit: null),
          (name: 'x' * 121, unit: null),
          (name: 'Leite', unit: null),
        ]);

        expect(n, 2);
        expect(await names(), ['Arroz 🍚', 'Feijão', 'Leite']);
      });

      test('é tudo ou nada: se algo falhar, nada fica gravado', () async {
        final unlogged = ProductsService(db, currentUserId: () => null);
        await expectLater(unlogged.importProducts([(name: 'Arroz', unit: null)]), throwsStateError);
        expect(await names(), isEmpty);
        expect(await db.pendingEntries(), isEmpty);
      });

      test('importar a mesma lista de novo não cria nada', () async {
        const list = [(name: 'Arroz', unit: 'kg'), (name: 'Leite', unit: 'L')];
        await products.importProducts(list);

        expect(await products.importProducts(list), 0);
        expect(await names(), hasLength(2));
      });

      test('muitos produtos de uma vez', () async {
        final n = await products.importProducts([
          for (var i = 0; i < 500; i++) (name: 'Produto $i', unit: i.isEven ? 'un' : null),
        ]);

        expect(n, 500);
        expect(await names(), hasLength(500));
        expect(await db.pendingEntries(), hasLength(500));
      });
    });

    group('listar', () {
      test('em ordem alfabética sem diferenciar maiúsculas, sem os apagados', () async {
        await products.create('banana');
        await products.create('Abacate');
        await products.create('cebola');
        await products.create('Arroz');
        final cebola = products.find('cebola')!;
        await products.delete(cebola.id);

        expect(await names(), ['Abacate', 'Arroz', 'banana']);
      });

      test('acompanha as mudanças em tempo real', () async {
        final stream = products.watchProducts();
        final expectation = expectLater(
          stream,
          emitsInOrder([
            isEmpty,
            predicate<List<dynamic>>((l) => l.length == 1),
            predicate<List<dynamic>>((l) => l.length == 2),
          ]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await products.create('Arroz');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await products.create('Feijão');
        await expectation;
      });
    });

    group('editar', () {
      test('troca nome e unidade, enviando só esses dois campos', () async {
        await products.create('Arroz', unit: 'kg');
        for (final e in await db.pendingEntries()) {
          await db.markSent(e);
        }
        final id = products.find('Arroz')!.id;

        await products.update(id, name: 'Arroz integral', unit: 'g');

        final p = (await products.watchProducts().first).single;
        expect((p.name, p.defaultUnit), ('Arroz integral', 'g'));
        final e = (await db.pendingEntries()).single;
        expect(e.op, 'update');
        expect(payloadOf(e), {'name': 'Arroz integral', 'default_unit': 'g'});
      });

      test('limpar a unidade envia null (não "esquece" o campo)', () async {
        await products.create('Arroz', unit: 'kg');
        for (final e in await db.pendingEntries()) {
          await db.markSent(e);
        }

        await products.update(products.find('Arroz')!.id, name: 'Arroz', unit: null);

        expect((await products.watchProducts().first).single.defaultUnit, isNull);
        expect(payloadOf((await db.pendingEntries()).single), {'name': 'Arroz', 'default_unit': null});
      });

      test('mudar só as maiúsculas do próprio nome é permitido', () async {
        await products.create('arroz');
        await products.update(products.find('arroz')!.id, name: 'Arroz');
        expect(await names(), ['Arroz']);
      });

      test('recusa um nome que é de outro produto e não altera nada', () async {
        await products.create('Arroz');
        await products.create('Feijão');
        final feijao = products.find('Feijão')!;

        await expectLater(
          products.update(feijao.id, name: 'arroz'),
          throwsA(isA<DuplicateProductException>()),
        );
        expect(await names(), ['Arroz', 'Feijão']);
      });

      test('editar um produto ainda não enviado continua sendo uma única criação', () async {
        await products.create('Arroz');
        await products.update(products.find('Arroz')!.id, name: 'Arroz branco', unit: 'kg');

        final e = (await db.pendingEntries()).single;
        expect(e.op, 'insert');
        expect(payloadOf(e), containsPair('name', 'Arroz branco'));
        expect(payloadOf(e), containsPair('default_unit', 'kg'));
      });
    });

    group('apagar e desfazer', () {
      test('apagar esconde o produto, tira das sugestões e enfileira deleted_at', () async {
        await products.create('Arroz');
        for (final e in await db.pendingEntries()) {
          await db.markSent(e);
        }
        final id = products.find('Arroz')!.id;

        await products.delete(id);

        expect(await names(), isEmpty);
        expect(products.find('Arroz'), isNull);
        expect(await db.select(db.localProducts).get(), hasLength(1)); // exclusão suave
        expect(payloadOf((await db.pendingEntries()).single).keys, ['deleted_at']);
      });

      test('desfazer traz de volta', () async {
        await products.create('Arroz', unit: 'kg');
        final id = products.find('Arroz')!.id;
        await products.delete(id);

        await products.restore(id);

        final p = (await products.watchProducts().first).single;
        expect((p.name, p.defaultUnit), ('Arroz', 'kg'));
        expect(products.find('Arroz'), isNotNull);
      });

      test('desfazer depois de sincronizar envia deleted_at nulo', () async {
        await products.create('Arroz');
        final id = products.find('Arroz')!.id;
        for (final e in await db.pendingEntries()) {
          await db.markSent(e);
        }
        await products.delete(id);
        for (final e in await db.pendingEntries()) {
          await db.markSent(e);
        }

        await products.restore(id);

        expect(payloadOf((await db.pendingEntries()).single), {'deleted_at': null});
      });

      test('desfazer é recusado se outro produto ativo já usa o nome', () async {
        await products.create('Arroz');
        final oldId = products.find('Arroz')!.id;
        await products.delete(oldId);
        await products.create('Arroz'); // recriado nesse meio tempo

        await expectLater(products.restore(oldId), throwsA(isA<DuplicateProductException>()));
        expect(await names(), ['Arroz']);
      });
    });

    group('aprendizado automático (remember)', () {
      test('digitar de novo o nome de um produto apagado o recria', () async {
        await products.create('Arroz', unit: 'kg');
        final oldId = products.find('Arroz')!.id;
        await products.delete(oldId);
        expect(products.find('Arroz'), isNull);

        await products.remember('Arroz');

        final p = products.find('Arroz')!;
        expect(p.id, isNot(oldId)); // é um produto novo
        expect(await names(), ['Arroz']);
      });

      test('não mexe em produto que já existe, nem na unidade', () async {
        await products.create('Arroz', unit: 'kg');
        for (final e in await db.pendingEntries()) {
          await db.markSent(e);
        }

        await products.remember('arroz', unit: 'g');

        expect(products.find('Arroz')?.defaultUnit, 'kg');
        expect(await db.pendingEntries(), isEmpty);
      });

      test('ignora nome vazio ou longo demais sem lançar erro', () async {
        await products.remember('  ');
        await products.remember('x' * 121);
        expect(await names(), isEmpty);
      });
    });
  });

  group('catálogo com dois aparelhos do mesmo usuário', () {
    late InMemoryServer server;
    late Device phone1;
    late Device phone2;

    setUp(() {
      server = InMemoryServer();
      phone1 = Device(server, 'a');
      phone2 = Device(server, 'a'); // o mesmo usuário em outro celular
    });
    tearDown(() async {
      await phone1.close();
      await phone2.close();
    });

    List<Map<String, dynamic>> serverProducts() => server.tables['products']!.values.toList();

    test('criar e editar num celular aparece no outro', () async {
      await phone1.products.create('Arroz', unit: 'kg');
      await phone1.sync_();
      await phone2.sync_();
      await phone2.products.load();
      expect(phone2.products.find('Arroz')?.defaultUnit, 'kg');

      await phone1.products.update(phone1.products.find('Arroz')!.id, name: 'Arroz branco', unit: 'g');
      await phone1.sync_();
      await phone2.sync_();

      final p = (await phone2.products.watchProducts().first).single;
      expect((p.name, p.defaultUnit), ('Arroz branco', 'g'));
    });

    test('apagar num celular some do outro, e desfazer volta', () async {
      await phone1.products.create('Arroz');
      await phone1.sync_();
      await phone2.sync_();
      final id = phone1.products.find('Arroz')!.id;

      await phone1.products.delete(id);
      await phone1.sync_();
      await phone2.sync_();
      expect(await phone2.products.watchProducts().first, isEmpty);

      await phone1.products.restore(id);
      await phone1.sync_();
      await phone2.sync_();
      expect((await phone2.products.watchProducts().first).map((p) => p.name), ['Arroz']);
    });

    test('apagar e digitar o mesmo nome de novo funciona de ponta a ponta (migração 0002)', () async {
      await phone1.products.create('Arroz');
      await phone1.sync_();
      await phone1.products.delete(phone1.products.find('Arroz')!.id);
      await phone1.sync_();

      await phone1.products.remember('Arroz'); // digitou o nome num item
      await phone1.sync_();

      expect(await phone1.db.failedEntries(), isEmpty);
      expect(await phone1.db.pendingEntries(), isEmpty);
      expect(serverProducts(), hasLength(2)); // um apagado, um ativo
      expect(serverProducts().where((p) => p['deleted_at'] == null), hasLength(1));

      await phone2.sync_();
      expect((await phone2.products.watchProducts().first).map((p) => p.name), ['Arroz']);
    });

    test('mesmo produto criado offline nos dois celulares: sobra um só, sem falha', () async {
      await phone1.goOffline();
      await phone2.goOffline();
      await phone1.products.create('Leite', unit: 'L');
      await phone2.products.create('Leite');

      await phone1.goOnline();
      await phone1.sync_();
      await phone2.goOnline();
      await phone2.sync_(); // o servidor recusa (nome repetido): descarta a cópia local

      expect(serverProducts(), hasLength(1));
      expect(await phone2.db.failedEntries(), isEmpty);
      final seen = await phone2.products.watchProducts().first;
      expect(seen.map((p) => p.name), ['Leite']);
      expect(seen.single.defaultUnit, 'L'); // vale o do celular que chegou primeiro
    });

    test('importar um catálogo grande sobe em poucas requisições e chega ao outro celular', () async {
      final total = 250;
      await phone1.products.importProducts([
        for (var i = 0; i < total; i++) (name: 'Produto $i', unit: i % 3 == 0 ? 'kg' : null),
      ]);

      await phone1.sync_();

      expect(serverProducts(), hasLength(total));
      expect(phone1.net.manyCalls, 3); // 100 + 100 + 50, em vez de 250 requisições
      expect(await phone1.db.pendingEntries(), isEmpty);
      expect(await phone1.db.failedEntries(), isEmpty);

      await phone2.sync_();
      expect(await phone2.products.watchProducts().first, hasLength(total));
    });

    test('importar o mesmo arquivo nos dois celulares do mesmo usuário não duplica', () async {
      const list = [(name: 'Arroz', unit: 'kg'), (name: 'Leite', unit: 'L'), (name: 'Sal', unit: null)];
      await phone1.products.importProducts(list);
      await phone1.sync_();
      await phone2.sync_();
      await phone2.products.load();

      // O celular 2 importa o mesmo arquivo: a conferência vê o que já chegou.
      expect(await phone2.products.importProducts(list), 0);
      expect(serverProducts(), hasLength(3));
    });

    test('mesmo arquivo importado offline nos dois celulares: sobra um de cada, sem falha', () async {
      const list = [(name: 'Arroz', unit: 'kg'), (name: 'Leite', unit: 'L')];
      await phone1.goOffline();
      await phone2.goOffline();
      await phone1.products.importProducts(list);
      await phone2.products.importProducts(list);

      await phone1.goOnline();
      await phone1.sync_();
      await phone2.goOnline();
      await phone2.sync_(); // o lote é recusado (nomes repetidos); cada um é tratado

      expect(serverProducts(), hasLength(2));
      expect(await phone2.db.failedEntries(), isEmpty);
      expect((await phone2.products.watchProducts().first).map((p) => p.name), ['Arroz', 'Leite']);
    });

    test('renomear para um nome que o servidor já tem vira falha explicada', () async {
      await phone1.products.create('Leite');
      await phone1.products.create('Pão');
      await phone1.sync_();
      await phone2.sync_();
      await phone2.goOffline();
      await phone2.products.load();

      // Offline, o celular 2 não sabe o que o 1 faz a seguir.
      await phone1.products.create('Café');
      await phone1.sync_();
      await phone2.products.update(phone2.products.find('Pão')!.id, name: 'Café');
      await phone2.goOnline();
      await phone2.sync.push();

      final failed = (await phone2.db.failedEntries()).single;
      expect(failed.lastError, contains('23505'));
      expect(explainFailure(failed.lastError), contains('igual'));
    });
  });
}
