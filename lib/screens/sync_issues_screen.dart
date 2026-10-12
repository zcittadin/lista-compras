import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../services/sync_service.dart';

/// Explica, em português, por que o servidor recusou uma mudança.
String explainFailure(String? lastError) {
  final error = lastError ?? '';
  if (error.contains('42501') || error.contains('não existe no servidor')) {
    return 'Você não tem permissão para isto, ou perdeu o acesso à lista.';
  }
  if (error.contains('23503')) {
    return 'A lista ou o item a que isto pertence não existe mais no servidor.';
  }
  if (error.contains('23505')) {
    return 'Já existe algo igual no servidor.';
  }
  return 'O servidor recusou esta alteração.';
}

/// Mudanças que o servidor recusou. Para cada uma: tentar de novo ou descartar.
class SyncIssuesScreen extends StatefulWidget {
  const SyncIssuesScreen({super.key});

  @override
  State<SyncIssuesScreen> createState() => _SyncIssuesScreenState();
}

class _SyncIssuesScreenState extends State<SyncIssuesScreen> {
  final _sync = SyncService.instance;

  late final Stream<List<({OutboxEntry entry, String description})>> _issues =
      AppDatabase.instance.watchFailedEntries().asyncMap(
            (entries) async => [
              for (final e in entries) (entry: e, description: await _sync.describe(e)),
            ],
          );

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _retry(OutboxEntry entry) async {
    try {
      await _sync.retryFailed(entry);
    } catch (e) {
      if (mounted) _toast('Não foi possível tentar agora: $e');
    }
  }

  Future<void> _discard(OutboxEntry entry, String description) async {
    final isInsert = entry.op == 'insert';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Descartar esta alteração?'),
        content: Text(
          isInsert
              ? '$description será apagada deste aparelho, pois nunca chegou ao servidor.'
              : '$description será desfeita: volta a versão que está no servidor.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Descartar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _sync.discardFailed(entry);
    } catch (_) {
      if (mounted) {
        _toast('Sem conexão com o servidor. Descartar uma alteração exige internet.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alterações não enviadas')),
      body: StreamBuilder<List<({OutboxEntry entry, String description})>>(
        stream: _issues,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final issues = snapshot.data!;
          if (issues.isEmpty) {
            return const Center(child: Text('Nenhum problema. Tudo foi enviado.'));
          }
          return ListView.separated(
            itemCount: issues.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final (:entry, :description) = issues[i];
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(description, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(explainFailure(entry.lastError)),
                    if (entry.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          entry.lastError!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => _discard(entry, description),
                          child: const Text('Descartar'),
                        ),
                        FilledButton.tonal(
                          onPressed: () => _retry(entry),
                          child: const Text('Tentar de novo'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
