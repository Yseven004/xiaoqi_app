class BookCategory {
  const BookCategory({
    this.id,
    required this.name,
    required this.normalizedName,
    this.isSystem = false,
    this.createdAt = '',
    this.updatedAt = '',
  });

  final int? id;
  final String name;
  final String normalizedName;
  final bool isSystem;
  final String createdAt;
  final String updatedAt;

  factory BookCategory.fromMap(Map<String, Object?> map) => BookCategory(
    id: map['id'] as int?,
    name: map['name'] as String? ?? '',
    normalizedName: map['normalized_name'] as String? ?? '',
    isSystem: (map['is_system'] as int? ?? 0) == 1,
    createdAt: map['created_at'] as String? ?? '',
    updatedAt: map['updated_at'] as String? ?? '',
  );
}
