import 'package:flutter/material.dart';

/// Categorias aceitas pelo banco (constraint em `lists.category`).
enum ListCategory {
  mercado('mercado', 'Mercado', Icons.shopping_cart),
  acougue('acougue', 'Açougue', Icons.set_meal),
  feira('feira', 'Feira', Icons.eco),
  padaria('padaria', 'Padaria', Icons.bakery_dining),
  farmacia('farmacia', 'Farmácia', Icons.medication),
  outro('outro', 'Outro', Icons.list_alt);

  const ListCategory(this.value, this.label, this.icon);

  /// Valor gravado na coluna `category`.
  final String value;
  final String label;
  final IconData icon;

  static ListCategory fromValue(String? value) =>
      values.firstWhere((c) => c.value == value, orElse: () => outro);
}

class ShoppingList {
  const ShoppingList({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.category,
  });

  final String id;
  final String ownerId;
  final String name;
  final ListCategory category;

  factory ShoppingList.fromMap(Map<String, dynamic> map) => ShoppingList(
        id: map['id'] as String,
        ownerId: map['owner_id'] as String,
        name: map['name'] as String,
        category: ListCategory.fromValue(map['category'] as String?),
      );
}
