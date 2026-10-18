// Domain models for Rasoi Care Admin — the owner/staff-facing operations and
// analytics app. Every field here is backed by a real column or a real
// aggregation query in app.py/database.py at the repo root — there is no
// mock/demo data source behind this app any more (see api_repository.dart's
// header). A metric with no real backend source (SLA targets, first-time-fix
// tracking, customer segmentation, payment-method mix, coupon usage) has no
// model field for it — better to leave it off the screen than show an
// invented number.
//
// Money is stored in paise (integer) everywhere and only formatted at the
// edge. See [Money] for the formatter.

import 'package:intl/intl.dart';

/// Indian-locale currency, from paise. `Money.rupees(89900) == '₹899'`.
abstract final class Money {
  static final _fmt = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
  static String rupees(int paise) => _fmt.format(paise / 100);

  static final _fmtDec = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
  static String rupeesDecimal(int paise) => _fmtDec.format(paise / 100);
}

/// Owner sees financials and staff management; Staff gets operations only.
/// This is only ever set from the real role the backend's `/api/staff`
/// tables assigns — see StaffBootstrapService.
enum AdminRole { owner, staff }

extension AdminRoleX on AdminRole {
  String get label => this == AdminRole.owner ? 'Owner' : 'Staff member';
}

enum LineTone { neutral, success }

// ============================================================ OVERVIEW
/// A single item on the "needs attention" list — derived from real
/// unassigned bookings and open complaints, not a canned list.
class AttentionItem {
  const AttentionItem({
    required this.jobId,
    required this.title,
    required this.detail,
    required this.tone,
    this.isComplaint = false,
  });
  final String jobId;
  final String title;
  final String detail;
  final LineTone tone;
  final bool isComplaint;
}

/// Cluster-wide KPIs for the overview tab.
class AdminOverview {
  const AdminOverview({
    required this.revenuePaise,
    required this.completedJobs,
    required this.openComplaints,
    required this.avgRating,
    required this.ratingCount,
    required this.weekBars,
    required this.weekLabels,
    required this.technicianUtilisationPct,
    required this.attention,
  });
  final int revenuePaise;
  final int completedJobs;
  final int openComplaints;
  final double avgRating;
  final int ratingCount;
  final List<int> weekBars; // 0..100, one per of the last 7 calendar days
  final List<String> weekLabels;
  final int technicianUtilisationPct;
  final List<AttentionItem> attention;
}

// ============================================================ BOOKINGS
enum BookingCategory { unassigned, inProgress, closed }

/// One row in the admin bookings queue.
class AdminBooking {
  const AdminBooking({
    required this.jobId,
    required this.title,
    required this.meta,
    required this.statusLabel,
    required this.category,
    required this.totalPaise,
    this.createdAt,
    this.area,
    this.customerName,
    this.directions,
    this.technicianName,
  });
  final String jobId;
  final String title;
  final String meta;
  final String statusLabel;
  final BookingCategory category;
  final int totalPaise;
  final DateTime? createdAt;
  final String? area;
  final String? customerName;
  final String? directions;
  final String? technicianName;
}

// ============================================================ TEAM
enum DutyStatus { onJob, idle, offDuty }

/// One technician on the roster tab.
class AdminTeamMember {
  const AdminTeamMember({
    required this.name,
    required this.initials,
    required this.specialties,
    required this.statsLabel,
    required this.rating,
    required this.duty,
    this.id,
    this.area,
    this.verified = true,
    this.applicationSubmitted = true,
    this.photoUrl,
    this.experienceYears,
    this.idDocumentUrl,
    this.bankAccountName,
    this.bankAccountNumber,
    this.bankIfsc,
    this.categories = const [],
    this.aadharDocumentUrl,
    this.aadharDocumentBackUrl,
    this.panDocumentUrl,
    this.bankPassbookUrl,
    this.aadharDocumentReady = false,
    this.aadharDocumentBackReady = false,
    this.panDocumentReady = false,
    this.bankPassbookReady = false,
    this.partnerCode,
    this.employmentType,
  });
  final String name;
  final String initials;
  final String specialties;
  final String statsLabel;
  final double rating;
  final DutyStatus duty;
  final String? id;
  final String? area;
  final bool verified;
  final bool applicationSubmitted;
  final String? photoUrl;
  final int? experienceYears;
  final String? idDocumentUrl;
  final String? bankAccountName;
  final String? bankAccountNumber;
  final String? bankIfsc;
  final List<String> categories;
  final String? aadharDocumentUrl;
  final String? aadharDocumentBackUrl;
  final String? panDocumentUrl;
  final String? bankPassbookUrl;
  // Whether a document was ever uploaded, independent of whether the raw
  // URL above is present — the staff-scoped GET /api/technicians response
  // redacts the URLs themselves (see technician_row_to_dict), so these are
  // what "missing document" warnings actually check now.
  final bool aadharDocumentReady;
  final bool aadharDocumentBackReady;
  final bool panDocumentReady;
  final bool bankPassbookReady;
  final String? partnerCode;

  /// 'payroll' or 'outsourced' — self-declared once by the technician at
  /// KYC/onboarding and never editable afterward, not even here. Drives
  /// which commission formula their earnings are computed with; see
  /// TechnicianEarnings.
  final String? employmentType;
}

/// One real, auto-computed addition to a technician's pay — a milestone
/// incentive (positive amount) or a late-arrival fine (negative), see
/// app.py's advance_booking. Never a manual admin entry.
class TechnicianLedgerEntry {
  const TechnicianLedgerEntry({
    required this.id,
    required this.kind,
    required this.amountPaise,
    required this.reason,
    this.bookingId,
    this.createdAt,
  });
  final String id;

