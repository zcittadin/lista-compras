import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/member.dart';
import '../models/shopping_list.dart';
import '../services/auth_service.dart';
import '../services/members_service.dart';

/// Quem participa da lista. O dono convida e remove; os demais podem sair.
class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key, required this.list});

  final ShoppingList list;

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  late final _members = MembersService.instance.watchMembers(widget.list.id);
  final _email = TextEditingController();
  bool _inviting = false;

  String? get _userId => AuthService.instance.currentUser?.id;
  bool get _isOwner => widget.list.ownerId == _userId;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _errorText(Object e) => e is PostgrestException ? e.message : '$e';

  Future<void> _invite() async {
    final email = _email.text.trim();
    if (email.isEmpty || _inviting) return;
    setState(() => _inviting = true);
    try {
      await MembersService.instance.share(widget.list.id, email);
      _email.clear();
      if (mounted) _toast('$email agora participa da lista.');
    } catch (e) {
      if (mounted) _toast(_errorText(e));
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _removeMember(Member m) async {
    if (!await _confirm(
      'Remover ${m.displayName}?',
      'A pessoa deixa de ver esta lista.',
      'Remover',
    )) {
      return;
    }
    try {
      await MembersService.instance.remove(widget.list.id, m.userId);
    } catch (e) {
      if (mounted) _toast(_errorText(e));
    }
  }

  Future<void> _leave() async {
    if (!await _confirm(
      'Sair da lista?',
      '"${widget.list.name}" deixa de aparecer para você. O dono pode convidar de novo.',
      'Sair',
    )) {
      return;
    }
    try {
      await MembersService.instance.remove(widget.list.id, _userId!);
      // Volta até a tela inicial: a lista não é mais acessível.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) _toast(_errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Participantes')),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Member>>(
              stream: _members,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Erro ao carregar: ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return ListView(
                  children: [
                    for (final m in snapshot.data!)
                      ListTile(
                        leading: CircleAvatar(
                          child: Text(m.displayName.characters.first.toUpperCase()),
                        ),
                        title: Text(m.displayName),
                        subtitle: Text(m.isOwner ? '${m.email} · Dono' : m.email),
                        trailing: _isOwner && !m.isOwner
                            ? IconButton(
                                tooltip: 'Remover',
                                icon: const Icon(Icons.person_remove),
                                onPressed: () => _removeMember(m),
                              )
                            : null,
                      ),
                  ],
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: _isOwner
                  ? Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.send,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              hintText: 'E-mail da conta Google',
                            ),
                            onSubmitted: (_) => _invite(),
                          ),
                        ),
                        IconButton.filled(
                          tooltip: 'Convidar',
                          icon: const Icon(Icons.person_add),
                          onPressed: _inviting ? null : _invite,
                        ),
                      ],
                    )
                  : SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.exit_to_app),
                        label: const Text('Sair da lista'),
                        onPressed: _leave,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
