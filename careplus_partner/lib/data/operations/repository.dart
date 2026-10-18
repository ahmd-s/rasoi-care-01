// The repository interface is the seam between the app and the real
// Flask+SQLite backend (app.py/database.py at the repo root) — the same one
// careplus_flutter (Customer) and careplus_partner (Partner) share.
//
// Unlike those two apps, Admin has no legitimate use for mock/demo data:
// every screen here shows operational business numbers (revenue, bookings,
// technician verification, staff accounts, stock), and there is no
// catalog-description-style content that's fine to keep static. So there is
// exactly one implementation of this interface — [ApiRepository] in
// lib/data/api/api_repository.dart — and every getter here is nullable:
// null means "not fetched yet" (or the fetch failed), and every screen shows
// a real loading/empty state for that rather than ever inventing a number.

import 'models.dart';

abstract interface class AdminRepository {
  /// [district] scopes every number to one operating area (see
  /// lib/data/locations.dart's State -> District picker) — null means the
  /// whole business, matching this method's original no-argument behavior.
  AdminOverview? overview({String? district});
  List<AdminBooking>? bookings();
  List<AdminTeamMember>? team();
  List<AdminStockItem>? stock();
  List<StaffAccount>? staffAccounts();
  ReportBundle? report(ReportRange range, {String? district});

  /// Approves a self-signed-up technician's application (see
  /// careplus_partner's TechApplyScreen) — flips them verified/online so
  /// they start appearing in auto-routing and their own job feed.
  Future<bool> verifyTechnician(String technicianId);

  /// Assigns (or reassigns) which technician is on a booking
  /// (`PATCH /api/bookings/<id>/assign`) — how an admin routes a freshly
  /// requested job that auto-routing hasn't picked up, or swaps in a
  /// replacement.
  Future<bool> assignTechnician(String bookingId, String technicianId);

  /// Owner-only: creates a new staff account with an initial PIN, mirroring
  /// admin.html's existing invite flow (`POST /api/staff`).
  Future<bool> inviteStaff({
    required String name,
    required String phone,
    required String pin,
    required AdminRole role,
  });

  /// Owner-only: suspends or reinstates a staff account
  /// (`PATCH /api/staff/<id>`).
  Future<bool> setStaffActive(String staffId, bool active);

  /// Updates a stock item's on-hand quantity (`PATCH /api/inventory/<id>`).
  Future<bool> adjustStock(String itemId, {required int quantity});
}
