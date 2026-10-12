import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/widgets/sync_status_banner.dart';

/// A faixa recebe os contadores como streams, então o teste os controla
/// diretamente (sem banco).
class _Harness {
  _Harness(this.tester);

  final WidgetTester tester;
  final pending = StreamController<int>();
  final failed = StreamController<int>();
  final online = ValueNotifier<bool>(true);

  Future<void> create({Duration stuckAfter = const Duration(seconds: 4)}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SyncStatusBanner(
                pendingCount: pending.stream,
                failedCount: failed.stream,
                online: online,
                stuckAfter: stuckAfter,
              ),
            ],
          ),
        ),
      ),
    );
    pending.add(0);
    failed.add(0);
    await _flush();
  }

  /// O stream entrega o evento numa microtarefa e a tela redesenha no frame
  /// seguinte: por isso dois `pump`.
  Future<void> _flush() async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> setPending(int n) async {
    pending.add(n);
    await _flush();
  }

  Future<void> setFailed(int n) async {
    failed.add(n);
    await _flush();
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox());
    unawaited(pending.close());
    unawaited(failed.close());
  }
}

void main() {
  testWidgets('em condições normais não aparece nada', (tester) async {
    final h = _Harness(tester);
    await h.create();
    expect(find.byType(Text), findsNothing);
    await h.dispose();
  });

  testWidgets('sem conexão e sem pendências: avisa que fica salvo no aparelho', (tester) async {
    final h = _Harness(tester);
    await h.create();
    h.online.value = false;
    await tester.pump();

    expect(find.textContaining('Sem conexão'), findsOneWidget);
    expect(find.textContaining('salvas neste aparelho'), findsOneWidget);
    await h.dispose();
  });

  testWidgets('sem conexão com pendências: mostra quantas aguardam envio', (tester) async {
    final h = _Harness(tester);
    await h.create();
    h.online.value = false;
    await h.setPending(2);

    expect(find.text('Sem conexão · 2 alterações aguardando envio'), findsOneWidget);
    await h.dispose();
  });

  testWidgets('singular: 1 alteração', (tester) async {
    final h = _Harness(tester);
    await h.create();
    h.online.value = false;
    await h.setPending(1);

    expect(find.text('Sem conexão · 1 alteração aguardando envio'), findsOneWidget);
    await h.dispose();
  });

  testWidgets('com conexão, uma pendência rápida não pisca na tela', (tester) async {
    final h = _Harness(tester);
    await h.create();
    await h.setPending(1);
    expect(find.byType(Text), findsNothing);

    // O envio termina antes do prazo: a faixa nunca aparece.
    await h.setPending(0);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(Text), findsNothing);
    await h.dispose();
  });

  testWidgets('com conexão, pendência que demora aparece depois do prazo e some ao enviar', (tester) async {
    final h = _Harness(tester);
    await h.create(stuckAfter: const Duration(seconds: 2));
    await h.setPending(3);
    expect(find.byType(Text), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('3 alterações aguardando envio'), findsOneWidget);

    await h.setPending(0);
    expect(find.byType(Text), findsNothing);
    await h.dispose();
  });

  testWidgets('um novo ciclo de pendência volta a esperar o prazo', (tester) async {
    final h = _Harness(tester);
    await h.create(stuckAfter: const Duration(seconds: 2));
    await h.setPending(1);
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('aguardando envio'), findsOneWidget);

    await h.setPending(0);
    await h.setPending(1); // outra alteração logo depois
    expect(find.byType(Text), findsNothing);
    await h.dispose();
  });

  testWidgets('falha do servidor: mostra o link "Ver" e tem prioridade sobre o offline', (tester) async {
    final h = _Harness(tester);
    await h.create();
    h.online.value = false;
    await h.setFailed(1);

    expect(find.text('1 alteração não pôde ser enviada'), findsOneWidget);
    expect(find.text('Ver'), findsOneWidget);
    expect(find.textContaining('Sem conexão'), findsNothing);
    await h.dispose();
  });

  testWidgets('várias falhas usam o plural', (tester) async {
    final h = _Harness(tester);
    await h.create();
    await h.setFailed(3);

    expect(find.text('3 alterações não puderam ser enviadas'), findsOneWidget);
    await h.dispose();
  });
}
