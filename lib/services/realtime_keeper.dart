import 'dart:async';

/// Mantém o canal de tempo real (Realtime) vivo.
///
/// O canal pode cair ou nem chegar a conectar. O caso real (2026-10-18): o app
/// abriu com a sessão vencida, o canal entrou com o token expirado, o servidor
/// recusou ("InvalidJWTToken"), e ninguém o refez depois de o token ser
/// renovado. Os avisos "algo mudou" pararam de chegar até o usuário sair e
/// entrar de novo na conta.
///
/// Regras:
/// * falhou → tenta de novo, esperando cada vez mais ([delays]);
/// * a sessão foi renovada e o canal está quebrado → refaz na hora;
/// * voltou depois de uma queda → [onRecovered] (para buscar o que se perdeu).
///
/// Conectar e desconectar de fato ficam com quem usa a classe, e o relógio é
/// injetável, o que permite testar tudo sem servidor.
class RealtimeKeeper {
  RealtimeKeeper({
    required this.connect,
    required this.disconnect,
    required this.onRecovered,
    this.delays = defaultDelays,
    Timer Function(Duration, void Function())? timer,
  }) : _timer = timer ?? Timer.new;

  static const defaultDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// Cria o canal e se inscreve. O resultado chega por [reportSubscribed] ou
  /// [reportFailed].
  final void Function() connect;
  final void Function() disconnect;
  final void Function() onRecovered;

  /// Esperas entre tentativas; depois da última, repete a última.
  final List<Duration> delays;
  final Timer Function(Duration, void Function()) _timer;

  Timer? _retry;
  int _attempts = 0;
  bool _running = false;
  bool _healthy = false;
  bool _everSubscribed = false;

  /// O canal está inscrito e recebendo avisos.
  bool get healthy => _healthy;

  void start() {
    if (_running) return;
    _running = true;
    connect();
  }

  void stop() {
    _running = false;
    _healthy = false;
    _retry?.cancel();
    _retry = null;
    disconnect();
  }

  /// O canal confirmou a inscrição.
  void reportSubscribed() {
    if (!_running) return;
    _retry?.cancel();
    _retry = null;
    _attempts = 0;
    _healthy = true;
    // Na primeira vez, quem iniciou já busca tudo; depois de uma queda, pode
    // ter havido mudanças que não foram avisadas.
    if (_everSubscribed) onRecovered();
    _everSubscribed = true;
  }

  /// O canal falhou (erro ou tempo esgotado): agenda uma nova tentativa.
  void reportFailed() {
    if (!_running) return;
    _healthy = false;
    if (_retry != null) return; // já há uma tentativa marcada
    final delay = delays[_attempts < delays.length ? _attempts : delays.length - 1];
    _attempts++;
    _retry = _timer(delay, () {
      _retry = null;
      _reconnect();
    });
  }

  /// A sessão foi renovada (token novo). Se o canal está quebrado, refaz já:
  /// não adianta esperar a próxima tentativa com o token velho.
  void sessionRefreshed() {
    if (!_running || _healthy) return;
    _retry?.cancel();
    _retry = null;
    _reconnect();
  }

  void _reconnect() {
    if (!_running) return;
    disconnect();
    connect();
  }
}
