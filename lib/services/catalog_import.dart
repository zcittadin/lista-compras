import 'dart:convert';
import 'dart:typed_data';

import '../models/measure_unit.dart';
import '../utils/text.dart';

/// Interpreta um arquivo (ou texto colado) com produtos para o catálogo e
/// monta uma PRÉ-VISUALIZAÇÃO. Nada aqui grava no banco: quem importa decide
/// depois de o usuário conferir o resultado.
///
/// Formatos aceitos (todos reduzem a "um produto por linha, com unidade opcional"):
///
/// * `.txt` com um nome por linha;
/// * CSV com colunas `nome` e `unidade`, com ou sem cabeçalho, separado por
///   `;`, vírgula ou tab (o Excel em português usa `;`).
///
/// O arquivo é entrada não confiável: o tamanho é limitado, caracteres de
/// controle são removidos e os limites do banco (nome de até 120 caracteres)
/// são conferidos linha a linha.

/// O arquivo ou texto não pode ser lido (grande demais, vazio...). A mensagem
/// já é para o usuário.
class CatalogImportException implements Exception {
  const CatalogImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// O que acontece com cada linha ao importar.
enum EntryStatus {
  /// Produto novo: será importado.
  fresh,

  /// Já existe no catálogo (mesmo nome, ignorando maiúsculas e emojis): ignorado.
  alreadyExists,

  /// Repete uma linha anterior do próprio arquivo: ignorado.
  duplicateInFile,

  /// A linha não tem nome.
  nameEmpty,

  /// Nome acima do limite do banco.
  nameTooLong,
}

class ImportEntry {
  const ImportEntry({
    required this.line,
    required this.name,
    required this.status,
    this.unit,
    this.ignoredUnit,
    this.existingName,
  });

  /// Número da linha no arquivo (começa em 1; conta o cabeçalho).
  final int line;

  /// Nome já limpo (espaços e caracteres de controle).
  final String name;
  final EntryStatus status;

  /// Símbolo da unidade reconhecida (`kg`, `L`...), ou `null`.
  final String? unit;

  /// Texto da unidade que não foi reconhecida (a linha é importada sem unidade).
  final String? ignoredUnit;

  /// Para [EntryStatus.alreadyExists] e [EntryStatus.duplicateInFile]: o nome
  /// que já existe (pode diferir só por maiúsculas ou emojis).
  final String? existingName;
}

class CatalogPreview {
  const CatalogPreview({
    required this.entries,
    required this.hadHeader,
    required this.delimiter,
    required this.legacyEncoding,
    this.repairedLines = 0,
  });

  final List<ImportEntry> entries;

  /// A primeira linha era um cabeçalho (`nome;unidade`) e foi descartada.
  final bool hadHeader;

  /// Separador de colunas detectado (`;`, `,` ou tab); `null` se for uma lista simples.
  final String? delimiter;

  /// O arquivo não era UTF-8 e foi lido como Windows-1252 (o "ANSI" do Excel).
  final bool legacyEncoding;

  /// Quantas linhas tinham os acentos corrompidos (UTF-8 lido como ANSI e
  /// regravado, "CafÃ©") e foram consertadas automaticamente.
  final int repairedLines;

  List<ImportEntry> _with(EntryStatus s) => entries.where((e) => e.status == s).toList();

  /// Os produtos que serão importados.
  List<ImportEntry> get toImport => _with(EntryStatus.fresh);
  List<ImportEntry> get alreadyExist => _with(EntryStatus.alreadyExists);
  List<ImportEntry> get duplicatesInFile => _with(EntryStatus.duplicateInFile);
  List<ImportEntry> get invalid => entries
      .where((e) => e.status == EntryStatus.nameEmpty || e.status == EntryStatus.nameTooLong)
      .toList();

  /// Linhas importadas cuja unidade não foi reconhecida.
  List<ImportEntry> get unknownUnits =>
      toImport.where((e) => e.ignoredUnit != null).toList();

  bool get isEmpty => entries.isEmpty;
}

class CatalogParser {
  const CatalogParser._();

