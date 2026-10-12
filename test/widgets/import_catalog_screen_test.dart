import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/screens/import_catalog_screen.dart';

import '../support/mojibake.dart';

Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

class Harness {
  Harness(this.tester);

  final WidgetTester tester;
  final imported = <List<ImportItem>>[];
  int? result;
  bool closed = false;

  /// Abre a tela a partir de um botão (para poder ver o que ela devolve ao fechar).
  Future<void> open({
    List<String> existing = const [],
    Future<Uint8List?> Function()? pickFile,
    Future<int> Function(List<ImportItem>)? onImport,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.push<int>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ImportCatalogScreen(
                      existingNames: existing,
                      pickFile: pickFile ?? () async => null,
                      onImport: (items) async {
                        imported.add(items);
                        return onImport != null ? onImport(items) : items.length;
                      },
                    ),
                  ),
                );
                closed = true;
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  Future<void> paste(String text) async {
    await tester.tap(find.text('Colar texto'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('Analisar'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseFile() async {
    await tester.tap(find.text('Escolher arquivo'));
    await tester.pumpAndSettle();
  }
}

Finder importButton(String label) => find.widgetWithText(FilledButton, label);

void main() {
  testWidgets('tela inicial: oferece arquivo e texto colado e mostra o formato aceito', (tester) async {
    final h = Harness(tester);
    await h.open();

    expect(find.text('Escolher arquivo'), findsOneWidget);
    expect(find.text('Colar texto'), findsOneWidget);
    expect(find.text('Formato aceito'), findsOneWidget);
    expect(find.textContaining('nome;unidade'), findsWidgets);
  });

  testWidgets('colar texto, analisar e ver o resumo antes de importar', (tester) async {
    final h = Harness(tester);
    await h.open();

    await h.paste('nome;unidade\nArroz;kg\nLeite;L\nSal');

    expect(find.text('3 produtos novos'), findsOneWidget);
    expect(find.text('A primeira linha foi usada como cabeçalho'), findsOneWidget);
    expect(importButton('Importar 3 produtos'), findsOneWidget);
    expect(h.imported, isEmpty); // nada foi gravado ainda
    // A seção "Novos" já vem aberta e mostra nome e unidade.
    expect(find.text('Arroz'), findsOneWidget);
    expect(find.text('kg · quilo'), findsOneWidget);
  });

  testWidgets('arquivo escolhido é lido e analisado', (tester) async {
    final h = Harness(tester);
    await h.open(pickFile: () async => utf8Bytes('Açúcar 🍬\nFeijão'));

    await h.chooseFile();

    expect(find.text('2 produtos novos'), findsOneWidget);
    expect(find.text('Açúcar 🍬'), findsOneWidget);
  });

  testWidgets('cancelar a escolha do arquivo não muda nada nem mostra erro', (tester) async {
    final h = Harness(tester);
    await h.open(pickFile: () async => null);

    await h.chooseFile();

    expect(find.text('Escolher arquivo'), findsOneWidget);
    expect(find.byType(Text).evaluate().where((e) => (e.widget as Text).data?.contains('Não foi possível') ?? false), isEmpty);
  });

  testWidgets('planilha .xlsx: mostra como exportar para CSV', (tester) async {
    final h = Harness(tester);
    await h.open(pickFile: () async => Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0, 1, 2]));

    await h.chooseFile();

    expect(find.textContaining('CSV'), findsWidgets);
    expect(find.text('Escolher arquivo'), findsOneWidget); // continua na tela inicial
  });

  testWidgets('arquivo em Windows-1252 avisa para conferir os acentos', (tester) async {
    final h = Harness(tester);
    // "Açúcar" em Latin-1/Windows-1252.
    await h.open(pickFile: () async => Uint8List.fromList([0x41, 0xE7, 0xFA, 0x63, 0x61, 0x72]));

    await h.chooseFile();

    expect(find.text('Açúcar'), findsOneWidget);
    expect(find.textContaining('Windows-1252'), findsOneWidget);
  });

  testWidgets('acentos corrompidos (UTF-8 lido como ANSI) são consertados e a tela avisa', (tester) async {
    final h = Harness(tester);
    await h.open(pickFile: () async => utf8Bytes(mojibake('nome;unidade\nBrócolis;un\nCafé;pct\nSal;kg')));

    await h.chooseFile();

    expect(find.text('3 produtos novos'), findsOneWidget);
    expect(find.text('Brócolis'), findsOneWidget);
    expect(find.text('Café'), findsOneWidget);
    expect(find.textContaining('2 linhas tinham os acentos corrompidos'), findsOneWidget);
    expect(find.textContaining('BrÃ'), findsNothing);
  });

  testWidgets('arquivo correto não mostra o aviso de acentos corrompidos', (tester) async {
    final h = Harness(tester);
    await h.open();

    await h.paste('Brócolis\nCafé');

    expect(find.textContaining('corrompidos'), findsNothing);
  });

  testWidgets('o que já existe no catálogo é ignorado, e dá para ver qual é', (tester) async {
    final h = Harness(tester);
    await h.open(existing: ['Arroz 🍚']);

    await h.paste('Arroz\nFeijão');

    expect(find.text('1 produto novo'), findsOneWidget);
    expect(find.text('1 já existe no catálogo (ignorados)'), findsOneWidget);
    await tester.tap(find.text('Já existem (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Igual a "Arroz 🍚"'), findsOneWidget);
    expect(importButton('Importar 1 produto'), findsOneWidget);
  });

  testWidgets('quando nada é novo, o botão de importar fica desabilitado', (tester) async {
    final h = Harness(tester);
    await h.open(existing: ['Arroz', 'Leite']);

    await h.paste('Arroz\nLeite');

    expect(find.text('Nada novo para importar'), findsOneWidget);
    final button = tester.widget<FilledButton>(importButton('Importar 0 produtos'));
    expect(button.onPressed, isNull);
  });

  testWidgets('linhas com problema e unidades desconhecidas são sinalizadas', (tester) async {
    final h = Harness(tester);
    await h.open();

    await h.paste('nome;unidade\n;kg\nSardinha;lata\nArroz;kg');

    expect(find.text('2 produtos novos'), findsOneWidget);
    expect(find.text('1 linha com problema (ignoradas)'), findsOneWidget);
    expect(find.text('1 com unidade não reconhecida (entram sem unidade)'), findsOneWidget);
    await tester.tap(find.text('Linhas com problema (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Linha 2: sem nome'), findsOneWidget);
  });

  testWidgets('importar chama a gravação só com os produtos novos e fecha devolvendo a contagem', (tester) async {
    final h = Harness(tester);
    await h.open(existing: ['Sal']);

    await h.paste('nome;unidade\nArroz;kg\nSal;\nLeite;L\nArroz;kg');
    await tester.tap(importButton('Importar 2 produtos'));
    await tester.pumpAndSettle();

    expect(h.imported, [
      [(name: 'Arroz', unit: 'kg'), (name: 'Leite', unit: 'L')],
    ]);
    expect(h.closed, isTrue);
    expect(h.result, 2);
  });

  testWidgets('falha ao gravar: mostra o erro, continua na tela e permite tentar de novo', (tester) async {
    final h = Harness(tester);
    await h.open(onImport: (_) => throw StateError('sem permissão'));

    await h.paste('Arroz');
    await tester.tap(importButton('Importar 1 produto'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Não foi possível importar'), findsOneWidget);
    expect(h.closed, isFalse);
    final button = tester.widget<FilledButton>(importButton('Importar 1 produto'));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('"Voltar" na pré-visualização retorna à escolha da origem', (tester) async {
    final h = Harness(tester);
    await h.open();
    await h.paste('Arroz');

    await tester.tap(find.text('Voltar'));
    await tester.pumpAndSettle();

    expect(find.text('Escolher arquivo'), findsOneWidget);
    expect(h.closed, isFalse);
  });

  testWidgets('texto sem produtos: mensagem clara', (tester) async {
    final h = Harness(tester);
    await h.open();

    await h.paste('  \n\n ');

    expect(find.text('Nenhum produto encontrado.'), findsOneWidget);
  });

  testWidgets('lista grande demais: mostra o limite', (tester) async {
    final h = Harness(tester);
    await h.open();

    await h.paste(List.generate(2005, (i) => 'P$i').join('\n'));

    expect(find.textContaining('mais de 2000 linhas'), findsOneWidget);
  });

  testWidgets('botão de colar da área de transferência preenche o campo', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'Arroz\nFeijão'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final h = Harness(tester);
    await h.open();
    await tester.tap(find.text('Colar texto'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Colar da área de transferência'));
    await tester.pumpAndSettle();

    expect(find.text('Arroz\nFeijão'), findsOneWidget);
  });
}
