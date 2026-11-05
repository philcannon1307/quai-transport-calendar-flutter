/// A sibling truck that shares the same login/calendar view.
class LinkedTruck {
  const LinkedTruck({required this.displayName, required this.truck});
  final String displayName;
  final String truck;
}

class Carrier {
  const Carrier({
    required this.displayName,
    required this.group,
    required this.truck,
    this.ownerLabel,
    this.backendUsername,
    this.linkedTrucks = const <LinkedTruck>[],
  });

  final String displayName;
  final String group;
  final String truck;
  final String? ownerLabel;

  /// Backend (NetSuite) account name when it differs from the display name.
  final String? backendUsername;
  final List<LinkedTruck> linkedTrucks;
}

/// One backend account per truck, labelled with its shared calendar name.
/// Credentials are deliberately absent: the server-side token exchange owns them.
class CarrierAccount {
  const CarrierAccount(
      {required this.displayName, required this.username, required this.truck});
  final String displayName;
  final String username;
  final String truck;
}
