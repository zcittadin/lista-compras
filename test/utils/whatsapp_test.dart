import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/utils/whatsapp.dart';

void main() {
  test('a mensagem cita o nome da lista', () {
    expect(shareNoticeText('Mercado'), contains('"Mercado"'));
    expect(shareNoticeText('Mercado'), contains('Lista de Compras'));
  });

  test('o link é do wa.me, sem número, com o texto no parâmetro', () {
    final uri = whatsAppUri('Oi');
    expect(uri.scheme, 'https');
    expect(uri.host, 'wa.me');
    expect(uri.queryParameters['text'], 'Oi');
  });

  test('acentos, aspas, emojis e & sobrevivem à codificação do link', () {
    const text = 'Compartilhei "Açougue & Feira 🥩" com você';
    final uri = whatsAppUri(text);

    expect(uri.toString(), isNot(contains(' '))); // tudo codificado
    expect(Uri.parse(uri.toString()).queryParameters['text'], text);
  });
}
