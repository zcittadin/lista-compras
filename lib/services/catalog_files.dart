import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Escolhe um arquivo do aparelho (Drive, Downloads, WhatsApp...) e devolve o
/// conteúdo; `null` se o usuário cancelar.
///
/// Não filtramos por extensão no seletor: no Android, vários gerenciadores de
/// arquivos escondem ou desabilitam `.csv` por causa do tipo MIME. Quem lê o
/// conteúdo (`CatalogParser`) recusa o que não for texto.
Future<Uint8List?> pickCatalogFile() async {
  final file = await FilePicker.pickFile(dialogTitle: 'Escolha o arquivo do catálogo');
  if (file == null) return null;
  return file.readAsBytes();
}

/// Abre o "Salvar como" do sistema. Devolve `false` se o usuário cancelar.
Future<bool> saveCatalogFile(Uint8List bytes) async {
  final saved = await FilePicker.saveFile(
    fileName: 'catalogo-produtos.csv',
    bytes: bytes,
    mimeType: 'text/csv',
    dialogTitle: 'Salvar catálogo de produtos',
  );
  return saved != null;
}