  /// Tamanho máximo do arquivo (1 MiB já comporta dezenas de milhares de linhas;
  /// acima disso não é uma lista de produtos).
  static const maxBytes = 1 << 20;

  /// Máximo de linhas com conteúdo.
  static const maxRows = 2000;

  /// Limite de `products.name` no banco.
  static const maxNameLength = 120;

  static const _nameHeaders = {'nome', 'produto', 'name', 'item', 'descricao'};
  static const _unitHeaders = {'unidade', 'un', 'unit', 'medida', 'und'};

  // -------------------------------------------------------------------
  // Leitura de bytes
  // -------------------------------------------------------------------

  /// Converte os bytes de um arquivo em texto. Tenta UTF-8 (com ou sem BOM);
  /// se não for válido, lê como Windows-1252, que é como o Excel em português
  /// salva "CSV" por padrão. Também entende UTF-16 (o "Texto Unicode" do Excel).
  static ({String text, bool legacyEncoding}) decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const CatalogImportException(
        'O arquivo é grande demais para ser uma lista de produtos (limite de 1 MB).',
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return (text: _utf16(bytes, 2, littleEndian: true), legacyEncoding: false);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return (text: _utf16(bytes, 2, littleEndian: false), legacyEncoding: false);
    }
    _rejectBinary(bytes);
    final start = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
    final body = start == 0 ? bytes : Uint8List.sublistView(bytes, start);
    try {
      return (text: utf8.decode(body), legacyEncoding: false);
    } on FormatException {
      return (text: _windows1252(body), legacyEncoding: true);
    }
  }

  /// Recusa o que claramente não é texto: planilha do Excel (.xlsx/.xls),
  /// documento do Word, PDF ou qualquer arquivo binário. A mensagem diz o que
  /// fazer, porque é o erro mais provável de quem tem a lista numa planilha.
  static void _rejectBinary(Uint8List bytes) {
    bool starts(List<int> signature) =>
        bytes.length >= signature.length &&
        [for (var i = 0; i < signature.length; i++) bytes[i] == signature[i]].every((same) => same);

    final isOffice = starts([0x50, 0x4B, 0x03, 0x04]) || starts([0xD0, 0xCF, 0x11, 0xE0]); // zip (xlsx/docx) ou xls/doc
    if (isOffice) {
      throw const CatalogImportException(
        'Este arquivo é uma planilha ou documento do Office, que o app não lê. '
        'No Excel ou Planilhas Google, use "Salvar como" / "Fazer download" em CSV e escolha o arquivo .csv.',
      );
    }
    if (starts([0x25, 0x50, 0x44, 0x46])) {
      throw const CatalogImportException('Este arquivo é um PDF. Escolha um arquivo de texto (.txt) ou CSV (.csv).');
    }
    // Texto não tem byte zero (UTF-16 já foi tratado antes, pelo BOM).
    if (bytes.contains(0)) {
      throw const CatalogImportException('Este arquivo não parece ser de texto. Escolha um arquivo .txt ou .csv.');
    }
  }

