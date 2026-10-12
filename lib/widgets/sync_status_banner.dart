import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../screens/sync_issues_screen.dart';
import '../services/sync_service.dart';

/// Faixa no topo das telas com o estado da sincronização:
///
/// - mudanças que o servidor recusou (sempre aparece, com acesso à tela de problemas);
/// - sem conexão (com quantas mudanças aguardam envio);
/// - mudanças pendentes há mais de alguns segundos mesmo com conexão.
///
/// Em condições normais não aparece. O "pendente com conexão" só surge depois
/// de [stuckAfter] para não piscar a cada alteração (o envio leva menos de 1 s).
class SyncStatusBanner extends StatefulWidget {
  const SyncStatusBanner({
    super.key,
    this.pendingCount,
    this.failedCount,
    this.online,
    this.stuckAfter = const Duration(seconds: 4),
  });

  /// Para testes; por padrão usa a fila do banco e o estado de conexão do app.
  final Stream<int>? pendingCount;
  final Stream<int>? failedCount;
  final ValueListenable<bool>? online;
  final Duration stuckAfter;

  @override
  State<SyncStatusBanner> createState() => _SyncStatusBannerState();
}

class _SyncStatusBannerState extends State<SyncStatusBanner> {
  late final ValueListenable<bool> _online = widget.online ?? SyncService.instance.online;

  final _subscriptions = <StreamSubscription<int>>[];
  Timer? _stuckTimer;
  int _pending = 0;
  int _failed = 0;
  bool _stuck = false;

  @override
  void initState() {
    super.initState();
    final pending = widget.pendingCount ?? AppDatabase.instance.watchPendingCount();
    final failed = widget.failedCount ?? AppDatabase.instance.watchFailedCount();
    _subscriptions.add(pending.listen(_onPending));
    _subscriptions.add(failed.listen((n) => setState(() => _failed = n)));
    _online.addListener(_rebuild);
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _stuckTimer?.cancel();
    _online.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  void _onPending(int count) {
    setState(() => _pending = count);
    if (count == 0) {
      _stuckTimer?.cancel();
      _stuckTimer = null;
      if (_stuck) setState(() => _stuck = false);
    } else {
      _stuckTimer ??= Timer(widget.stuckAfter, () {
        if (mounted) setState(() => _stuck = true);
      });
    }
  }

  static String _changes(int n) => n == 1 ? '1 alteração' : '$n alterações';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_failed > 0) {
      return _Bar(
        color: scheme.errorContainer,
        onColor: scheme.onErrorContainer,
        icon: Icons.error_outline,
        text: '${_changes(_failed)} não ${_failed == 1 ? 'pôde' : 'puderam'} ser '
            '${_failed == 1 ? 'enviada' : 'enviadas'}',
        action: 'Ver',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SyncIssuesScreen()),
        ),
      );
    }

    if (!_online.value) {
      return _Bar(
        color: scheme.secondaryContainer,
        onColor: scheme.onSecondaryContainer,
        icon: Icons.cloud_off,
        text: _pending > 0
            ? 'Sem conexão · ${_changes(_pending)} aguardando envio'
            : 'Sem conexão · as alterações ficam salvas neste aparelho',
      );
    }

    if (_pending > 0 && _stuck) {
      return _Bar(
        color: scheme.secondaryContainer,
        onColor: scheme.onSecondaryContainer,
        icon: Icons.sync,
        text: '${_changes(_pending)} aguardando envio',
      );
    }

    return const SizedBox.shrink();
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.color,
    required this.onColor,
    required this.icon,
    required this.text,
    this.action,
    this.onTap,
  });

  final Color color;
  final Color onColor;
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: onColor),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: TextStyle(color: onColor))),
              if (action != null)
                Text(action!, style: TextStyle(color: onColor, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}
