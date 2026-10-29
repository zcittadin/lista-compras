/// "Última atualização 29/10/2026 18:27 por Fulano" (a data no fuso do celular).
/// Sem [by], termina na hora.
String formatLastUpdate(DateTime at, {String? by}) {
  final t = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final text = 'Última atualização ${two(t.day)}/${two(t.month)}/${t.year} '
      '${two(t.hour)}:${two(t.minute)}';
  return by == null ? text : '$text por $by';
}