  static String _utf16(Uint8List bytes, int start, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  /// Windows-1252 = Latin-1 exceto 0x80–0x9F, que tem pontuação tipográfica.
  static const _cp1252 = <int, int>{
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020,
    0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152,
    0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022,
    0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
    0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
  };

  static String _windows1252(Uint8List bytes) =>
      String.fromCharCodes([for (final b in bytes) _cp1252[b] ?? b]);

  // -------------------------------------------------------------------
  // Interpretação do texto
  // -------------------------------------------------------------------

  /// Monta a pré-visualização de [text]. [existingNames] são os nomes que já
  /// estão no catálogo (as linhas iguais são marcadas como já existentes).
  static CatalogPreview parse(
    String text, {
    Iterable<String> existingNames = const [],
    bool legacyEncoding = false,
  }) {
    final repaired = repairMojibake(text);
    text = repaired.text;
    final delimiter = _detectDelimiter(text);
    final rows = _readRows(text, delimiter);

    if (rows.length > maxRows + 1) {
      throw const CatalogImportException(
        'A lista tem mais de $maxRows linhas. Divida em arquivos menores.',
      );
    }

    // Cabeçalho: a primeira linha tem uma coluna chamada nome/produto/item...
    var nameCol = 0;
    int? unitCol = rows.isNotEmpty && rows.first.cells.length > 1 ? 1 : null;
    var hadHeader = false;
    if (rows.isNotEmpty) {
      final folded = [for (final c in rows.first.cells) foldForSearch(c).trim()];
      final nameAt = folded.indexWhere(_nameHeaders.contains);
      if (nameAt >= 0) {
        hadHeader = true;
        nameCol = nameAt;
        final unitAt = folded.indexWhere(_unitHeaders.contains);
        unitCol = unitAt >= 0 ? unitAt : null;
      }
    }

    final known = <String, String>{
      for (final n in existingNames) nameKey(n): n,
    };
    final seenInFile = <String, String>{};
    final entries = <ImportEntry>[];

    for (final row in hadHeader ? rows.skip(1) : rows) {
      if (row.cells.every((c) => c.trim().isEmpty)) continue; // linha em branco

      final name = _cleanName(nameCol < row.cells.length ? row.cells[nameCol] : '');
      final unitText = unitCol != null && unitCol < row.cells.length ? _cleanName(row.cells[unitCol]) : '';
      final unit = MeasureUnit.parse(unitText)?.symbol;
      final ignoredUnit = unitText.isNotEmpty && unit == null ? unitText : null;

      if (name.isEmpty) {
        entries.add(ImportEntry(line: row.line, name: '', status: EntryStatus.nameEmpty));
        continue;
      }
      if (name.length > maxNameLength) {
        entries.add(ImportEntry(
          line: row.line,
          name: '${name.substring(0, 40)}…',
          status: EntryStatus.nameTooLong,
        ));
        continue;
      }

      final key = nameKey(name);
      final existing = known[key];
      final repeated = seenInFile[key];
      if (existing != null) {
        entries.add(ImportEntry(
          line: row.line, name: name, status: EntryStatus.alreadyExists,
          unit: unit, ignoredUnit: ignoredUnit, existingName: existing,
        ));
      } else if (repeated != null) {
        entries.add(ImportEntry(
          line: row.line, name: name, status: EntryStatus.duplicateInFile,
          unit: unit, ignoredUnit: ignoredUnit, existingName: repeated,
        ));
      } else {
        seenInFile[key] = name;
        entries.add(ImportEntry(
          line: row.line, name: name, status: EntryStatus.fresh,
          unit: unit, ignoredUnit: ignoredUnit,
        ));
      }
    }

    return CatalogPreview(
      entries: entries,
      hadHeader: hadHeader,
      delimiter: delimiter,
      legacyEncoding: legacyEncoding,
      repairedLines: repaired.lines,
    );
  }

  /// Conserta texto cujos acentos foram corrompidos pela dupla codificação
  /// mais comum: o arquivo era UTF-8, alguma ferramenta (Excel, PowerShell...)
  /// o leu como Windows-1252 e o regravou como UTF-8. "Café" vira "CafÃ©".
  ///
  /// O conserto desfaz o caminho: cada caractere volta ao byte que o gerou e
  /// os bytes são relidos como UTF-8. Só vale se o resultado for UTF-8
  /// VÁLIDO, o que praticamente nunca acontece por acaso em texto normal
  /// ("PÃO" vira bytes C3 4F, que não são UTF-8, e fica como está). É feito
  /// linha a linha, então um arquivo parcialmente corrompido também é aproveitado.
  static ({String text, int lines}) repairMojibake(String text) {
    // Só vale a pena tentar se há uma letra que possa ser a abertura de uma sequência
    // UTF-8 lida como Windows-1252 (bytes C2 a F4: de Â a ô).
    if (!text.contains(_utf8Lead)) return (text: text, lines: 0);

    var repairedLines = 0;
    final lines = text.split('\n').map((line) {
      if (!line.contains(_utf8Lead)) return line;
      final fixed = _undoMojibake(line);
      if (fixed == null || fixed == line) return line;
      repairedLines++;
      return fixed;
    }).toList();
    return (text: lines.join('\n'), lines: repairedLines);
  }

  static final _utf8Lead = RegExp('[Â-ô]');

  static final Map<int, int> _cp1252Reverse = {for (final e in _cp1252.entries) e.value: e.key};

  static String? _undoMojibake(String line) {
    final bytes = <int>[];
    for (final rune in line.runes) {
      final byte = _cp1252Reverse[rune] ?? (rune <= 0xFF ? rune : null);
      if (byte == null) return null; // tem caractere que não vem de Windows-1252: não é este caso
      bytes.add(byte);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// Tira caracteres de controle, junta espaços repetidos e apara as pontas.
  static String _cleanName(String raw) => raw
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Escolhe o separador de colunas: `;`, tab ou vírgula, nessa ordem de
  /// preferência, mas só se aparecer na MAIORIA das linhas. Assim uma lista de
  /// um nome por linha com uma vírgula aqui e ali ("Arroz, tipo 1") não é
  /// partida ao meio.
  ///
  /// Só conta o que está FORA de aspas: o `;` de `"Arroz; tipo 1",kg` não faz
  /// do arquivo um arquivo separado por `;`.
  static String? _detectDelimiter(String text) {
    const candidates = [';', '\t', ','];
    final linesWith = {for (final c in candidates) c: 0};
    final seenInLine = <String>{};
    var lines = 0;
    var lineHasContent = false;
    var inQuotes = false;

    void endLine() {
      if (lineHasContent) {
        lines++;
        for (final c in seenInLine) {
          linesWith[c] = linesWith[c]! + 1;
        }
      }
      seenInLine.clear();
      lineHasContent = false;
    }

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        lineHasContent = true;
      } else if (!inQuotes && (ch == '\n' || ch == '\r')) {
        endLine();
      } else {
        if (!inQuotes && linesWith.containsKey(ch)) seenInLine.add(ch);
        if (ch.trim().isNotEmpty) lineHasContent = true;
      }
    }
    endLine();

    if (lines == 0) return null;
    for (final c in candidates) {
      if (linesWith[c]! * 2 >= lines) return c;
    }
    return null;
  }

  /// Leitor de CSV (RFC 4180): campos entre aspas, aspas duplicadas e quebras
  /// de linha dentro de aspas. Guarda a linha de origem de cada registro.
  static List<_Row> _readRows(String text, String? delimiter) {
    final rows = <_Row>[];
    var cells = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;
    var line = 1;
    var rowLine = 1;

    void endCell() {
      cells.add(cell.toString());
      cell.clear();
    }

    void endRow() {
      endCell();
      rows.add(_Row(rowLine, cells));
      cells = <String>[];
      rowLine = line;
    }

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          if (ch == '\n') line++;
          cell.write(ch);
        }
      } else if (ch == '"' && cell.isEmpty) {
        inQuotes = true;
      } else if (delimiter != null && ch == delimiter) {
        endCell();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        line++;
        endRow();
      } else {
        cell.write(ch);
      }
    }
    if (cell.isNotEmpty || cells.isNotEmpty) endRow();
    return rows;
  }
}

class _Row {
  const _Row(this.line, this.cells);

  final int line;
  final List<String> cells;
}

/// Gera o CSV do catálogo (`nome;unidade`) para exportar ou copiar. Lê de
/// volta com [CatalogParser.parse].
String buildCatalogCsv(Iterable<({String name, String? unit})> products) {
  String field(String value) =>
      value.contains(RegExp(r'[;"\n\r]')) ? '"${value.replaceAll('"', '""')}"' : value;

  final buffer = StringBuffer('nome;unidade\n');
  for (final p in products) {
    buffer.write('${field(p.name)};${field(p.unit ?? '')}\n');
  }
  return buffer.toString();
}

/// O mesmo CSV como bytes UTF-8 com BOM, que é o que faz o Excel abrir
/// acentos e emojis corretamente.
Uint8List catalogCsvBytes(Iterable<({String name, String? unit})> products) =>
    Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(buildCatalogCsv(products))]);
