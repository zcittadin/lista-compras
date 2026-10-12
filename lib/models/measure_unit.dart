/// Unidades de medida oferecidas ao cadastrar um item.
///
/// No banco a unidade continua sendo texto livre (`items.unit` e
/// `products.default_unit`): grava-se o [symbol]. O enum só existe no app, para
/// o usuário escolher em vez de digitar; por isso acrescentar uma unidade aqui
/// não exige mudança no banco.
enum MeasureUnit {
  un('un', 'unidade'),
  kg('kg', 'quilo'),
  g('g', 'grama'),
  l('L', 'litro'),
  ml('mL', 'mililitro'),
  dz('dz', 'dúzia'),
  pct('pct', 'pacote'),
  cx('cx', 'caixa'),
  m('m', 'metro');

  const MeasureUnit(this.symbol, this.label);

  /// O que é gravado no banco e mostrado na lista (ex.: "2 kg").
  final String symbol;

  /// Nome por extenso, mostrado ao escolher.
  final String label;

  /// Reconhece o texto de uma unidade já gravada, ignorando maiúsculas
  /// ("Kg" e "KG" viram [kg]). Devolve `null` se vazio ou desconhecido
  /// (ex.: "lata", digitada na época em que o campo era livre).
  static MeasureUnit? parse(String? text) {
    final key = text?.trim().toLowerCase();
    if (key == null || key.isEmpty) return null;
    for (final unit in values) {
      if (unit.symbol.toLowerCase() == key) return unit;
    }
    return null;
  }

  /// Como mostrar [text] na lista: o símbolo padronizado quando reconhecido,
  /// senão o próprio texto (para não perder unidades antigas).
  static String display(String text) => parse(text)?.symbol ?? text.trim();
}
