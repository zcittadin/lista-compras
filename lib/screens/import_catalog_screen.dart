import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/measure_unit.dart';
import '../services/catalog_files.dart';
import '../services/catalog_import.dart';

typedef ImportItem = ({String name, String? unit});

/// Importa produtos para o catálogo a partir de um arquivo (CSV ou TXT) ou de
/// texto colado. Sempre mostra uma PRÉ-VISUALIZAÇÃO antes de gravar.
///
/// Devolve (ao fechar) quantos produtos foram importados, ou `null` se o
/// usuário saiu sem importar.
class ImportCatalogScreen extends StatefulWidget {
  const ImportCatalogScreen({
    super.key,
    required this.existingNames,
    required this.onImport,
    this.pickFile = pickCatalogFile,
  });

  /// Nomes que já estão no catálogo (as linhas iguais são ignoradas).
  final List<String> existingNames;

  /// Grava de fato; devolve quantos foram criados.
  final Future<int> Function(List<ImportItem> items) onImport;

  /// Escolhe o arquivo (injetável nos testes).
  final Future<Uint8List?> Function() pickFile;

  @override
  State<ImportCatalogScreen> createState() => _ImportCatalogScreenState();
}

class _ImportCatalogScreenState extends State<ImportCatalogScreen> {
  final _text = TextEditingController();
  bool _pasting = false;
  bool _busy = false;
  String? _error;
  CatalogPreview? _preview;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _analyze(String text, {bool legacyEncoding = false}) {
    try {
      final preview = CatalogParser.parse(
        text,
        existingNames: widget.existingNames,
        legacyEncoding: legacyEncoding,
      );
      setState(() {
        _preview = preview;
        _error = preview.isEmpty ? 'Nenhum produto encontrado.' : null;
        if (preview.isEmpty) _preview = null;
      });
    } on CatalogImportException catch (e) {
      setState(() {
        _preview = null;
        _error = e.message;
      });
    }
  }

