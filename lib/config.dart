/// Chaves de configuração lidas em tempo de compilação.
///
/// Rode o app com:
///   flutter run --dart-define-from-file=config.json
///
/// Copie `config.example.json` para `config.json` e preencha com os valores
/// do seu projeto Supabase e do Google Cloud. O `config.json` não vai para o Git.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// ID de cliente OAuth do tipo "Aplicativo da Web" no Google Cloud.
  /// É ele que o Supabase usa para validar o login.
  static const googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  /// ID de cliente OAuth do tipo "iOS". Só é necessário no iPhone.
  static const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty && googleWebClientId.isNotEmpty;
}
