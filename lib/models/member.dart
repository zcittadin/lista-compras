class Member {
  const Member({
    required this.userId,
    required this.isOwner,
    required this.email,
    this.fullName,
  });

  final String userId;
  final bool isOwner;
  final String email;
  final String? fullName;

  /// Nome para exibir: o nome do Google, ou o e-mail se não houver.
  String get displayName =>
      (fullName != null && fullName!.isNotEmpty) ? fullName! : email;
}
