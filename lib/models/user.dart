class User {
  final int? id;
  final String nickname;
  final DateTime createdAt;

  User({
    this.id,
    required this.nickname,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'nickname': nickname,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'] as int?,
      nickname: map['nickname'] as String? ?? '同学',
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  User copyWith({int? id, String? nickname, DateTime? createdAt}) {
    return User(
      id: id ?? this.id,
      nickname: nickname ?? this.nickname,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
