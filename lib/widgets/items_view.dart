import 'package:flutter/material.dart';

import '../models/item.dart';

/// Move [item] para entre [afterId] (o item que fica logo acima) e [beforeId]
/// (o que fica logo abaixo); `null` = início ou fim.
typedef MoveItem = Future<void> Function(Item item, {String? afterId, String? beforeId});

/// Os itens de uma lista, como no Google Keep:
///
/// * os pendentes primeiro, na ordem manual, reordenáveis arrastando pelo
///   puxador de 6 pontinhos (só por ele: tocar edita, deslizar apaga);
/// * depois a seção "N itens marcados", que pode ser recolhida.
///
/// Enquanto um item é arrastado (e até a nova posição ser gravada), as
/// atualizações que chegam (de outro aparelho, por exemplo) ficam em espera,
/// para a lista não "pular" na mão do usuário. Ao soltar, a nova ordem aparece
/// na hora, antes mesmo de o banco confirmar.
class ItemsView extends StatefulWidget {
  const ItemsView({
    super.key,
    required this.items,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onMove,
    this.initiallyShowChecked = true,
  });

  /// Todos os itens, já na ordem manual (marcados e pendentes misturados).
  final List<Item> items;
  final void Function(Item item, bool checked) onToggle;
  final ValueChanged<Item> onEdit;
  final ValueChanged<Item> onDelete;
  final MoveItem onMove;
  final bool initiallyShowChecked;

  @override
  State<ItemsView> createState() => _ItemsViewState();
}

class _ItemsViewState extends State<ItemsView> {
  late List<Item> _pending = _pendingOf(widget.items);
  late bool _showChecked = widget.initiallyShowChecked;

  /// Verdadeiro do início do arrasto até a nova posição ser gravada.
  bool _holding = false;

  static List<Item> _pendingOf(List<Item> items) => [for (final i in items) if (!i.checked) i];

  @override
  void didUpdateWidget(ItemsView old) {
    super.didUpdateWidget(old);
    // Durante o arrasto (e a gravação) a ordem da tela não muda; a próxima
    // atualização depois disso traz tudo, inclusive o que chegou no meio tempo.
    if (!_holding) _pending = _pendingOf(widget.items);
  }

  /// [newIndex] já vem ajustado pelo Flutter (`onReorderItem`): é o índice
  /// final do item na lista, depois de tirado da posição antiga.
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex == oldIndex) {
      setState(() => _holding = false);
      return;
    }
    final item = _pending[oldIndex];
    setState(() {
      _pending = [..._pending]
        ..removeAt(oldIndex)
        ..insert(newIndex, item);
    });
    final afterId = newIndex > 0 ? _pending[newIndex - 1].id : null;
    final beforeId = newIndex < _pending.length - 1 ? _pending[newIndex + 1].id : null;
    try {
      await widget.onMove(item, afterId: afterId, beforeId: beforeId);
      // A gravação gera uma atualização logo em seguida; ela é que liberará a
      // tela (não usamos a lista atual, que ainda pode ser a de antes).
      _holding = false;
    } catch (_) {
      // Não gravou: volta ao que o banco diz.
      if (mounted) {
        setState(() {
          _holding = false;
          _pending = _pendingOf(widget.items);
        });
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Não foi possível mover o item.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final checked = [for (final i in widget.items) if (i.checked) i];

    if (_pending.isEmpty && checked.isEmpty) {
      return const Center(child: Text('Lista vazia. Adicione o primeiro item abaixo.'));
    }

    return CustomScrollView(
      slivers: [
        SliverReorderableList(
          itemCount: _pending.length,
          onReorderStart: (_) => _holding = true,
          onReorderItem: _onReorder,
          proxyDecorator: (child, index, animation) => Material(
            elevation: 6,
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: child,
          ),
          itemBuilder: (context, i) {
            final item = _pending[i];
            return _ItemRow(
              key: ValueKey(item.id),
              item: item,
              dragHandle: ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                  child: Icon(Icons.drag_indicator, semanticLabel: 'Arrastar para reordenar'),
                ),
              ),
              onToggle: (v) => widget.onToggle(item, v),
              onEdit: () => widget.onEdit(item),
              onDelete: () => widget.onDelete(item),
            );
          },
        ),
        if (checked.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: InkWell(
              onTap: () => setState(() => _showChecked = !_showChecked),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
                child: Row(
                  children: [
                    Icon(_showChecked ? Icons.expand_more : Icons.chevron_right),
                    const SizedBox(width: 8),
                    Text(
                      checked.length == 1 ? '1 item marcado' : '${checked.length} itens marcados',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_showChecked)
            SliverList.builder(
              itemCount: checked.length,
              itemBuilder: (context, i) {
                final item = checked[i];
                return _ItemRow(
                  key: ValueKey(item.id),
                  item: item,
                  onToggle: (v) => widget.onToggle(item, v),
                  onEdit: () => widget.onEdit(item),
                  onDelete: () => widget.onDelete(item),
                );
              },
            ),
        ],
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    this.dragHandle,
  });

  final Item item;

  /// O puxador (só nos pendentes). Nos marcados fica um espaço do mesmo
  /// tamanho, para os textos continuarem alinhados.
  final Widget? dragHandle;
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
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            dragHandle ?? const SizedBox(width: 32),
            Expanded(
              child: ListTile(
                contentPadding: const EdgeInsets.only(right: 16),
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
            ),
          ],
        ),
      ),
    );
  }
}
