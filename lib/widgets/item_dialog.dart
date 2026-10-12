import 'package:flutter/material.dart';

import '../models/item.dart';
import 'unit_dropdown.dart';

typedef ItemFormResult = ({String name, num? quantity, String? unit, String? note});

/// Diálogo de cadastro (novo item) e edição. Devolve um [ItemFormResult], ou
/// `null` se o usuário cancelar.
class ItemDialog extends StatefulWidget {
  const ItemDialog({super.key, required this.item, required this.isNew});

  final Item item;
  final bool isNew;

  @override
  State<ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<ItemDialog> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _quantity = TextEditingController(text: widget.item.quantityText);
  late final _note = TextEditingController(text: widget.item.note);

  /// Símbolo escolhido, ou `null` para "sem unidade".
  late String? _unit = UnitDropdown.normalize(widget.item.unit);

  @override
  void dispose() {
    _name.dispose();
    _quantity.dispose();
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
      unit: _unit,
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
                  child: UnitDropdown(
                    initialValue: _unit,
                    onChanged: (value) => _unit = value,
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
