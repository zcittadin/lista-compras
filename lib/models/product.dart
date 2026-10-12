import '../data/app_database.dart';

class Product {
  const Product({required this.id, required this.name, this.defaultUnit});

  final String id;
  final String name;
  final String? defaultUnit;

  factory Product.fromLocal(LocalProduct row) => Product(
        id: row.id,
        name: row.name,
        defaultUnit: row.defaultUnit,
      );
}
