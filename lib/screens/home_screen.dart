import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../models/shopping_list.dart';
import '../services/auth_service.dart';
import '../services/lists_service.dart';
import '../services/sync_service.dart';
import 'list_screen.dart';
import 'members_screen.dart';

/// Tela inicial: as listas do usuário, atualizadas em tempo real.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Lê do banco local: não depende de internet. Criado uma vez só.
  late final _lists = ListsService.instance.watchLists();

  @override
  void initState() {
    super.initState();
    SyncService.instance.start();
  }

  /// Sair apaga o banco local. Se há mudanças que ainda não subiram ao
  /// servidor, avisa antes: elas seriam perdidas.
  Future<void> _signOut() async {
    final db = AppDatabase.instance;
    final unsent = (await db.pendingEntries()).length + (await db.failedEntries()).length;
    if (unsent > 0 && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sair mesmo assim?'),
          content: Text(
            '$unsent ${unsent == 1 ? 'alteração ainda não foi enviada' : 'alterações ainda não foram enviadas'} '
            'ao servidor e ${unsent == 1 ? 'será perdida' : 'serão perdidas'} ao sair.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sair')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final userId = AuthService.instance.currentUser?.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Minhas listas'),
        actions: [
          IconButton(
            tooltip: 'Sair',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      body: StreamBuilder<List<ShoppingList>>(
        stream: _lists,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Erro ao carregar: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final lists = snapshot.data!;
          if (lists.isEmpty) {
            return const Center(
              child: Text('Nenhuma lista ainda. Toque em + para criar.'),
            );
          }
          return ListView.builder(
            itemCount: lists.length,
            itemBuilder: (context, i) {
              final list = lists[i];
              final isOwner = list.ownerId == userId;
              return ListTile(
                leading: Icon(list.category.icon),
                title: Text(list.name),
                subtitle: Text(list.category.label),
                // Só o dono altera, apaga ou compartilha (regra da RLS); os demais
                // têm só "Participantes", onde também podem sair da lista.
                trailing: PopupMenuButton<String>(
                  onSelected: (action) {
                    switch (action) {
                      case 'share':
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => MembersScreen(list: list)),
                        );
                      case 'edit':
                        _showListDialog(context, list: list);
                      case 'delete':
                        _confirmDelete(context, list);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'share',
                      child: Text(isOwner ? 'Compartilhar' : 'Participantes'),
                    ),
                    if (isOwner) ...const [
                      PopupMenuItem(value: 'edit', child: Text('Editar')),
                      PopupMenuItem(value: 'delete', child: Text('Apagar')),
                    ],
                  ],
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ListScreen(list: list)),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nova lista',
        onPressed: () => _showListDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }
}

Future<void> _showListDialog(BuildContext context, {ShoppingList? list}) async {
  final result = await showDialog<({String name, ListCategory category})>(
    context: context,
    builder: (_) => _ListDialog(list: list),
  );
  if (result == null || !context.mounted) return;

  try {
    if (list == null) {
      await ListsService.instance.createList(
        name: result.name,
        category: result.category,
      );
    } else {
      await ListsService.instance.updateList(
        list.id,
        name: result.name,
        category: result.category,
      );
    }
  } catch (e) {
    if (context.mounted) _showError(context, e);
  }
}

Future<void> _confirmDelete(BuildContext context, ShoppingList list) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Apagar lista?'),
      content: Text('"${list.name}" deixará de aparecer para todos os membros.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Apagar'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  try {
    await ListsService.instance.deleteList(list.id);
  } catch (e) {
    if (context.mounted) _showError(context, e);
  }
}

void _showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Erro: $error')),
  );
}

class _ListDialog extends StatefulWidget {
  const _ListDialog({this.list});

  final ShoppingList? list;

  @override
  State<_ListDialog> createState() => _ListDialogState();
}

class _ListDialogState extends State<_ListDialog> {
  late final _name = TextEditingController(text: widget.list?.name);
  late ListCategory _category = widget.list?.category ?? ListCategory.mercado;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name: name, category: _category));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.list == null ? 'Nova lista' : 'Editar lista'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Nome'),
            onSubmitted: (_) => _submit(),
          ),
          DropdownButtonFormField<ListCategory>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Categoria'),
            items: [
              for (final c in ListCategory.values)
                DropdownMenuItem(value: c, child: Text(c.label)),
            ],
            onChanged: (c) => setState(() => _category = c ?? _category),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Salvar')),
      ],
    );
  }
}
