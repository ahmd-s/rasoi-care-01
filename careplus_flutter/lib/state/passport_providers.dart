import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/passport_client.dart';

final passportClientProvider =
    Provider<PassportClient>((ref) => PassportClient());

/// The signed-in customer's Kitchen Passport. Failures surface as a
/// [PassportFailure] error so the screen can show the right retry state.
final kitchenPassportProvider =
    FutureProvider.autoDispose<KitchenPassport>((ref) async {
  final r = await ref.watch(passportClientProvider).overview();
  if (!r.ok) throw r.failure!;
  return r.passport!;
});