  Future<void> _chooseFile() async {
    setState(() => _error = null);
    try {
      final bytes = await widget.pickFile();
      if (bytes == null) return; // cancelou
      final decoded = CatalogParser.decode(bytes);
      _analyze(decoded.text, legacyEncoding: decoded.legacyEncoding);
    } on CatalogImportException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Não foi possível ler o arquivo: $e');
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      setState(() => _error = 'A área de transferência está vazia.');
      return;
    }
    setState(() {
      _text.text = text;
      _error = null;
    });
  }

  Future<void> _import() async {
    final preview = _preview;
    if (preview == null || preview.toImport.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final count = await widget.onImport([
        for (final e in preview.toImport) (name: e.name, unit: e.unit),
      ]);
      if (mounted) Navigator.pop(context, count);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Não foi possível importar: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Importar catálogo')),
      body: preview == null ? _buildInput(context) : _buildPreview(context, preview),
    );
  }

  // -------------------------------------------------------------------
  // 1. Escolher a origem
  // -------------------------------------------------------------------

  Widget _buildInput(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _buildInputForm(context)),
        // Com o texto sendo colado, "Analisar" fica fixo embaixo: com o teclado
        // aberto o botão ainda estaria à vista, sem precisar rolar.
        if (_pasting)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _analyze(_text.text),
                  child: const Text('Analisar'),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildInputForm(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Traga uma lista de produtos de um arquivo ou cole o texto. '
          'Antes de importar, você confere o que vai entrar.',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 16),
        // Ao colar texto, a ajuda sai do caminho para o campo ficar à vista.
        if (!_pasting) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Formato aceito', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  const Text('Um produto por linha, com a unidade (opcional) depois de ponto e vírgula:'),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Text('nome;unidade\nArroz;kg\nLeite;L\nSal', style: TextStyle(fontFamily: 'monospace')),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Serve CSV de Excel ou Planilhas Google (salve como CSV) e TXT com um nome por linha. '
                    'Unidades: ${MeasureUnit.values.map((u) => u.symbol).join(', ')}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        FilledButton.icon(
          icon: const Icon(Icons.upload_file),
          label: const Text('Escolher arquivo'),
          onPressed: _chooseFile,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.content_paste),
          label: const Text('Colar texto'),
          onPressed: () => setState(() => _pasting = !_pasting),
        ),
        if (_pasting) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: 5,
            maxLines: 10,
            decoration: InputDecoration(
              hintText: 'Cole aqui a lista de produtos',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Colar da área de transferência',
                icon: const Icon(Icons.paste),
                onPressed: _pasteFromClipboard,
              ),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  // -------------------------------------------------------------------
  // 2. Pré-visualização
  // -------------------------------------------------------------------

  Widget _buildPreview(BuildContext context, CatalogPreview preview) {
    final theme = Theme.of(context);
    final fresh = preview.toImport;

    String plural(int n, String one, String many) => n == 1 ? one : many;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                fresh.isEmpty
                    ? 'Nada novo para importar'
                    : '${fresh.length} ${plural(fresh.length, 'produto novo', 'produtos novos')}',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              if (preview.alreadyExist.isNotEmpty)
                _note(Icons.check_circle_outline,
                    '${preview.alreadyExist.length} já ${plural(preview.alreadyExist.length, 'existe', 'existem')} no catálogo (ignorados)'),
              if (preview.duplicatesInFile.isNotEmpty)
                _note(Icons.content_copy,
                    '${preview.duplicatesInFile.length} ${plural(preview.duplicatesInFile.length, 'repetido', 'repetidos')} no próprio arquivo (ignorados)'),
              if (preview.invalid.isNotEmpty)
                _note(Icons.error_outline,
                    '${preview.invalid.length} ${plural(preview.invalid.length, 'linha com problema', 'linhas com problema')} (ignoradas)',
                    color: theme.colorScheme.error),
              if (preview.unknownUnits.isNotEmpty)
                _note(Icons.help_outline,
                    '${preview.unknownUnits.length} com unidade não reconhecida (entram sem unidade)'),
              if (preview.hadHeader) _note(Icons.table_rows_outlined, 'A primeira linha foi usada como cabeçalho'),
              if (preview.repairedLines > 0)
                _note(
                  Icons.build_circle_outlined,
                  '${preview.repairedLines} ${plural(preview.repairedLines, 'linha tinha', 'linhas tinham')} os acentos '
                  'corrompidos (UTF-8 lido como ANSI) e ${plural(preview.repairedLines, 'foi corrigida', 'foram corrigidas')} '
                  'automaticamente. Confira a lista.',
                ),
              if (preview.legacyEncoding)
                _note(
                  Icons.warning_amber,
                  'O arquivo não estava em UTF-8 e foi lido como Windows-1252. Confira se os acentos estão certos.',
                  color: theme.colorScheme.error,
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 8),
              _section('Novos', fresh, initiallyExpanded: true, builder: (e) => _unitSubtitle(e)),
              _section('Já existem', preview.alreadyExist, builder: (e) => 'Igual a "${e.existingName}"'),
              _section('Repetidos no arquivo', preview.duplicatesInFile, builder: (e) => 'Repete "${e.existingName}"'),
              _section('Linhas com problema', preview.invalid, builder: _problem, showName: false),
              _section('Unidade não reconhecida', preview.unknownUnits,
                  builder: (e) => 'Unidade "${e.ignoredUnit}" ignorada'),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _preview = null),
                  child: const Text('Voltar'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: fresh.isEmpty || _busy ? null : _import,
                  child: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('Importar ${fresh.length} ${plural(fresh.length, 'produto', 'produtos')}'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String? _unitSubtitle(ImportEntry e) {
    final unit = e.unit == null ? null : MeasureUnit.parse(e.unit);
    return unit == null ? null : '${unit.symbol} · ${unit.label}';
  }

  String _problem(ImportEntry e) => switch (e.status) {
        EntryStatus.nameEmpty => 'Linha ${e.line}: sem nome',
        EntryStatus.nameTooLong => 'Linha ${e.line}: nome com mais de ${CatalogParser.maxNameLength} caracteres',
        _ => 'Linha ${e.line}',
      };

  Widget _note(IconData icon, String text, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(color: color))),
          ],
        ),
      );

  Widget _section(
    String title,
    List<ImportEntry> entries, {
    required String? Function(ImportEntry) builder,
    bool initiallyExpanded = false,
    bool showName = true,
  }) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      initiallyExpanded: initiallyExpanded,
      tilePadding: EdgeInsets.zero,
      title: Text('$title (${entries.length})'),
      children: [
        for (final e in entries)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8),
            title: Text(showName ? e.name : builder(e) ?? ''),
            subtitle: showName && builder(e) != null ? Text(builder(e)!) : null,
          ),
      ],
    );
  }
}
