/// Posições fracionárias para a ordem manual dos itens.
///
/// Cada item tem um número; a lista é mostrada em ordem crescente. Para pôr um
/// item entre dois outros, ele recebe a média das posições deles: só UM item
/// muda, por mais longa que seja a lista.
///
/// Depois de muitos movimentos para o mesmo lugar, a média dos vizinhos fica
/// cada vez mais próxima deles (1, 1.5, 1.25, 1.125...). Quando a distância
/// ficar menor que [minGap], é hora de renumerar a lista (rebalancear).
library;

/// Abaixo desta distância entre vizinhos, a lista é renumerada. Com `double`,
/// cabem cerca de 20 movimentos seguidos para o mesmo vão antes disso.
const minGap = 1e-6;

/// Posição para um item colocado entre [before] (o item de cima) e [after] (o
/// de baixo). `null` significa "não há item" daquele lado.
double positionBetween(double? before, double? after) {
  if (before == null && after == null) return 1;
  if (before == null) return after! - 1;
  if (after == null) return before + 1;
  return before + (after - before) / 2;
}

/// `true` se não há mais espaço útil entre [before] e [after] (ou se eles
/// estão fora de ordem, o que pode acontecer com edições simultâneas).
bool needsRebalance(double? before, double? after) {
  if (before == null || after == null) return false;
  return after - before < minGap;
}
