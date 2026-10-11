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

  factory Item.fromMap(Map<String, dynamic> map) => Item(
        id: map['id'] as String,
        listId: map['list_id'] as String,
        name: map['name'] as String,
        checked: map['checked'] as bool,
        quantity: map['quantity'] as num?,
        unit: map['unit'] as String?,
        note: map['note'] as String?,
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
    final hasUnit = unit != null && unit!.isNotEmpty;
    return hasUnit ? '$quantityText $unit' : quantityText;
  }
}
