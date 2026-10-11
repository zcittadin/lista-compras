import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/member.dart';

/// Compartilhamento de listas: quem participa, convidar, remover e sair.
class MembersService {
  MembersService._();
  static final instance = MembersService._();

  SupabaseClient get _supabase => Supabase.instance.client;

  /// Membros da lista em tempo real (dono primeiro, depois por nome).
  ///
  /// `list_members` só tem os IDs; nome e e-mail vêm da tabela `profiles`.
  /// A RLS de `profiles` deixa ver o perfil de quem divide uma lista com você.
  Stream<List<Member>> watchMembers(String listId) {
    return _supabase
        .from('list_members')
        .stream(primaryKey: ['list_id', 'user_id'])
        .eq('list_id', listId)
        .asyncMap((rows) async {
          if (rows.isEmpty) return <Member>[];
          final roles = {
            for (final r in rows) r['user_id'] as String: r['role'] as String,
          };
          final profiles = await _supabase
              .from('profiles')
              .select('id, email, full_name')
              .inFilter('id', roles.keys.toList());
          final members = [
            for (final p in profiles)
              Member(
                userId: p['id'] as String,
                isOwner: roles[p['id']] == 'owner',
                email: p['email'] as String,
                fullName: p['full_name'] as String?,
              ),
          ]..sort((a, b) {
              if (a.isOwner != b.isOwner) return a.isOwner ? -1 : 1;
              return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
            });
          return members;
        });
  }

  /// Convida pelo e-mail chamando a função SQL `share_list` (RPC).
  ///
  /// A função confere no servidor se quem chama é o dono e se o e-mail
  /// pertence a alguém que já entrou no app. Os erros dela chegam aqui
  /// como `PostgrestException` com a mensagem escrita no SQL.
  Future<void> share(String listId, String email) {
    return _supabase.rpc('share_list', params: {
      'p_list_id': listId,
      'p_email': email.trim(),
    });
  }

  /// O dono remove um membro, ou o próprio membro sai: é o mesmo DELETE.
  /// A RLS decide quem pode (e nunca deixa remover o dono).
  Future<void> remove(String listId, String userId) {
    return _supabase
        .from('list_members')
        .delete()
        .eq('list_id', listId)
        .eq('user_id', userId);
  }
}
