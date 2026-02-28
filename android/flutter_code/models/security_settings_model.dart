class SecuritySettings {
  final String id;
  final String userId;
  final bool passcodeEnabled;
  final bool biometricEnabled;
  final bool twoFactorEnabled;
  final String? twoFactorMethod; // 'email' or 'sms'
  final bool autoDeleteEnabled;
  final int autoDeletePeriodHours; // 0 = never, 24 = 1 day, 168 = 7 days, 720 = 30 days
  final DateTime createdAt;
  final DateTime updatedAt;

  SecuritySettings({
    required this.id,
    required this.userId,
    this.passcodeEnabled = false,
    this.biometricEnabled = false,
    this.twoFactorEnabled = false,
    this.twoFactorMethod,
    this.autoDeleteEnabled = false,
    this.autoDeletePeriodHours = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'passcodeEnabled': passcodeEnabled ? 1 : 0,
      'biometricEnabled': biometricEnabled ? 1 : 0,
      'twoFactorEnabled': twoFactorEnabled ? 1 : 0,
      'twoFactorMethod': twoFactorMethod,
      'autoDeleteEnabled': autoDeleteEnabled ? 1 : 0,
      'autoDeletePeriodHours': autoDeletePeriodHours,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory SecuritySettings.fromJson(Map<String, dynamic> json) {
    return SecuritySettings(
      id: json['id'] as String,
      userId: json['userId'] as String,
      passcodeEnabled: (json['passcodeEnabled'] as int) == 1,
      biometricEnabled: (json['biometricEnabled'] as int) == 1,
      twoFactorEnabled: (json['twoFactorEnabled'] as int) == 1,
      twoFactorMethod: json['twoFactorMethod'] as String?,
      autoDeleteEnabled: (json['autoDeleteEnabled'] as int) == 1,
      autoDeletePeriodHours: json['autoDeletePeriodHours'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  SecuritySettings copyWith({
    String? id,
    String? userId,
    bool? passcodeEnabled,
    bool? biometricEnabled,
    bool? twoFactorEnabled,
    String? twoFactorMethod,
    bool? autoDeleteEnabled,
    int? autoDeletePeriodHours,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SecuritySettings(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      passcodeEnabled: passcodeEnabled ?? this.passcodeEnabled,
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
      twoFactorEnabled: twoFactorEnabled ?? this.twoFactorEnabled,
      twoFactorMethod: twoFactorMethod ?? this.twoFactorMethod,
      autoDeleteEnabled: autoDeleteEnabled ?? this.autoDeleteEnabled,
      autoDeletePeriodHours: autoDeletePeriodHours ?? this.autoDeletePeriodHours,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
