import 'package:flutter/material.dart';

import '../models/product.dart';
import '../services/products_service.dart';
import 'unit_dropdown.dart';

/// Diálogo de cadastro e edição de um produto do catálogo.
///
/// Quem o abre passa [onSave], que grava de fato. Se [onSave] lançar
/// [DuplicateProductException], o diálogo continua aberto e mostra o erro no
/// campo do nome. Devolve `true` ao salvar com sucesso.
class ProductDialog extends StatefulWidget {
  const ProductDialog({super.key, this.product, required this.onSave});

  /// `null` = novo produto.
  final Product? product;
  final Future<void> Function(String name, String? unit) onSave;

  @override
  State<ProductDialog> createState() => _ProductDialogState();
}

class _ProductDialogState extends State<ProductDialog> {
  late final _name = TextEditingController(text: widget.product?.name);
  late String? _unit = UnitDropdown.normalize(widget.product?.defaultUnit);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Informe o nome.');
      return;
    }
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(name, _unit);
      if (mounted) Navigator.pop(context, true);
    } on DuplicateProductException catch (e) {
      // Mostra o nome que já existe: pode diferir do digitado só por emojis.
      if (mounted) setState(() => _error = 'Já existe um produto com este nome: ${e.name}');
    } catch (e) {
      if (mounted) setState(() => _error = 'Não foi possível salvar: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.product == null ? 'Novo produto' : 'Editar produto'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.product == null,
              maxLength: ProductsService.maxNameLength,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: 'Nome', errorText: _error),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _save(),
            ),
            UnitDropdown(initialValue: _unit, onChanged: (value) => _unit = value),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Salvar')),
      ],
    );
  }
}
