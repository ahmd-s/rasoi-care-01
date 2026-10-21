import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/firebase/firestore_user_profile_service.dart';
import '../data/firebase/technician_location_service.dart';

final userProfileServiceProvider =
    Provider<UserProfileService>((ref) => UserProfileService());

/// The signed-in person's live profile — see AccountScreen, which falls
/// back to demo data when this is null (mock mode / no profile saved yet).
final userProfileStreamProvider = StreamProvider<UserProfile?>(
  (ref) => ref.watch(userProfileServiceProvider).watchProfile(),
);

final technicianLocationServiceProvider =
    Provider<TechnicianLocationService>((ref) => TechnicianLocationService());

/// Live location for an active booking, keyed by booking id — see
/// TrackingScreen in lib/features/tracking/tracking_screen.dart.
final technicianLocationProvider =
    StreamProvider.autoDispose.family<TechnicianLocation?, String>(
  (ref, bookingId) =>
      ref.watch(technicianLocationServiceProvider).watchLocation(bookingId),
);
