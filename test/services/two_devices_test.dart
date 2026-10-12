import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/shopping_list.dart';

import '../support/device.dart';
import '../support/in_memory_server.dart';

void main() {
  late InMemoryServer server;
  late Device a;
  late Device b;

  setUp(() {
    server = InMemoryServer();
    a = Device(server, 'a');
    b = Device(server, 'b');
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });

  /// A cria a lista "Mercado" com o item "Arroz", sobe tudo e compartilha com B.
  Future<String> sharedListWithRice() async {
    await a.lists.createList(name: 'Mercado', category: ListCategory.mercado);
    final id = await a.listId('Mercado');
    await a.items.addItem(id, name: 'Arroz');
    await a.sync_();
    server.share(id, 'b');
    await b.sync_();
    return id;
  }

  test('itens criados offline sobem ao reconectar e aparecem no outro aparelho', () async {
    await a.goOffline();
    await a.lists.createList(name: 'Mercado', category: ListCategory.mercado);
    final id = await a.listId('Mercado');
    await a.items.addItem(id, name: 'Pão');
    await a.items.addItem(id, name: 'Leite');
    await a.items.setChecked((await a.item(id, 'Pão')).id, true);
    await a.sync_(); // sem rede: nada sobe, nada se perde

    expect(server.tables['items'], isEmpty);
    expect(await a.db.pendingEntries(), hasLength(3)); // lista + 2 itens (marcação fundida)

    await a.goOnline();
    await a.sync_();
    server.share(id, 'b');
    await b.sync_();

    expect(await a.db.pendingEntries(), isEmpty);
    expect(server.tables['lists'], hasLength(1));
    expect(server.tables['items'], hasLength(2));
    final seenByB = await b.itemsOf(id);
    expect(seenByB.map((i) => i.name), ['Pão', 'Leite']); // ordem de digitação preservada
    expect(seenByB.first.checked, isTrue);
  });

  test('conflito: A marca offline enquanto B renomeia o mesmo item; os dois convergem', () async {
    final id = await sharedListWithRice();
    final itemId = (await b.item(id, 'Arroz')).id;

    await a.goOffline();
    await a.items.setChecked(itemId, true); // só o campo "checked"
    await b.items.updateItem(itemId, name: 'Arroz integral', quantity: 2, unit: 'kg');
    await b.sync_();

    await a.goOnline();
    await a.sync_();
    await b.sync_();

    for (final d in [a, b]) {
      final item = await d.item(id, 'Arroz integral');
      expect(item.checked, isTrue, reason: '${d.user}: a marcação de A não pode se perder');
      expect(item.quantityLabel, '2 kg', reason: '${d.user}: a edição de B não pode se perder');
    }
  });

  test('exclusão feita por um aparelho some no outro', () async {
    final id = await sharedListWithRice();
    await b.items.deleteItem((await b.item(id, 'Arroz')).id);
    await b.sync_();

    await a.sync_();

    expect(await a.itemsOf(id), isEmpty);
  });

  test('resposta perdida depois de o servidor aplicar: reenviar não duplica', () async {
    await a.lists.createList(name: 'Mercado', category: ListCategory.mercado);
    final id = await a.listId('Mercado');
    await a.items.addItem(id, name: 'Arroz');

    // O servidor grava a lista, mas a conexão cai antes de a resposta voltar.
    var dropped = false;
    a.net.afterApply = () {
      if (!dropped) {
        dropped = true;
        throw const SocketException('conexão caiu');
      }
    };
    await a.sync.push();
    expect(server.tables['lists'], hasLength(1));
    expect(await a.db.pendingEntries(), hasLength(2)); // A não sabe que subiu

    await a.sync.push();

    expect(server.tables['lists'], hasLength(1));
    expect(server.tables['items'], hasLength(1));
    expect(await a.db.pendingEntries(), isEmpty);
  });

  test('perder o acesso: a lista e os itens somem do aparelho de B, o resto permanece', () async {
    final id = await sharedListWithRice();
    await b.lists.createList(name: 'Só do B', category: ListCategory.outro); // pendente
    expect((await b.myLists()).map((l) => l.name), containsAll(['Mercado', 'Só do B']));

    server.unshare(id, 'b'); // A removeu B
    await b.sync_();

    expect((await b.myLists()).map((l) => l.name), ['Só do B']);
    expect(await b.itemsOf(id), isEmpty);
    expect(server.tables['lists'], hasLength(2)); // no servidor nada foi apagado
  });

  test('editar uma lista que já não é mais sua vira falha, e descartar limpa', () async {
    final id = await sharedListWithRice();
    final itemId = (await b.item(id, 'Arroz')).id;

    await b.goOffline();
    await b.items.setChecked(itemId, true); // B ainda enxerga a lista
    server.unshare(id, 'b'); // A remove B enquanto B está offline
    await b.goOnline();
    await b.sync_();

    final failed = await b.db.failedEntries();
    expect(failed, hasLength(1));
    expect(failed.single.rowId, itemId);
    // A linha continua local até o usuário decidir (a edição dele está protegida).
    expect(await b.itemsOf(id), hasLength(1));

    await b.sync.discardFailed(failed.single);

    expect(await b.itemsOf(id), isEmpty);
    expect(await b.db.failedEntries(), isEmpty);
  });

  test('convite para uma lista antiga traz a lista e todos os itens', () async {
    // A cria a lista e o item cedo; B só depois cria e sobe algo próprio,
    // deixando o marco de B mais novo que a lista de A.
    await a.lists.createList(name: 'Antiga', category: ListCategory.feira);
    final oldId = await a.listId('Antiga');
    await a.items.addItem(oldId, name: 'Banana');
    await a.sync_();

    await b.lists.createList(name: 'Do B', category: ListCategory.mercado);
    await b.sync_();
    expect((await b.myLists()).map((l) => l.name), ['Do B']);

    server.share(oldId, 'b');
    await b.sync_();

    expect((await b.myLists()).map((l) => l.name), containsAll(['Do B', 'Antiga']));
    expect((await b.itemsOf(oldId)).map((i) => i.name), ['Banana']);
  });

  test('banco de outra conta é limpo antes de sincronizar', () async {
    await a.lists.createList(name: 'Da conta A', category: ListCategory.mercado);
    await a.sync.claimDatabase('a'); // carimba o banco como sendo de "a"
    expect(await a.myLists(), hasLength(1));

    // Outra conta entra no mesmo aparelho sem passar por "Sair".
    await a.sync.claimDatabase('c');

    expect(await a.myLists(), isEmpty);
    expect(await a.db.pendingEntries(), isEmpty);
  });

  test('banco sem dono registrado (versão anterior) é assumido como do usuário atual', () async {
    await a.lists.createList(name: 'Existente', category: ListCategory.mercado);

    await a.sync.claimDatabase('a');

    expect(await a.myLists(), hasLength(1));
    expect(await a.db.getCursor('db_owner'), 'a');
  });
}