  /// 'incentive' or 'fine'.
  final String kind;
  final int amountPaise;
  final String reason;
  final String? bookingId;
  final DateTime? createdAt;

  bool get isIncentive => kind == 'incentive';
}

/// A technician's real, commission-based earnings — see
/// GET /api/technicians/<id>/earnings and compute_commission_paise in
/// app.py. Shown read-only in the Team detail sheet so an admin can review
/// a payout before running it; nothing here is editable.
class TechnicianEarnings {
  const TechnicianEarnings({
    required this.employmentType,
    required this.commissionRate,
    required this.commissionTotalPaise,
    required this.ledger,
    required this.incentiveTotalPaise,
    required this.fineTotalPaise,
    required this.netTotalPaise,
  });
  final String employmentType;
  final double commissionRate;
  final int commissionTotalPaise;
  final List<TechnicianLedgerEntry> ledger;
  final int incentiveTotalPaise;
  final int fineTotalPaise;
  final int netTotalPaise;

  List<TechnicianLedgerEntry> get incentives =>
      ledger.where((e) => e.isIncentive).toList(growable: false);
  List<TechnicianLedgerEntry> get fines =>
      ledger.where((e) => !e.isIncentive).toList(growable: false);
}

/// The backend only tracks active/suspended — there's no "invited" state
/// (an invite just creates an already-active account with a PIN).
enum StaffStatus { active, suspended }

/// A back-office staff account (owner-only "Staff & access" screen) — not a
/// field technician, but someone who signs into this app.
class StaffAccount {
  const StaffAccount({
    required this.id,
    required this.name,
    required this.initials,
    required this.phone,
    required this.role,
    required this.status,
    required this.lastActive,
  });
  final String id;
  final String name;
  final String initials;
  final String phone;
  final AdminRole role;
  final StaffStatus status;
  final String lastActive;
}

// ============================================================ STOCK
/// One SKU on the stock tab.
class AdminStockItem {
  const AdminStockItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.inStock,
    required this.reorderAt,
    required this.low,
  });
  final String id;
  final String name;
  final String sku;
  final int inStock;
  final int reorderAt;
  final bool low;
  double get fillFraction =>
      reorderAt <= 0 ? (inStock > 0 ? 1 : 0) : (inStock / reorderAt).clamp(0, 1);
}

// ============================================================ REPORTS
enum ReportRange { week, month, quarter }

extension ReportRangeX on ReportRange {
  String get label => switch (this) {
        ReportRange.week => 'This week',
        ReportRange.month => 'This month',
        ReportRange.quarter => 'This quarter',
      };
}

/// One point on a revenue/rating trend line.
class TrendPoint {
  const TrendPoint(this.label, this.value);
  final String label;
  final double value; // pre-normalized 0..1 for the chart
}

/// Revenue and job count for one appliance category, for the mix breakdown.
class CategoryRevenue {
  const CategoryRevenue(this.label, this.revenuePaise);
  final String label;
  final int revenuePaise;
}

/// One row of the technician leaderboard report.
class TechnicianRow {
  const TechnicianRow({
    required this.name,
    required this.initials,
    required this.jobs,
    required this.revenuePaise,
    required this.rating,
  });
  final String name;
  final String initials;
  final int jobs;
  final int revenuePaise;
  final double rating;
}

/// Real complaint counts grouped by status for the selected range (e.g.
/// Open, In review, Resolved) — replaces an earlier invented "complaint
/// reasons" taxonomy the backend never actually tracked.
class ComplaintStatusCount {
  const ComplaintStatusCount(this.status, this.count);
  final String status;
  final int count;
}

/// Owner-only P&L summary for the selected report range. The backend only
/// tracks gross revenue for real; technician payout is an assumed-rate
/// estimate (see app.py's TECH_PAYOUT_RATE) — [payoutRateAssumed] is shown
/// alongside it so it never reads as a real ledger figure. There is no
/// parts-cost, tax, refund, or discount ledger to report — those simply
/// aren't shown, rather than being displayed as an always-zero line.
class FinancialSummary {
  const FinancialSummary({
    required this.grossRevenuePaise,
    required this.technicianPayoutEstimatePaise,
    required this.payoutRateAssumed,
  });
  final int grossRevenuePaise;
  final int technicianPayoutEstimatePaise;
  final double payoutRateAssumed;

  int get netMarginEstimatePaise => grossRevenuePaise - technicianPayoutEstimatePaise;
  double get netMarginPct =>
      grossRevenuePaise == 0 ? 0 : (netMarginEstimatePaise / grossRevenuePaise) * 100;
}

/// Everything the Reports tab needs for one [ReportRange]. [financials] is
/// null for a Staff account (the backend only computes P&L for the Owner
/// role) as well as while it's still loading.
class ReportBundle {
  const ReportBundle({
    required this.range,
    required this.revenueTrend,
    required this.ratingTrend,
    required this.categoryRevenue,
    required this.technicianLeaderboard,
    required this.complaintsByStatus,
    required this.completedJobs,
    this.financials,
  });
  final ReportRange range;
  final List<TrendPoint> revenueTrend;
  final List<TrendPoint> ratingTrend;
  final List<CategoryRevenue> categoryRevenue;
  final List<TechnicianRow> technicianLeaderboard;
  final List<ComplaintStatusCount> complaintsByStatus;
  final int completedJobs;
  final FinancialSummary? financials;
}
