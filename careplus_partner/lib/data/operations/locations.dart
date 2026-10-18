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

  /// Whether a technician's or booking's `area` string falls under this
  /// selection. A null [district] matches everything, including a record
  /// with no area on file — only picking a specific district should ever
  /// hide those.
  bool matches(String? area) => district == null || area == district;

  String get label => district ?? 'All districts';
}
