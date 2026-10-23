/// Where Rasoi Care actually operates today — a State -> District structure
/// (rather than a flat city list) so more states can be added later without
/// changing how the picker or the dashboard filtering work, even though
/// there's only one state, Maharashtra, so far. These five districts match
/// exactly the service-area list the Partner app's signup form already
/// uses — no new locations invented here.
const Map<String, List<String>> kStatesAndDistricts = {
  'Maharashtra': ['Nashik', 'Pune', 'Mumbai', 'Nagpur', 'Aurangabad'],
};

/// The dashboard's current State/District selection. [district] of null
/// means "every district in [stateName]" — today that's indistinguishable
/// from "no filter at all" since every real booking/technician belongs to
/// Maharashtra, but keeping the state dimension real (rather than just a
/// flat district string) means a second state can be added later without
/// reshaping this type.
class LocationFilter {
  const LocationFilter({required this.stateName, this.district});
  final String stateName;
  final String? district;

  List<String> get districtsInState => kStatesAndDistricts[stateName] ?? const [];

  /// Whether a technician's service area or a booking's inferred city falls
  /// under this selection. Booking `area` is only a label such as Home/Office.
  bool matches(String? location) => district == null || location == district;

  String get label => district ?? 'All districts';
}
