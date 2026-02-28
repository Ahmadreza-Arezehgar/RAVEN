class User {
  final String id;
  final String username;
  final String? email;
  final String? phone;
  final String? avatarPath;
  final String? bio;
  final DateTime createdAt;
  final bool showUsername; // Privacy Feature
  final String? publicKey; // RSA public key for E2EE
  final String? firstName;
  final String? lastName;

  User({
    required this.id,
    required this.username,
    this.email,
    this.phone,
    this.avatarPath,
    this.bio,
    required this.createdAt,
    this.showUsername = true,
    this.publicKey,
    this.firstName,
    this.lastName,
  });

  /// Display name: "FirstName LastName" or fallback to username
  String get displayName {
    final full = [firstName, lastName]
        .where((s) => s?.trim().isNotEmpty == true)
        .join(' ')
        .trim();
    return full.isNotEmpty ? full : username;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'email': email,
        'phone': phone,
        'avatarPath': avatarPath,
        'bio': bio,
        'createdAt': createdAt.toIso8601String(),
        'showUsername': showUsername ? 1 : 0,
        'publicKey': publicKey,
        'firstName': firstName,
        'lastName': lastName,
      };

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        username: json['username'] as String,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        avatarPath: json['avatarPath'] ?? json['avatar_path'] as String?,
        bio: json['bio'] as String?,
        createdAt: DateTime.parse(json['createdAt'] ?? json['created_at'] ?? DateTime.now().toIso8601String()),
        showUsername: json['showUsername'] == 1 || json['show_username'] == true,
        publicKey: json['publicKey'] ?? json['public_key'] as String?,
        firstName: json['firstName'] ?? json['first_name'] as String?,
        lastName: json['lastName'] ?? json['last_name'] as String?,
      );

  User copyWith({
    String? username,
    String? email,
    String? phone,
    String? avatarPath,
    String? bio,
    String? publicKey,
    String? firstName,
    String? lastName,
  }) =>
      User(
        id: id,
        username: username ?? this.username,
        email: email ?? this.email,
        phone: phone ?? this.phone,
        avatarPath: avatarPath ?? this.avatarPath,
        bio: bio ?? this.bio,
        createdAt: createdAt,
        showUsername: showUsername,
        publicKey: publicKey ?? this.publicKey,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
      );
}
