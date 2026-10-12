import 'package:url_launcher/url_launcher.dart';

/// Texto do aviso enviado pelo WhatsApp depois de compartilhar uma lista.
String shareNoticeText(String listName) =>
    'Oi! Compartilhei a lista "$listName" com você no app Lista de Compras. '
    'Abra o app para ver 🛒';

/// Link `wa.me` que abre o WhatsApp com [text] pronto; a pessoa escolhe para
/// quem mandar. Não precisa de número de telefone nem de servidor.
Uri whatsAppUri(String text) => Uri.https('wa.me', '/', {'text': text});

/// Abre o WhatsApp (ou, se não estiver instalado, o WhatsApp Web no navegador).
/// Devolve `false` se nada conseguiu abrir o link.
Future<bool> openWhatsApp(String text) =>
    launchUrl(whatsAppUri(text), mode: LaunchMode.externalApplication);
