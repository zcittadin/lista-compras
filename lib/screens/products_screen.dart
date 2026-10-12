import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/measure_unit.dart';
import '../models/product.dart';
import '../services/catalog_files.dart';
import '../services/catalog_import.dart';
import '../services/products_service.dart';
import '../utils/text.dart';
import '../widgets/product_dialog.dart';
import 'import_catalog_screen.dart';
import '../widgets/sync_status_banner.dart';

/// Gerenciamento do catálogo de produtos: buscar, criar, editar e apagar.
///
/// O catálogo só alimenta as sugestões ao digitar um item; mudar ou apagar
/// um produto não altera itens que já estão em listas.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _service = ProductsService.instance;
  late final _products = _service.watchProducts();
  final _search = TextEditingController();
  String _query = '';

  /// Produtos que o usuário acabou de arrastar para apagar. O `Dismissible`
  /// exige que o item saia da árvore na mesma hora, e o banco só avisa um
  /// instante depois, então escondemos já.
  final _hidden = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit({Product? product}) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => ProductDialog(
        product: product,
        onSave: (name, unit) => product == null
            ? _service.create(name, unit: unit)
            : _service.update(product.id, name: name, unit: unit),
      ),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _import() async {
    final existing = [for (final p in await _service.watchProducts().first) p.name];
    if (!mounted) return;
    final count = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (_) => ImportCatalogScreen(
          existingNames: existing,
          onImport: _service.importProducts,
        ),
      ),
    );
    if (count != null && mounted) {
      _toast(count == 1 ? '1 produto importado' : '$count produtos importados');
    }
  }

  Future<List<({String name, String? unit})>?> _exportable() async {
    final products = await _service.watchProducts().first;
    if (products.isEmpty) {
      if (mounted) _toast('O catálogo está vazio.');
      return null;
    }
    return [for (final p in products) (name: p.name, unit: p.defaultUnit)];
  }

  Future<void> _exportFile() async {
    final items = await _exportable();
    if (items == null) return;
    try {
      final saved = await saveCatalogFile(catalogCsvBytes(items));
      if (saved && mounted) _toast('Catálogo exportado (${items.length} produtos)');
    } catch (e) {
      if (mounted) _toast('Não foi possível exportar: $e');
    }
  }

  Future<void> _copyText() async {
    final items = await _exportable();
    if (items == null) return;
    await Clipboard.setData(ClipboardData(text: buildCatalogCsv(items)));
    if (mounted) {
      _toast('${items.length} produtos copiados. Cole em uma mensagem ou em Importar > Colar texto.');
    }
  }

  Future<void> _delete(Product product) async {
    setState(() => _hidden.add(product.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _service.delete(product.id);
    } catch (e) {
      if (mounted) setState(() => _hidden.remove(product.id));
      messenger.showSnackBar(SnackBar(content: Text('Não foi possível apagar: $e')));
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('"${product.name}" removido do catálogo'),
          action: SnackBarAction(
            label: 'Desfazer',
            onPressed: () => _undo(product, messenger),
          ),
        ),
      );
  }

  Future<void> _undo(Product product, ScaffoldMessengerState messenger) async {
    try {
      await _service.restore(product.id);
    } on DuplicateProductException {
      messenger.showSnackBar(
        SnackBar(content: Text('Já existe outro produto chamado "${product.name}".')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não foi possível desfazer: $e')));
    } finally {
      if (mounted) setState(() => _hidden.remove(product.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catálogo de produtos'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Mais opções',
            onSelected: (action) {
              switch (action) {
                case 'import':
                  _import();
                case 'export':
                  _exportFile();
                case 'copy':
                  _copyText();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'import', child: Text('Importar catálogo…')),
              PopupMenuItem(value: 'export', child: Text('Exportar para arquivo…')),
              PopupMenuItem(value: 'copy', child: Text('Copiar como texto')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncStatusBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Buscar produto',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Limpar',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onChanged: (value) => setState(() => _query = foldForSearch(value.trim())),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Product>>(
              stream: _products,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Erro ao carregar: ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                // Um produto só fica escondido enquanto o banco ainda o entrega;
                // depois que ele some do stream, o esconderijo já cumpriu o papel.
                _hidden.retainAll(snapshot.data!.map((p) => p.id).toSet());
                final all = snapshot.data!.where((p) => !_hidden.contains(p.id)).toList();
                final shown = _query.isEmpty
                    ? all
                    : all.where((p) => foldForSearch(p.name).contains(_query)).toList();

                if (all.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Nenhum produto no catálogo ainda.\n'
                        'Eles entram sozinhos ao adicionar itens, ou toque em + para criar.\n'
                        'Para trazer uma lista pronta, use o menu ⋮ > Importar catálogo.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                if (shown.isEmpty) {
                  return const Center(child: Text('Nenhum produto encontrado.'));
                }
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _query.isEmpty
                              ? '${all.length} ${all.length == 1 ? 'produto' : 'produtos'}'
                              : '${shown.length} de ${all.length}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (context, i) => _ProductTile(
                          key: ValueKey(shown[i].id),
                          product: shown[i],
                          onTap: () => _edit(product: shown[i]),
                          onDelete: () => _delete(shown[i]),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Novo produto',
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    super.key,
    required this.product,
    required this.onTap,
    required this.onDelete,
  });

  final Product product;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final unit = product.defaultUnit == null ? null : MeasureUnit.parse(product.defaultUnit);
    final subtitle = product.defaultUnit == null || product.defaultUnit!.trim().isEmpty
        ? null
        : unit == null
            ? product.defaultUnit!.trim()
            : '${unit.symbol} · ${unit.label}';

    return Dismissible(
      key: ValueKey('dismiss-${product.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) => onDelete(),
      child: ListTile(
        title: Text(product.name),
        subtitle: subtitle == null ? null : Text(subtitle),
        onTap: onTap,
      ),
    );
  }
}
