import 'package:flutter/material.dart';

import '../data/app_database.dart';

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

  factory ShoppingList.fromLocal(LocalList row) => ShoppingList(
        id: row.id,
        ownerId: row.ownerId,
        name: row.name,
        category: ListCategory.fromValue(row.category),
      );
}
