import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/shopping_list.dart';

import '../support/device.dart';
import '../support/in_memory_server.dart';

/// "Última atualização ... por ...": o mais recente entre a lista e seus itens.
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

  Future<String> sharedList() async {
    await a.lists.createList(name: 'Mercado', category: ListCategory.mercado);
    final id = await a.listId('Mercado');
    await a.sync_();
    server.share(id, 'b');
    await b.sync_();
    return id;
  }

  Future<ShoppingList> only(Device d) async => (await d.myLists()).single;

  test('lista nova: atualizada pelo dono, na hora da criação', () async {
    await a.lists.createList(name: 'Mercado', category: ListCategory.mercado);
    final list = await only(a);
    expect(list.lastUpdatedBy, 'a');
    expect(list.lastUpdatedAt, isNotNull);
  });

  test('mexer num item atualiza a lista, e vale offline', () async {
    await a.goOffline();
    await a.lists.createList(name: 'Mercado', category: ListCategory.mercado);
    final id = await a.listId('Mercado');
    final before = (await only(a)).lastUpdatedAt!;

    await a.items.addItem(id, name: 'Arroz');

    final list = await only(a);
    expect(list.lastUpdatedAt!.isAfter(before), isTrue);
    expect(list.lastUpdatedBy, 'a');
  });

  test('o outro membro aparece como autor depois de sincronizar', () async {
    final id = await sharedList();
    await a.items.addItem(id, name: 'Arroz');
    await a.sync_();
    await b.sync_();
    expect((await only(b)).lastUpdatedBy, 'a');

    final item = await b.item(id, 'Arroz');
    await b.items.setChecked(item.id, true);
    await b.sync_();
    expect((await only(b)).lastUpdatedBy, 'b');

    await a.sync_();
    final seenByA = await only(a);
    expect(seenByA.lastUpdatedBy, 'b');
    expect(seenByA.lastUpdatedAt, (await only(b)).lastUpdatedAt);
  });

  test('apagar um item também conta como atualização', () async {
    final id = await sharedList();
    await a.items.addItem(id, name: 'Arroz');
    final item = await a.item(id, 'Arroz');
    await a.sync_();
    await b.sync_();

    await b.items.deleteItem(item.id);
    await b.sync_(); // o servidor carimba a hora (e o autor) da alteração
    expect((await only(b)).lastUpdatedBy, 'b');
  });

  test('renomear a lista conta, se for mais recente que os itens', () async {
    final id = await sharedList();
    await a.items.addItem(id, name: 'Arroz');
    await a.lists.updateList(id, name: 'Feira', category: ListCategory.feira);
    final list = await only(a);
    expect(list.lastUpdatedBy, 'a');
    expect(list.lastUpdatedAt, isNotNull);
  });

  test('item antigo sem updated_by cai no criador; lista sem, no dono', () async {
    final id = await sharedList();
    await a.items.addItem(id, name: 'Arroz');
    await a.sync_();
    // Como se vieram de um servidor sem a migração 0004.
    for (final t in ['lists', 'items']) {
      for (final row in server.tables[t]!.values) {
        row.remove('updated_by');
      }
    }
    await b.db.clearAll();
    await b.sync_();

    expect((await only(b)).lastUpdatedBy, 'a');
  });
}
