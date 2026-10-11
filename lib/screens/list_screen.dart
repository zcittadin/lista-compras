import 'package:flutter/material.dart';

import '../models/item.dart';
import '../models/product.dart';
import '../models/shopping_list.dart';
import '../services/items_service.dart';
import '../services/products_service.dart';
import 'members_screen.dart';

/// Itens de uma lista, atualizados em tempo real para todos os membros.
class ListScreen extends StatefulWidget {
  const ListScreen({super.key, required this.list});

  final ShoppingList list;

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  late final _items = ItemsService.instance.watchItems(widget.list.id);
  final _newItem = TextEditingController();
  final _newItemFocus = FocusNode();
  final _products = ProductsService.instance;

  @override
  void initState() {
    super.initState();
    // Sem catálogo o app continua funcionando, só sem sugestões.
    _products.load().then((_) => null, onError: (_) => null);
  }

  @override
  void dispose() {
    _newItem.dispose();
    _newItemFocus.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e')),
        );
      }
    }
  }

  /// Abre o diálogo do novo item (nome, quantidade, unidade, observação).
  /// Cancelar descarta o item; salvar o cria.
  Future<void> _add() async {
    final name = _newItem.text.trim();
    if (name.isEmpty) return;
    _newItem.clear();
    // Se o produto já está no catálogo, a unidade padrão vem preenchida.
    final draft = Item(
      id: '',
      listId: widget.list.id,
      name: name,
      checked: false,
      unit: _products.find(name)?.defaultUnit,
    );
    final result = await showDialog<_ItemFormResult>(
      context: context,
      builder: (_) => _ItemDialog(item: draft, isNew: true),
    );
    if (result == null) return;
    await _run(() async {
      await ItemsService.instance.addItem(
        widget.list.id,
        name: result.name,
        quantity: result.quantity,
        unit: result.unit,
        note: result.note,
      );
      await _products.remember(result.name, unit: result.unit);
    });
  }

  Future<void> _edit(Item item) async {
    final result = await showDialog<_ItemFormResult>(
      context: context,
      builder: (_) => _ItemDialog(item: item, isNew: false),
    );
    if (result == null) return;
    await _run(() async {
      await ItemsService.instance.updateItem(
        item.id,
        name: result.name,
        quantity: result.quantity,
        unit: result.unit,
        note: result.note,
      );
      await _products.remember(result.name, unit: result.unit);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.list.name),
        actions: [
          IconButton(
            tooltip: 'Participantes',
            icon: const Icon(Icons.group),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => MembersScreen(list: widget.list)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Item>>(
              stream: _items,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Erro ao carregar: ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                // Pendentes primeiro; marcados vão para o fim (sort estável).
                final items = [...snapshot.data!]
                  ..sort((a, b) => a.checked == b.checked ? 0 : (a.checked ? 1 : -1));
                if (items.isEmpty) {
                  return const Center(child: Text('Lista vazia. Adicione o primeiro item abaixo.'));
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) => _ItemTile(
                    key: ValueKey(items[i].id),
                    item: items[i],
                    onToggle: (v) => _run(() => ItemsService.instance.setChecked(items[i].id, v)),
                    onEdit: () => _edit(items[i]),
                    onDelete: () => _run(() => ItemsService.instance.deleteItem(items[i].id)),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: RawAutocomplete<Product>(
                      textEditingController: _newItem,
                      focusNode: _newItemFocus,
                      displayStringForOption: (p) => p.name,
                      optionsBuilder: (value) {
                        final query = value.text.trim().toLowerCase();
                        if (query.isEmpty) return const Iterable<Product>.empty();
                        return _products.products
                            .where((p) => p.name.toLowerCase().contains(query));
                      },
                      // Escolher uma sugestão segue o mesmo caminho do botão +.
                      onSelected: (_) => _add(),
                      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          maxLength: 120,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            hintText: 'Adicionar item',
                            counterText: '',
                          ),
                          onSubmitted: (_) => _add(),
                        );
                      },
                      optionsViewOpenDirection: OptionsViewOpenDirection.up,
                      optionsViewBuilder: (context, onSelected, options) {
                        return Align(
                          alignment: Alignment.bottomLeft,
                          child: Material(
                            elevation: 4,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 240),
                              child: ListView(
                                padding: EdgeInsets.zero,
                                shrinkWrap: true,
                                children: [
                                  for (final p in options)
                                    ListTile(
                                      dense: true,
                                      title: Text(p.name),
                                      subtitle: p.defaultUnit == null ? null : Text(p.defaultUnit!),
                                      onTap: () => onSelected(p),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  IconButton.filled(
                    tooltip: 'Adicionar',
                    icon: const Icon(Icons.add),
                    onPressed: _add,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    super.key,
    required this.item,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final Item item;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final details = [
      item.quantityLabel,
      if (item.note != null) item.note!,
    ].where((s) => s.isNotEmpty).join(' · ');

    return Dismissible(
      key: ValueKey('dismiss-${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) => onDelete(),
      child: ListTile(
        leading: Checkbox(value: item.checked, onChanged: (v) => onToggle(v ?? false)),
        title: Text(
          item.name,
          style: item.checked
              ? const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey)
              : null,
        ),
        subtitle: details.isEmpty ? null : Text(details),
        onTap: onEdit,
      ),
    );
  }
}

typedef _ItemFormResult = ({String name, num? quantity, String? unit, String? note});

class _ItemDialog extends StatefulWidget {
  const _ItemDialog({required this.item, required this.isNew});

  final Item item;
  final bool isNew;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _quantity = TextEditingController(text: widget.item.quantityText);
  late final _unit = TextEditingController(text: widget.item.unit);
  late final _note = TextEditingController(text: widget.item.note);

  @override
  void dispose() {
    _name.dispose();
    _quantity.dispose();
    _unit.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    // Aceita vírgula decimal (teclado brasileiro).
    final quantity = num.tryParse(_quantity.text.trim().replaceAll(',', '.'));
    Navigator.pop(context, (
      name: name,
      quantity: quantity,
      unit: _unit.text,
      note: _note.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? 'Novo item' : 'Editar item'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nome'),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _quantity,
                    autofocus: widget.isNew,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Quantidade'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    decoration: const InputDecoration(labelText: 'Unidade', hintText: 'kg, un, L'),
                  ),
                ),
              ],
            ),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Observação'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _submit, child: const Text('Salvar')),
      ],
    );
  }
}
