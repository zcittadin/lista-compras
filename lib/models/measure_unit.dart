import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/text.dart';

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

  /// Outras grafias comuns (já sem acento, em minúsculas e sem ponto), úteis
  /// ao ler arquivos feitos por outras pessoas ou programas.
  static const _aliases = <MeasureUnit, List<String>>{
    un: ['und', 'unid', 'unidade', 'unidades'],
    kg: ['kgs', 'quilo', 'quilos', 'kilo', 'kilos', 'quilograma', 'quilogramas'],
    g: ['gr', 'grs', 'grama', 'gramas'],
    l: ['lt', 'lts', 'litro', 'litros'],
    ml: ['mililitro', 'mililitros'],
    dz: ['duzia', 'duzias'],
    pct: ['pc', 'pcs', 'pcts', 'pacote', 'pacotes'],
    cx: ['caixa', 'caixas'],
    m: ['mt', 'mts', 'metro', 'metros'],
  };

  /// Só para testes: confere que nenhum apelido se repete entre unidades.
  @visibleForTesting
  static Map<MeasureUnit, List<String>> get aliasesForTest => _aliases;

  static final Map<String, MeasureUnit> _lookup = {
    for (final unit in values) ...{
      foldForSearch(unit.symbol): unit,
      for (final alias in _aliases[unit] ?? const <String>[]) alias: unit,
    },
  };

  /// Reconhece o texto de uma unidade, ignorando maiúsculas, acentos e pontos
  /// ("Kg", "KG", "quilos" e "Und." viram [kg] e [un]). Devolve `null` se
  /// vazio ou desconhecido (ex.: "lata", digitada na época em que o campo era
  /// livre).
  static MeasureUnit? parse(String? text) {
    if (text == null) return null;
    final key = foldForSearch(text).replaceAll('.', '').trim();
    return key.isEmpty ? null : _lookup[key];
  }

  /// Como mostrar [text] na lista: o símbolo padronizado quando reconhecido,
  /// senão o próprio texto (para não perder unidades antigas).
  static String display(String text) => parse(text)?.symbol ?? text.trim();
}
