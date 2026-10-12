import '../data/app_database.dart';
import 'measure_unit.dart';

class Item {
  const Item({
    required this.id,
    required this.listId,
    required this.name,
    required this.checked,
    this.quantity,
    this.unit,
    this.note,
  });

  final String id;
  final String listId;
  final String name;
  final bool checked;
  final num? quantity;
  final String? unit;
  final String? note;

  factory Item.fromLocal(LocalItem row) => Item(
        id: row.id,
        listId: row.listId,
        name: row.name,
        checked: row.checked,
        quantity: row.quantity,
        unit: row.unit,
        note: row.note,
      );

  /// A quantidade como texto ("2", "0.5"), ou "" se não houver.
  String get quantityText {
    final q = quantity;
    if (q == null) return '';
    return q == q.roundToDouble() ? q.toInt().toString() : q.toString();
  }

  /// Ex.: "2 kg" ou "3". Sem quantidade, fica vazio (a unidade sozinha
  /// não faz sentido na listagem).
  String get quantityLabel {
    if (quantity == null) return '';
    final text = unit?.trim();
    if (text == null || text.isEmpty) return quantityText;
    // Unidades antigas ("Kg") aparecem padronizadas ("kg").
    return '$quantityText ${MeasureUnit.display(text)}';
  }
}
