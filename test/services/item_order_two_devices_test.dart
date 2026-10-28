import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/shopping_list.dart';

import '../support/device.dart';
import '../support/in_memory_server.dart';

void main() {
  late InMemoryServer server;
  late Device a;
  late Device b;
  late String listId;

  setUp(() async {
    server = InMemoryServer();
    a = Device(server, 'a');
    b = Device(server, 'b');
    await a.lists.createList(name: 'Mercado', category: ListCategory.mercado);
    listId = await a.listId('Mercado');
    for (final n in ['Pão', 'Leite', 'Ovos', 'Café']) {
      await a.items.addItem(listId, name: n);
    }
    await a.sync_();
    server.share(listId, 'b');
    await b.sync_();
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });

  Future<List<String>> order(Device d) async => [for (final i in await d.itemsOf(listId)) i.name];

  Future<void> move(Device d, String name, {String? after, String? before}) async => d.items.moveItem(
        listId,
        (await d.item(listId, name)).id,
        afterId: after == null ? null : (await d.item(listId, after)).id,
        beforeId: before == null ? null : (await d.item(listId, before)).id,
      );

  test('a ordem inicial é a mesma nos dois aparelhos', () async {
    expect(await order(a), ['Pão', 'Leite', 'Ovos', 'Café']);
    expect(await order(b), ['Pão', 'Leite', 'Ovos', 'Café']);
  });

  test('reordenar num aparelho aparece no outro', () async {
    await move(a, 'Café', before: 'Pão');
    await a.sync_();
    await b.sync_();

    expect(await order(b), ['Café', 'Pão', 'Leite', 'Ovos']);
  });

  test('movimentos simultâneos offline: os dois terminam com a MESMA ordem', () async {
    await a.goOffline();
    await b.goOffline();
    await move(a, 'Café', before: 'Pão'); // A põe Café no topo
    await move(b, 'Ovos', before: 'Pão'); // B põe Ovos no topo

    await a.goOnline();
    await b.goOnline();
    await a.sync_();
    await b.sync_();
    await a.sync_();

    final orderA = await order(a);
    expect(orderA, await order(b));
    expect(orderA.sublist(2), ['Pão', 'Leite']); // os dois movidos ficam no topo
  });

  test('o mesmo item movido nos dois aparelhos: vence o último a sincronizar', () async {
    await a.goOffline();
    await b.goOffline();
    await move(a, 'Leite', before: 'Pão'); // topo
    await move(b, 'Leite', after: 'Café'); // fim

    await a.goOnline();
    await a.sync_();
    await b.goOnline();
    await b.sync_(); // B sincroniza por último
    await a.sync_();

    expect(await order(a), ['Pão', 'Ovos', 'Café', 'Leite']);
    expect(await order(b), await order(a));
  });

  test('item novo criado offline durante uma reordenação vai para o fim nos dois', () async {
    await b.goOffline();
    await b.items.addItem(listId, name: 'Sal');
    await move(a, 'Café', before: 'Pão');
    await a.sync_();

    await b.goOnline();
    await b.sync_();
    await a.sync_();

    expect(await order(a), ['Café', 'Pão', 'Leite', 'Ovos', 'Sal']);
    expect(await order(b), await order(a));
  });

  test('marcar num aparelho e reordenar no outro não se atrapalham', () async {
    await b.items.setChecked((await b.item(listId, 'Leite')).id, true);
    await move(a, 'Café', after: 'Pão', before: 'Leite');
    await a.sync_();
    await b.sync_();
    await a.sync_();

    for (final d in [a, b]) {
      expect(await order(d), ['Pão', 'Café', 'Leite', 'Ovos']);
      expect((await d.item(listId, 'Leite')).checked, isTrue);
    }
  });

  test('celular com o app antigo (sem posição): o servidor põe o item no fim', () async {
    // Simula o app antigo: cria o item sem o campo `position`.
    server.upsert('b', 'items', {
      'id': 'antigo',
      'list_id': listId,
      'name': 'Do app antigo',
      'checked': false,
    });

    await a.sync_();

    expect((await order(a)).last, 'Do app antigo');
  });

  test('uma renumeração (rebalanceamento) chega inteira ao outro aparelho', () async {
    // Força o vão a acabar: muitos itens sempre logo abaixo de "Pão".
    var below = 'Leite';
    for (var i = 0; i < 25; i++) {
      final name = 'N$i';
      await a.items.addItem(listId, name: name);
      await move(a, name, after: 'Pão', before: below);
      below = name;
    }
    await a.sync_();
    await b.sync_();

    expect(await order(b), await order(a));
    expect((await order(b)).take(2), ['Pão', 'N24']);
  });
}
