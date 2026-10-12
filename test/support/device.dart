import 'package:drift/native.dart';
import 'package:lista_compras/data/app_database.dart';
import 'package:lista_compras/models/item.dart';
import 'package:lista_compras/models/shopping_list.dart';
import 'package:lista_compras/services/items_service.dart';
import 'package:lista_compras/services/lists_service.dart';
import 'package:lista_compras/services/products_service.dart';
import 'package:lista_compras/services/sync_service.dart';

import 'in_memory_server.dart';

/// Um "celular": banco local próprio, serviços e conexão com o servidor falso.
class Device {
  Device(InMemoryServer server, this.user) {
    db = AppDatabase(NativeDatabase.memory());
    net = ServerGateway(server, user);
    sync = SyncService(db, remote: net, currentUserId: () => user);
    lists = ListsService(db, currentUserId: () => user, now: _tick);
    items = ItemsService(db, currentUserId: () => user, now: _tick);
    products = ProductsService(db, currentUserId: () => user, now: _tick);
  }

  final String user;
  late final AppDatabase db;
  late final ServerGateway net;
  late final SyncService sync;
  late final ListsService lists;
  late final ItemsService items;
  late final ProductsService products;

  static var _clock = DateTime.utc(2026, 10, 12, 8);
  static DateTime _tick() => _clock = _clock.add(const Duration(milliseconds: 1));

  Future<void> goOffline() async => net.online = false;
  Future<void> goOnline() async => net.online = true;

  /// O que o app faz ao reconectar: envia e depois busca.
  Future<void> sync_() => sync.syncNow();

  Future<List<ShoppingList>> myLists() => lists.watchLists().first;
  Future<String> listId(String name) async =>
      (await myLists()).firstWhere((l) => l.name == name).id;
  Future<List<Item>> itemsOf(String listId) => items.watchItems(listId).first;
  Future<Item> item(String listId, String name) async =>
      (await itemsOf(listId)).firstWhere((i) => i.name == name);

  Future<void> close() => db.close();
}
