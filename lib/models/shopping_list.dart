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
    this.lastUpdatedAt,
    this.lastUpdatedBy,
  });

  final String id;
  final String ownerId;
  final String name;
  final ListCategory category;

  /// Última atualização da lista ou de qualquer item dela, e quem fez (id do
  /// usuário). Só vem preenchido em `ListsService.watchLists`.
  final DateTime? lastUpdatedAt;
  final String? lastUpdatedBy;

  factory ShoppingList.fromLocal(
    LocalList row, {
    DateTime? lastUpdatedAt,
    String? lastUpdatedBy,
  }) =>
      ShoppingList(
        id: row.id,
        ownerId: row.ownerId,
        name: row.name,
        category: ListCategory.fromValue(row.category),
        lastUpdatedAt: lastUpdatedAt,
        lastUpdatedBy: lastUpdatedBy,
      );
}
