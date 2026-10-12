/// Emojis e o que os acompanha: pictogramas, tons de pele, bandeiras (letras
/// regionais), seletores de variação, junção de sequências (ZWJ), keycap e
/// etiquetas. Dígitos e `#` não entram.
///
/// O analisador estático ainda não reconhece `\p{Extended_Pictographic}` e
/// acusa a expressão como inválida; ela funciona em tempo de execução (o teste
/// `test/utils/text_test.dart` garante).
final _emojiLike = RegExp(
  // ignore: valid_regexps
  r'[\p{Extended_Pictographic}\u{1F3FB}-\u{1F3FF}\u{1F1E6}-\u{1F1FF}'
  r'\u{FE0E}\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]',
  unicode: true,
);

/// [text] sem emojis ("Arroz 🍚" vira "Arroz ").
String stripEmoji(String text) => text.replaceAll(_emojiLike, '');

/// Identidade de um nome de produto: sem emojis, sem espaços sobrando e sem
/// diferenciar maiúsculas. "Arroz", "arroz" e "Arroz 🍚" são o mesmo produto.
///
/// Acentos CONTAM ("Acucar" ≠ "Açúcar"), como no servidor. Um nome só de
/// emojis cai de volta no próprio texto, para não colidir com todos os outros
/// nomes só de emojis.
String nameKey(String text) {
  final plain = stripEmoji(text).replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  return plain.isEmpty ? text.trim().toLowerCase() : plain;
}

/// Minúsculas, sem acentos e sem emojis, para ordenar e buscar em português
/// ("Açúcar" fica ao lado de "Acerola", e buscar "acucar" acha "Açúcar").
///
/// Só para ordenação e busca: a unicidade de nomes diferencia acentos
/// (veja [nameKey]).
String foldForSearch(String text) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final buffer = StringBuffer();
  for (final rune in stripEmoji(text).trim().toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i] : ch);
  }
  return buffer.toString();
}
