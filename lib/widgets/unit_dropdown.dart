import 'package:flutter/material.dart';

import '../models/measure_unit.dart';

/// Escolha da unidade de medida (ou "Sem unidade"). Usado nos diálogos do
/// item e do produto.
///
/// Uma unidade antiga que não está no enum (texto livre de antes) aparece
/// como opção extra, para não ser perdida ao editar.
class UnitDropdown extends StatelessWidget {
  const UnitDropdown({
    super.key,
    required this.initialValue,
    required this.onChanged,
  });

  /// Símbolo gravado (ou `null`). Grafias diferentes ("Kg") são padronizadas
  /// por [normalize].
  final String? initialValue;
  final ValueChanged<String?> onChanged;

  /// O valor inicial como o dropdown o usa: o símbolo padronizado, o texto
  /// antigo se não for reconhecido, ou `null` se vazio.
  static String? normalize(String? stored) {
    final text = stored?.trim();
    if (text == null || text.isEmpty) return null;
    return MeasureUnit.display(text);
  }

  static String _describe(String? symbol) {
    if (symbol == null) return 'Sem unidade';
    final unit = MeasureUnit.parse(symbol);
    return unit == null ? symbol : '${unit.symbol} · ${unit.label}';
  }

  @override
  Widget build(BuildContext context) {
    final initial = normalize(initialValue);
    final legacy = initial != null && MeasureUnit.parse(initial) == null ? initial : null;
    final options = <String?>[
      null,
      for (final u in MeasureUnit.values) u.symbol,
      ?legacy,
    ];

    return DropdownButtonFormField<String?>(
      initialValue: initial,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Unidade'),
      items: [
        for (final o in options)
          DropdownMenuItem<String?>(
            value: o,
            child: Text(_describe(o), overflow: TextOverflow.ellipsis),
          ),
      ],
      // No campo fechado, só o símbolo (a descrição completa só cabe na lista aberta).
      selectedItemBuilder: (_) => [
        for (final o in options) Text(o ?? '—'),
      ],
      onChanged: onChanged,
    );
  }
}
