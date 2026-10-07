enum UserRole { owner, partner }

/// The signed-in person's role and permissions (from `public.profiles`).
/// The UI uses this only to show/hide controls; the database enforces access.
class Profile {
  const Profile({
    required this.id,
    required this.fullName,
    required this.role,
    required this.isActive,
    required this.canCreateSale,
    required this.canOverridePrice,
    this.fullAccess = false,
  });

  final String id;
  final String fullName;
  final UserRole role;
  final bool isActive;
  final bool canCreateSale;
  final bool canOverridePrice;

  /// Partner trusted with everything except users and the private password.
  final bool fullAccess;

  /// The real owner (users, private password).
  bool get isRealOwner => role == UserRole.owner;

  /// Can see and manage business data like the owner (owner or full-access partner).
  bool get isOwner => isRealOwner || fullAccess;
  bool get isPartner => role == UserRole.partner;
  bool get isFullPartner => isPartner && fullAccess;

  String get roleLabel => isRealOwner ? 'Owner' : (fullAccess ? 'Partner · Full access' : 'Partner');

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        fullName: (j['full_name'] as String?) ?? '',
        role: j['role'] == 'owner' ? UserRole.owner : UserRole.partner,
        isActive: j['is_active'] == true,
        canCreateSale: j['can_create_sale'] == true,
        canOverridePrice: j['can_override_price'] == true,
        fullAccess: j['full_access'] == true,
      );
}
