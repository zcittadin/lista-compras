import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/services/realtime_keeper.dart';

/// Relógio falso: guarda os timers pedidos para o teste disparar à mão.
class FakeTimers {
  final pending = <(Duration, void Function(), _FakeTimer)>[];

  Timer create(Duration d, void Function() f) {
    final t = _FakeTimer();
    pending.add((d, f, t));
    return t;
  }

  List<Duration> get delays => [for (final p in pending) if (p.$3.isActive) p.$1];

  /// Dispara o próximo timer ativo.
  void fireNext() {
    final next = pending.firstWhere((p) => p.$3.isActive);
    next.$3.isActive = false;
    next.$2();
  }
}

class _FakeTimer implements Timer {
  @override
  bool isActive = true;

  @override
  void cancel() => isActive = false;

  @override
  int get tick => 0;
}

void main() {
  late FakeTimers timers;
  late List<String> calls;
  late RealtimeKeeper keeper;

  setUp(() {
    timers = FakeTimers();
    calls = [];
    keeper = RealtimeKeeper(
      connect: () => calls.add('connect'),
      disconnect: () => calls.add('disconnect'),
      onRecovered: () => calls.add('recovered'),
      timer: timers.create,
    );
  });

  test('start conecta uma vez (e de novo não faz nada)', () {
    keeper.start();
    keeper.start();
    expect(calls, ['connect']);
  });

  test('a primeira inscrição não dispara "recuperado" (quem iniciou já busca tudo)', () {
    keeper.start();
    keeper.reportSubscribed();
    expect(keeper.healthy, isTrue);
    expect(calls, ['connect']);
  });

  test('falhou: tenta de novo com espera crescente, até o teto', () {
    keeper.start();
    final seen = <Duration>[];
    for (var i = 0; i < 7; i++) {
      keeper.reportFailed();
      seen.add(timers.delays.single);
      timers.fireNext();
    }
    expect(seen, [
      const Duration(seconds: 2),
      const Duration(seconds: 5),
      const Duration(seconds: 15),
      const Duration(seconds: 30),
      const Duration(seconds: 60),
      const Duration(seconds: 60), // teto
      const Duration(seconds: 60),
    ]);
    // Cada tentativa desfaz o canal quebrado e cria outro.
    expect(calls.where((c) => c == 'connect'), hasLength(8));
    expect(calls.where((c) => c == 'disconnect'), hasLength(7));
  });

  test('falhas repetidas antes da tentativa não empilham timers', () {
    keeper.start();
    keeper.reportFailed();
    keeper.reportFailed();
    keeper.reportFailed();
    expect(timers.delays, hasLength(1));
  });

  test('voltou depois de uma queda: busca o que se perdeu e zera a espera', () {
    keeper.start();
    keeper.reportSubscribed();
    keeper.reportFailed();
    keeper.reportFailed(); // ainda a mesma tentativa pendente
    timers.fireNext();
    keeper.reportSubscribed();

    expect(calls.last, 'recovered');
    expect(keeper.healthy, isTrue);

    keeper.reportFailed();
    expect(timers.delays.single, const Duration(seconds: 2)); // recomeçou do início
  });

  test('o caso real: token vencido na abertura e sessão renovada depois', () {
    keeper.start(); // conecta com o token velho
    keeper.reportFailed(); // "InvalidJWTToken"
    expect(timers.delays, [const Duration(seconds: 2)]);

    keeper.sessionRefreshed(); // o Supabase renovou o token

    // Refaz já, sem esperar a tentativa marcada, que é cancelada.
    expect(calls, ['connect', 'disconnect', 'connect']);
    expect(timers.delays, isEmpty);
    keeper.reportSubscribed();
    expect(keeper.healthy, isTrue);
  });

  test('sessão renovada com o canal saudável não mexe em nada', () {
    keeper.start();
    keeper.reportSubscribed();
    keeper.sessionRefreshed();
    expect(calls, ['connect']);
  });

  test('stop cancela a tentativa pendente e ignora avisos atrasados', () {
    keeper.start();
    keeper.reportFailed();
    keeper.stop();

    expect(timers.delays, isEmpty);
    expect(calls.last, 'disconnect');
    keeper.reportFailed();
    keeper.reportSubscribed();
    keeper.sessionRefreshed();
    expect(timers.delays, isEmpty);
    expect(calls, ['connect', 'disconnect']);
  });

  test('depois de stop, start recomeça (sair e entrar de novo na conta)', () {
    keeper.start();
    keeper.stop();
    keeper.start();
    expect(calls, ['connect', 'disconnect', 'connect']);
  });
}
