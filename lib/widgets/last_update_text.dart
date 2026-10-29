import 'package:flutter/material.dart';

import '../utils/last_update.dart';

/// "Última atualização 29/10/2026 18:27 por Fulano".
///
/// O nome vem de [nameOf] (busca no servidor, pode falhar ou demorar); até lá,
/// ou sem rede, aparece só a data. Quem fez a alteração é o próprio usuário
/// ([currentUserId]) aparece como "você", sem precisar de busca.
class LastUpdateText extends StatefulWidget {
  const LastUpdateText({
    super.key,
    required this.at,
    required this.userId,
    required this.currentUserId,
    required this.nameOf,
    required this.cachedName,
    this.style,
  });

  final DateTime at;
  final String? userId;
  final String? currentUserId;

  /// Busca o nome de um usuário (`null` se não conseguir).
  final Future<String?> Function(String userId) nameOf;

  /// Nome já conhecido, sem espera (evita piscar ao rolar a lista).
  final String? Function(String userId) cachedName;
  final TextStyle? style;

  @override
  State<LastUpdateText> createState() => _LastUpdateTextState();
}

class _LastUpdateTextState extends State<LastUpdateText> {
  String? _name;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(LastUpdateText old) {
    super.didUpdateWidget(old);
    if (old.userId != widget.userId) _resolve();
  }

  void _resolve() {
    final id = widget.userId;
    _name = null;
    if (id == null || id == widget.currentUserId) return;
    _name = widget.cachedName(id);
    if (_name != null) return;
    widget.nameOf(id).then((name) {
      // Ignora a resposta se, nesse meio tempo, o tile passou a outra pessoa.
      if (mounted && name != null && widget.userId == id) setState(() => _name = name);
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.userId;
    final by = id == null ? null : (id == widget.currentUserId ? 'você' : _name);
    return Text(
      formatLastUpdate(widget.at, by: by),
      style: widget.style,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
