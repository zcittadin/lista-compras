import 'dart:io' show Platform;

import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';

/// Login com a conta Google, usando o fluxo nativo do celular.
///
/// O Google devolve um "ID token" que o Supabase valida e troca por uma
/// sessão própria. A partir daí, todas as consultas ao banco carregam a
/// identidade do usuário, e as regras de segurança (RLS) usam `auth.uid()`.
class AuthService {
  AuthService._();
  static final instance = AuthService._();

  final _google = GoogleSignIn.instance;
  bool _initialized = false;

  SupabaseClient get _supabase => Supabase.instance.client;

  Stream<AuthState> get authStateChanges => _supabase.auth.onAuthStateChange;

  User? get currentUser => _supabase.auth.currentUser;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _google.initialize(
      clientId: Platform.isIOS && AppConfig.googleIosClientId.isNotEmpty
          ? AppConfig.googleIosClientId
          : null,
      serverClientId: AppConfig.googleWebClientId,
    );
    _initialized = true;
  }

  Future<void> signInWithGoogle() async {
    await _ensureInitialized();

    final account = await _google.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('O Google não devolveu um token de identidade.');
    }

    await _supabase.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
  }

  Future<void> signOut() async {
    await _ensureInitialized();
    await _google.signOut();
    await _supabase.auth.signOut();
  }
}
