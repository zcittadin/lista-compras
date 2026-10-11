import 'package:flutter/material.dart';

import '../models/shopping_list.dart';
import '../services/auth_service.dart';
import '../services/lists_service.dart';
import 'list_screen.dart';

/// Tela inicial: as listas do usuário, atualizadas em tempo real.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Criado uma vez só: recriar o stream a cada build reabriria a conexão Realtime.
  late final _lists = ListsService.instance.watchLists();

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
            onPressed: () => AuthService.instance.signOut(),
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
                // Só o dono altera ou apaga (regra da RLS), então só ele vê o menu.
                trailing: isOwner
                    ? PopupMenuButton<String>(
                        onSelected: (action) => action == 'edit'
                            ? _showListDialog(context, list: list)
                            : _confirmDelete(context, list),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Editar')),
                          PopupMenuItem(value: 'delete', child: Text('Apagar')),
                        ],
                      )
                    : null,
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
