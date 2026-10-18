import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/operations/api_repository.dart';
import '../data/operations/locations.dart';
import '../data/operations/models.dart';

final operationsRepositoryProvider = ChangeNotifierProvider<OperationsApiRepository>(
  (ref) => OperationsApiRepository(),
);

final reportRangeProvider = NotifierProvider<ReportRangeVM, ReportRange>(
  ReportRangeVM.new,
);

class ReportRangeVM extends Notifier<ReportRange> {
  @override
  ReportRange build() => ReportRange.week;
  void set(ReportRange value) => state = value;
}

final locationFilterProvider = NotifierProvider<LocationFilterVM, LocationFilter>(
  LocationFilterVM.new,
);

class LocationFilterVM extends Notifier<LocationFilter> {
  @override
  LocationFilter build() => LocationFilter(stateName: kStatesAndDistricts.keys.first);

  void setStateName(String stateName) => state = LocationFilter(stateName: stateName);

  void setDistrict(String? district) =>
      state = LocationFilter(stateName: state.stateName, district: district);
}
