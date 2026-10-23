// The one and only [AdminRepository] implementation — backed by the live
// Flask+SQLite backend at the repo root (app.py / database.py), sharing real
// data with careplus_flutter (customer) and careplus_partner (technician).
// There is no mock fallback: every field either comes from a real fetch or
// is null (not yet loaded / failed), and every screen shows a real loading
// or empty state for null rather than ever inventing a number — see
// repository.dart's header for why this app has no Mock implementation,
// unlike its sibling apps.
//
// The interface is synchronous by design, so this class fetches in the
// background and caches whatever arrives. It's a [ChangeNotifier] so
// `ChangeNotifierProvider` (see lib/state/providers.dart) can rebuild
// watchers once background fetches resolve, without turning the repository
// interface itself async.

import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../models.dart';
import '../repository.dart';
import 'api_config.dart';

const _timeout = Duration(seconds: 8);

class ApiRepository extends ChangeNotifier implements AdminRepository {
  ApiRepository({http.Client? client}) : _client = client ?? http.Client() {
    // Every one of these needs a signed-in staff member's token — the
    // backend used to serve bookings/stats/inventory/complaints to anyone
    // with no token at all. The repository can be constructed before
    // Firebase Auth has restored `currentUser` on a cold start, so try once
    // now and again the moment auth state actually settles, rather than
    // only once at construction.
    unawaited(_fetchOverviewStats());
    unawaited(_fetchBookings());
    unawaited(_fetchInventory());
    unawaited(_fetchComplaints());
    unawaited(_fetchTechnicians());
    unawaited(_fetchStaffAccounts());
    unawaited(_fetchReport(ReportRange.week));
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) return;
      unawaited(_fetchOverviewStats());
      unawaited(_fetchBookings());
      unawaited(_fetchInventory());
      unawaited(_fetchComplaints());
      unawaited(_fetchTechnicians());
      unawaited(_fetchStaffAccounts());
      unawaited(_fetchReport(_lastReportRange, district: _lastReportDistrict));
    });
  }

  final http.Client _client;
  StreamSubscription<User?>? _authSub;
  ReportRange _lastReportRange = ReportRange.week;
  String? _lastReportDistrict;

  // ---- raw cached pieces (null = not yet fetched / fetch failed) --------
  Map<String, dynamic>? _statsRaw;
  List<dynamic>? _bookingsRaw;
  List<dynamic>? _techniciansRaw;
  List<dynamic>? _inventoryRaw;
  List<dynamic>? _complaintsRaw;
  List<dynamic>? _staffRaw;
  // Keyed by (range, district) — a district-scoped report is a genuinely
  // different backend query (see stats_reports's `area` param in app.py),
  // not just a client-side filter of the whole-business one.
  final Map<(ReportRange, String?), Map<String, dynamic>> _reportsRaw = {};
  final Set<(ReportRange, String?)> _reportsFetching = {};

  // A fetch that never completes leaves its `_xxxRaw` cache at null forever,
  // which every screen reads as "still loading" — indistinguishable from a
  // fetch that failed (bad/missing token, non-200, network error/timeout).
  // Track which named fetches have actually failed so screens can show a
  // real "couldn't load, retry" state instead of spinning forever. Not
  // marked failed while the token is simply still null (Firebase Auth may
  // not have restored `currentUser` yet on a cold start) — the
  // authStateChanges listener above already retries automatically once
  // auth settles, so that case is transient, not a failure to surface.
  final Set<String> _failedFetches = {};

  bool fetchFailed(String key) => _failedFetches.contains(key);

  void _markFailed(String key) {
    _failedFetches.add(key);
    notifyListeners();
  }

  void _markSucceeded(String key) => _failedFetches.remove(key);

  /// Re-runs the named fetch after a user-initiated retry tap.
  Future<void> retryFetch(String key) async {
    _failedFetches.remove(key);
    notifyListeners();
    switch (key) {
      case 'overview':
        await _fetchOverviewStats();
      case 'bookings':
        await _fetchBookings();
      case 'technicians':
        await _fetchTechnicians();
      case 'inventory':
        await _fetchInventory();
      case 'complaints':
        await _fetchComplaints();
      case 'staff':
        await _fetchStaffAccounts();
    }
  }

  // ============================================================ OVERVIEW
  @override
  AdminOverview? overview({String? district}) {
    final stats = _statsRaw;
    final bookings = _bookingsRaw;
    final technicians = _techniciansRaw;
    if (stats == null || bookings == null || technicians == null) return null;

    final allBookings = bookings.cast<Map<String, dynamic>>();
    final allTechnicians = technicians.cast<Map<String, dynamic>>();
    final scopedBookings =
        district == null ? allBookings : allBookings.where((b) => b['city'] == district).toList();
    final scopedTechnicians = district == null
        ? allTechnicians
        : allTechnicians.where((t) => t['area'] == district).toList();

    final completedJobs = scopedBookings.where((b) => b['status'] == 'Completed').length;

    var ratingWeightedSum = 0.0;
    var ratingCount = 0;
    for (final t in scopedTechnicians) {
      final count = _asInt(t['ratingCount']);
      ratingWeightedSum += _asDouble(t['rating']) * count;
      ratingCount += count;
    }
    final avgRating = ratingCount == 0 ? 0.0 : ratingWeightedSum / ratingCount;

    // Unfiltered ("whole business") keeps using the backend's own aggregate
    // stats exactly as before — only a district selection switches to
    // recomputing from the already-fetched full booking/technician lists,
    // so the default view's numbers are untouched by this filter existing.
    final int revenuePaise;
    final int openComplaints;
    final int totalTechnicians;
    final int onlineTechnicians;
    if (district == null) {
      revenuePaise = _asInt(stats['revenue']) * 100;
      openComplaints = _asInt(stats['openComplaints']);
      totalTechnicians = _asInt(stats['totalTechnicians']);
      onlineTechnicians = _asInt(stats['onlineTechnicians']);
    } else {
      revenuePaise = scopedBookings
              .where((b) => b['status'] == 'Completed')
              .fold<int>(0, (sum, b) => sum + _asInt(b['total_amount'] ?? b['price'])) *
          100;
      final bookingAreaById = {
        for (final b in allBookings) b['id'] as String?: b['city'] as String?,
      };
      openComplaints = (_complaintsRaw?.cast<Map<String, dynamic>>() ?? const [])
          .where((c) => c['status'] != 'Resolved')
          .where((c) => bookingAreaById[c['bookingId'] as String?] == district)
          .length;
      totalTechnicians = scopedTechnicians.length;
      onlineTechnicians = scopedTechnicians.where((t) => t['online'] == true).length;
    }
    final utilisationPct =
        totalTechnicians == 0 ? 0 : ((onlineTechnicians / totalTechnicians) * 100).round();

    return AdminOverview(
      revenuePaise: revenuePaise,
      completedJobs: completedJobs,
      openComplaints: openComplaints,
      avgRating: avgRating,
      ratingCount: ratingCount,
      weekBars: _weekBars(district: district),
      weekLabels: _weekLabels(),
      technicianUtilisationPct: utilisationPct,
      attention: _attention(district: district),
    );
  }

  /// The last 7 calendar days (today last), zero-filled for any day with no
  /// completed revenue — real data, not a canned week shape.
  List<int> _weekBars({String? district}) {
    final byDay = <String, int>{};
    for (final b in _bookingsRaw?.cast<Map<String, dynamic>>() ?? const []) {
      if (b['status'] != 'Completed') continue;
      if (district != null && b['city'] != district) continue;
      final updatedAt = b['updatedAt'] as String?;
      final dt = updatedAt == null ? null : DateTime.tryParse(updatedAt);
      if (dt == null) continue;
      final key = DateFormat('yyyy-MM-dd').format(dt.toLocal());
      final amount = _asInt(b['total_amount'] ?? b['price']);
      byDay[key] = (byDay[key] ?? 0) + amount;
    }
    final now = DateTime.now();
    final amounts = [
      for (var i = 6; i >= 0; i--)
        byDay[DateFormat('yyyy-MM-dd').format(now.subtract(Duration(days: i)))] ?? 0,
    ];
    final max = amounts.fold<int>(0, (m, v) => v > m ? v : m);
    if (max == 0) return List.filled(7, 0);
    return [for (final v in amounts) ((v / max) * 100).round()];
  }

  List<String> _weekLabels() {
    final now = DateTime.now();
    return [for (var i = 6; i >= 0; i--) DateFormat('E').format(now.subtract(Duration(days: i)))[0]];
  }

  /// Real unassigned bookings and open complaints — nothing canned.
  List<AttentionItem> _attention({String? district}) {
    final items = <AttentionItem>[];
    final bookingAreaById = {
      for (final b in _bookingsRaw?.cast<Map<String, dynamic>>() ?? const [])
        b['id'] as String?: b['city'] as String?,
    };
    for (final b in _bookingsRaw?.cast<Map<String, dynamic>>() ?? const []) {
      if (b['status'] != 'Requested') continue;
      final area = (b['area'] as String?)?.trim();
      final city = (b['city'] as String?)?.trim();
      if (district != null && city != district) continue;
      final detail = [if (city?.isNotEmpty == true) city!, if (area?.isNotEmpty == true) area!]
          .join(' · ');
      items.add(AttentionItem(
        jobId: (b['id'] as String?) ?? '—',
        title: 'Unassigned · ${(b['service'] as String?) ?? 'Service'}',
        detail: detail.isNotEmpty ? detail : 'No area on file',
        tone: LineTone.neutral,
      ));
      if (items.length >= 4) break;
    }
    for (final c in _complaintsRaw?.cast<Map<String, dynamic>>() ?? const []) {
      if (c['status'] == 'Resolved') continue;
      if (district != null && bookingAreaById[c['bookingId'] as String?] != district) continue;
      final text = (c['text'] as String?)?.trim();
      items.add(AttentionItem(
        jobId: (c['id'] as String?) ?? '—',
        title: 'Complaint · ${(c['status'] as String?) ?? 'Open'}',
        detail: text?.isNotEmpty == true ? text! : 'No details on file',
        tone: LineTone.neutral,
        isComplaint: true,
      ));
      if (items.length >= 6) break;
    }
    return items;
  }

  Future<void> _fetchOverviewStats() async {
    try {
      final token = await _idToken();
      if (token == null) return; // staff-gated — nothing to fetch without one
      final res = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/stats/overview'), headers: _headers(token))
          .timeout(_timeout);
      if (res.statusCode != 200) return _markFailed('overview');
      _statsRaw = jsonDecode(res.body) as Map<String, dynamic>;
      _markSucceeded('overview');
      notifyListeners();
    } catch (_) {
      // Backend not deployed yet / offline / timed out.
      _markFailed('overview');
    }
  }

  // ============================================================ BOOKINGS
  @override
  List<AdminBooking>? bookings() {
    final raw = _bookingsRaw;
    if (raw == null) return null;
    final techNames = {
      for (final t in _techniciansRaw?.cast<Map<String, dynamic>>() ?? const [])
        t['id'] as String?: t['name'] as String?,
    };
    return [for (final b in raw) _bookingFrom(b as Map<String, dynamic>, techNames)];
  }

  AdminBooking _bookingFrom(Map<String, dynamic> b, Map<String?, String?> techNames) {
    final area = (b['area'] as String?)?.trim();
    final customerName = (b['customerName'] as String?)?.trim();
    final meta = [
      if (area != null && area.isNotEmpty) area,
      if (customerName != null && customerName.isNotEmpty) customerName,
    ].join(' · ');
    final status = (b['status'] as String?) ?? 'Requested';
    final technicianId = b['technicianId'] as String?;
    final directions = (b['directions'] as String?)?.trim();
    return AdminBooking(
      jobId: (b['id'] as String?) ?? '—',
      title: (b['service'] as String?) ?? 'Service request',
      meta: meta.isEmpty ? '—' : meta,
      statusLabel: status,
      category: _categoryForStatus(status),
      totalPaise: _asInt(b['total_amount'] ?? b['price']) * 100,
      createdAt: DateTime.tryParse((b['createdAt'] as String?) ?? ''),
      area: area?.isNotEmpty == true ? area : null,
      city: (b['city'] as String?)?.trim(),
      customerName: customerName?.isNotEmpty == true ? customerName : null,
      directions: directions?.isNotEmpty == true ? directions : null,
      technicianName: technicianId == null ? null : techNames[technicianId],
    );
  }

  /// The backend has no "scheduled" status string — every booking is either
  /// unassigned (just requested), some flavour of in-progress, or completed.
  /// Anything unrecognised is treated as in-progress (an active job of some
  /// kind) rather than silently dropped.
  BookingCategory _categoryForStatus(String status) => switch (status) {
        'Requested' => BookingCategory.unassigned,
        'Accepted' || 'On the way' || 'In Progress' => BookingCategory.inProgress,
        'Completed' => BookingCategory.closed,
        _ => BookingCategory.inProgress,
      };

  /// A Bearer token now decides the shape of the response server-side: a
  /// *staff* token (what we always send here) gets the full ops queue; a
  /// *customer* token would instead get just that customer's own bookings.
  /// Since staff and customer accounts are separate Firebase users, this
  /// staff member's token can never be misread as a customer token, so the
  /// admin queue always gets the full list it needs.
  Future<void> _fetchBookings() async {
    try {
      final token = await _idToken();
      if (token == null) return; // staff-gated — nothing to fetch without one
      final res = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/bookings'), headers: _headers(token))
          .timeout(_timeout);
      if (res.statusCode != 200) return _markFailed('bookings');
      _bookingsRaw = jsonDecode(res.body) as List<dynamic>;
      _markSucceeded('bookings');
      notifyListeners();
    } catch (_) {
      _markFailed('bookings');
    }
  }

  // ================================================================ TEAM
  @override
  List<AdminTeamMember>? team() {
    final raw = _techniciansRaw;
    if (raw == null) return null;
    return [for (final t in raw) _teamMemberFrom(t as Map<String, dynamic>)];
  }

  AdminTeamMember _teamMemberFrom(Map<String, dynamic> t) {
    final name = (t['name'] as String?) ?? 'Technician';
    final online = t['online'] == true;
    final categories = (t['categories'] as List?)?.cast<String>() ?? const [];
    return AdminTeamMember(
      id: t['id'] as String?,
      name: name,
      initials: _initials(name),
      specialties: categories.isNotEmpty
          ? categories.join(', ')
          : (t['category'] as String?) ?? '—',
      area: t['area'] as String?,
      statsLabel: '${_asInt(t['jobsCompleted'])} jobs',
      rating: _asDouble(t['rating']),
      // The payload can't distinguish "actively on a job" from "idle but
      // online" — online maps to idle, offline to offDuty. onJob is never
      // emitted for API-sourced rows.
      duty: online ? DutyStatus.idle : DutyStatus.offDuty,
      verified: t['verified'] == true,
      applicationSubmitted: t['applicationSubmitted'] == true,
      photoUrl: t['photoUrl'] as String?,
      experienceYears: t['experienceYears'] == null ? null : _asInt(t['experienceYears']),
      idDocumentUrl: t['idDocumentUrl'] as String?,
      bankAccountName: t['bankAccountName'] as String?,
      bankAccountNumber: t['bankAccountNumber'] as String?,
      bankIfsc: t['bankIfsc'] as String?,
      categories: categories,
      aadharDocumentUrl: t['aadharDocumentUrl'] as String?,
      aadharDocumentBackUrl: t['aadharDocumentBackUrl'] as String?,
      panDocumentUrl: t['panDocumentUrl'] as String?,
      bankPassbookUrl: t['bankPassbookUrl'] as String?,
      aadharDocumentReady: t['aadharDocumentReady'] == true,
      aadharDocumentBackReady: t['aadharDocumentBackReady'] == true,
      panDocumentReady: t['panDocumentReady'] == true,
      bankPassbookReady: t['bankPassbookReady'] == true,
      partnerCode: t['partnerCode'] as String?,
      employmentType: t['employmentType'] as String?,
    );
  }

  /// Real, itemized earnings for one technician — see
  /// GET /api/technicians/<id>/earnings. Null on any failure; the caller
  /// shows a loading/error state rather than a fabricated total.
  Future<TechnicianEarnings?> fetchTechnicianEarnings(String technicianId) async {
    try {
      final token = await _idToken();
      if (token == null) return null;
      final res = await _client
          .get(
            Uri.parse('${ApiConfig.baseUrl}/api/technicians/$technicianId/earnings'),
            headers: _headers(token),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is! Map<String, dynamic>) return null;
      final ledgerRaw = (data['ledger'] as List?) ?? const [];
      return TechnicianEarnings(
        employmentType: (data['employmentType'] as String?) ?? 'outsourced',
        commissionRate: (data['commissionRate'] as num?)?.toDouble() ?? 0,
        commissionTotalPaise: _asInt(data['commissionTotalPaise']),
        ledger: [
          for (final e in ledgerRaw.whereType<Map<String, dynamic>>())
            TechnicianLedgerEntry(
              id: '${e['id']}',
              kind: (e['kind'] as String?) ?? 'incentive',
              amountPaise: _asInt(e['amountPaise']),
              reason: (e['reason'] as String?) ?? '',
              bookingId: e['bookingId'] as String?,
              createdAt: DateTime.tryParse('${e['createdAt'] ?? ''}'),
            ),
        ],
        incentiveTotalPaise: _asInt(data['incentiveTotalPaise']),
        fineTotalPaise: _asInt(data['fineTotalPaise']),
        netTotalPaise: _asInt(data['netTotalPaise']),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _fetchTechnicians() async {
    try {
      final token = await _idToken();
      if (token == null) return; // staff-gated — nothing to fetch without one
      final res = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/technicians'), headers: _headers(token))
          .timeout(_timeout);
      if (res.statusCode != 200) return _markFailed('technicians');
      _techniciansRaw = jsonDecode(res.body) as List<dynamic>;
      _markSucceeded('technicians');
      notifyListeners();
    } catch (_) {
      _markFailed('technicians');
    }
  }

  @override
  Future<bool> verifyTechnician(String technicianId) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await _client
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/technicians/$technicianId/verify'),
            headers: _headers(token),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      // Refresh the cache so the Team screen reflects the change immediately
      // without waiting for the next natural refetch.
      await _fetchTechnicians();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> assignTechnician(String bookingId, String technicianId) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await _client
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/bookings/$bookingId/assign'),
            headers: {'Content-Type': 'application/json', ..._headers(token)},
            body: jsonEncode({'technician_id': technicianId}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      // Refresh so both the Bookings queue and Overview's "Needs attention"
      // list (derived from the same cached bookings) drop this job
      // immediately, without waiting for the next natural refetch.
      await _fetchBookings();
      return true;
    } catch (_) {
      return false;
    }
  }

  // =============================================================== STOCK
  @override
  List<AdminStockItem>? stock() {
    final raw = _inventoryRaw;
    if (raw == null) return null;
    return [for (final s in raw) _stockItemFrom(s as Map<String, dynamic>)];
  }

  AdminStockItem _stockItemFrom(Map<String, dynamic> s) => AdminStockItem(
        id: (s['id'] as String?) ?? '',
        name: (s['name'] as String?) ?? 'Item',
        sku: (s['sku'] as String?) ?? '—',
        inStock: _asInt(s['quantity']),
        reorderAt: _asInt(s['reorderLevel']),
        low: s['lowStock'] == true,
      );

  Future<void> _fetchInventory() async {
    try {
      final token = await _idToken();
      if (token == null) return; // staff-gated — nothing to fetch without one
      final res = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/inventory'), headers: _headers(token))
          .timeout(_timeout);
      if (res.statusCode != 200) return _markFailed('inventory');
      _inventoryRaw = jsonDecode(res.body) as List<dynamic>;
      _markSucceeded('inventory');
      notifyListeners();
    } catch (_) {
      _markFailed('inventory');
    }
  }

  @override
  Future<bool> adjustStock(String itemId, {required int quantity}) async {
    try {
      final token = await _idToken();
      final res = await _client
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/inventory/$itemId'),
            headers: {'Content-Type': 'application/json', ..._headers(token)},
            body: jsonEncode({'quantity': quantity}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      await _fetchInventory();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ========================================================= COMPLAINTS
  Future<void> _fetchComplaints() async {
    try {
      final token = await _idToken();
      if (token == null) return; // staff-gated — nothing to fetch without one
      final res = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/complaints'), headers: _headers(token))
          .timeout(_timeout);
      if (res.statusCode != 200) return _markFailed('complaints');
      _complaintsRaw = jsonDecode(res.body) as List<dynamic>;
      _markSucceeded('complaints');
      notifyListeners();
    } catch (_) {
      _markFailed('complaints');
    }
  }

  // ========================================================= STAFF ACCTS
  @override
  List<StaffAccount>? staffAccounts() {
    final raw = _staffRaw;
    if (raw == null) return null;
    return [for (final s in raw) _staffAccountFrom(s as Map<String, dynamic>)];
  }

  StaffAccount _staffAccountFrom(Map<String, dynamic> s) {
    final name = (s['name'] as String?) ?? 'Staff';
    final roleStr = (s['role'] as String?) ?? 'staff';
    return StaffAccount(
      id: (s['id'] as String?) ?? '',
      name: name,
      initials: _initials(name),
      // May be a synthetic `fb-...` placeholder for Firebase-bootstrapped
      // accounts that never set a real phone — displayed as-is.
      phone: (s['phone'] as String?) ?? '—',
      role: roleStr == 'owner' ? AdminRole.owner : AdminRole.staff,
      status: s['active'] == true ? StaffStatus.active : StaffStatus.suspended,
      lastActive: _formatCreatedAt(s['createdAt'] as String?),
    );
  }

  String _formatCreatedAt(String? raw) {
    final dt = raw == null ? null : DateTime.tryParse(raw);
    if (dt == null) return 'Joined —';
    return 'Joined ${DateFormat('MMM d, yyyy').format(dt.toLocal())}';
  }

  Future<void> _fetchStaffAccounts() async {
    try {
      final token = await _idToken();
      if (token == null) return; // staff-gated — nothing to fetch without one
      final res = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/staff'), headers: _headers(token))
          .timeout(_timeout);
      if (res.statusCode != 200) return _markFailed('staff');
      _staffRaw = jsonDecode(res.body) as List<dynamic>;
      _markSucceeded('staff');
      notifyListeners();
    } catch (_) {
      _markFailed('staff');
    }
  }

  @override
  Future<bool> inviteStaff({
    required String name,
    required String phone,
    required String pin,
    required AdminRole role,
  }) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await _client
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/staff'),
            headers: {'Content-Type': 'application/json', ..._headers(token)},
            body: jsonEncode({
              'name': name,
              'phone': phone,
              'pin': pin,
              'role': role == AdminRole.owner ? 'owner' : 'staff',
            }),
          )
          .timeout(_timeout);
      if (res.statusCode != 201) return false;
      await _fetchStaffAccounts();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setStaffActive(String staffId, bool active) async {
    try {
      final token = await _idToken();
      if (token == null) return false;
      final res = await _client
          .patch(
            Uri.parse('${ApiConfig.baseUrl}/api/staff/$staffId'),
            headers: {'Content-Type': 'application/json', ..._headers(token)},
            body: jsonEncode({'active': active}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      await _fetchStaffAccounts();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ============================================================= REPORTS
  @override
  ReportBundle? report(ReportRange range, {String? district}) {
    _lastReportRange = range;
    _lastReportDistrict = district;
    final key = (range, district);
    final raw = _reportsRaw[key];
    if (raw == null) {
      // Kick off a fetch for whichever (range, district) was just asked for
      // (the week range with no district is already fetched eagerly in the
      // constructor) — at most one in-flight attempt per key at a time.
      if (!_reportsFetching.contains(key)) unawaited(_fetchReport(range, district: district));
      return null;
    }
    return _reportBundleFrom(range, raw);
  }

  ReportBundle _reportBundleFrom(ReportRange range, Map<String, dynamic> raw) {
    final pnl = raw['pnl'] as Map<String, dynamic>?;
    return ReportBundle(
      range: range,
      revenueTrend: _normalizedTrend(
        (raw['revenueTrend'] as List<dynamic>? ?? []),
        valueKey: 'revenue',
      ),
      ratingTrend: _normalizedTrend(
        (raw['ratingTrend'] as List<dynamic>? ?? []),
        valueKey: 'avgRating',
        fixedMax: 5.0,
      ),
      categoryRevenue: [
        for (final c in (raw['revenueByCategory'] as List<dynamic>? ?? []))
          CategoryRevenue(
            (c as Map<String, dynamic>)['category'] as String? ?? '—',
            _asInt(c['revenue']) * 100,
          ),
      ],
      technicianLeaderboard: [
        for (final t in (raw['technicianLeaderboard'] as List<dynamic>? ?? []))
          _technicianRowFrom(t as Map<String, dynamic>),
      ],
      complaintsByStatus: [
        for (final c in (raw['complaintStatusBreakdown'] as List<dynamic>? ?? []))
          ComplaintStatusCount(
            (c as Map<String, dynamic>)['status'] as String? ?? '—',
            _asInt(c['count']),
          ),
      ],
      completedJobs: _asInt(raw['completedJobs']),
      financials: pnl == null ? null : _financialsFrom(pnl),
    );
  }

  TechnicianRow _technicianRowFrom(Map<String, dynamic> t) {
    final name = (t['name'] as String?) ?? 'Technician';
    return TechnicianRow(
      name: name,
      initials: _initials(name),
      jobs: _asInt(t['jobsInPeriod']),
      revenuePaise: _asInt(t['revenueInPeriod']) * 100,
      rating: _asDouble(t['rating']),
    );
  }

  FinancialSummary _financialsFrom(Map<String, dynamic> pnl) => FinancialSummary(
        grossRevenuePaise: _asInt(pnl['grossRevenue']) * 100,
        technicianPayoutEstimatePaise: _asInt(pnl['technicianPayout']) * 100,
        payoutRateAssumed: _asDouble(pnl['payoutRateAssumed']),
      );

  List<TrendPoint> _normalizedTrend(
    List<dynamic> points, {
    required String valueKey,
    double? fixedMax,
  }) {
    if (points.isEmpty) return const [];
    final values = [
      for (final p in points) _asDouble((p as Map<String, dynamic>)[valueKey]),
    ];
    final max = fixedMax ?? values.fold<double>(0, (m, v) => v > m ? v : m);
    return [
      for (var i = 0; i < points.length; i++)
        TrendPoint(
          (points[i] as Map<String, dynamic>)['date'] as String? ?? '',
          max <= 0 ? 0 : (values[i] / max).clamp(0, 1),
        ),
    ];
  }

  Future<void> _fetchReport(ReportRange range, {String? district}) async {
    final key = (range, district);
    _reportsFetching.add(key);
    try {
      final token = await _idToken();
      if (token == null) return; // staff-gated — nothing to fetch without one
      final period = switch (range) {
        ReportRange.week => 'week',
        ReportRange.month => 'month',
        ReportRange.quarter => 'quarter',
      };
      final areaQuery = district == null ? '' : '&area=${Uri.encodeQueryComponent(district)}';
      final res = await _client
          .get(
            Uri.parse('${ApiConfig.baseUrl}/api/stats/reports?period=$period$areaQuery'),
            headers: _headers(token),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return;
      _reportsRaw[key] = jsonDecode(res.body) as Map<String, dynamic>;
      notifyListeners();
    } catch (_) {
      // keep null
    } finally {
      _reportsFetching.remove(key);
    }
  }

  // ================================================================ UTIL
  Future<String?> _idToken() async {
    try {
      return await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _headers(String? token) => {
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// URL + headers for a technician's KYC document image — see
  /// GET /api/technicians/<id>/document/<kind> in app.py. The response no
  /// longer includes the raw Firebase Storage URL (technician_row_to_dict
  /// redacts it for staff-scoped requests), so team_screen fetches the
  /// image bytes through this authenticated proxy instead of a plain,
  /// non-expiring Image.network(url).
  String documentUrl(String technicianId, String kind) =>
      '${ApiConfig.baseUrl}/api/technicians/$technicianId/document/$kind';

  Future<Map<String, String>> documentHeaders() async => _headers(await _idToken());

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  int _asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  double _asDouble(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  @override
  void dispose() {
    _authSub?.cancel();
    _client.close();
    super.dispose();
  }
}
