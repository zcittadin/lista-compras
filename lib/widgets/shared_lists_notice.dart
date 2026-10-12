import 'package:flutter/material.dart';

import '../models/shopping_list.dart';

/// Aviso no topo da tela inicial: "Fulano compartilhou a lista X com você".
/// Um cartão por lista nova; tocar abre a lista, o X dispensa o aviso.
class SharedListsNotice extends StatelessWidget {
  const SharedListsNotice({
    super.key,
    required this.lists,
    required this.ownerName,
    required this.onOpen,
    required this.onDismiss,
  });

  final List<ShoppingList> lists;

  /// Nome de quem compartilhou (pode ser `null`, ex.: sem conexão).
  final Future<String?> Function(String ownerId) ownerName;
  final ValueChanged<ShoppingList> onOpen;
  final ValueChanged<ShoppingList> onDismiss;

  @override
  Widget build(BuildContext context) {
    if (lists.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        for (final list in lists)
          Card(
            key: ValueKey('shared-${list.id}'),
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            color: scheme.primaryContainer,
            child: ListTile(
              leading: Icon(Icons.group_add, color: scheme.onPrimaryContainer),
              title: Text(
                'Nova lista compartilhada: ${list.name}',
                style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
              ),
              subtitle: FutureBuilder<String?>(
                future: ownerName(list.ownerId),
                builder: (context, snapshot) {
                  final who = snapshot.data;
                  return Text(
                    who == null ? 'Toque para abrir' : '$who compartilhou com você · toque para abrir',
                    style: TextStyle(color: scheme.onPrimaryContainer),
                  );
                },
              ),
              trailing: IconButton(
                tooltip: 'Dispensar',
                icon: Icon(Icons.close, color: scheme.onPrimaryContainer),
                onPressed: () => onDismiss(list),
              ),
              onTap: () => onOpen(list),
            ),
          ),
      ],
    );
  }
}
