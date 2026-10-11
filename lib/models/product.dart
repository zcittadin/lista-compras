class Product {
  const Product({required this.id, required this.name, this.defaultUnit});

  final String id;
  final String name;
  final String? defaultUnit;

  factory Product.fromMap(Map<String, dynamic> map) => Product(
        id: map['id'] as String,
        name: map['name'] as String,
        defaultUnit: map['default_unit'] as String?,
      );
}
