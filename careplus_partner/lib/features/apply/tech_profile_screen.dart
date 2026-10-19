// The technician's own view of who they are — photo, name, verification
// status, and career stats. Account-level actions (job history, financial
// details, help, sign out) live in the separate "More" tab, matching how
// Swiggy/Urban Company Partner apps split identity from the menu instead
// of bundling both into one screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/care_widgets.dart';
import '../../l10n/l10n_extensions.dart';
import '../../state/auth_providers.dart';

class TechProfileScreen extends ConsumerStatefulWidget {
  const TechProfileScreen({super.key});
  @override
  ConsumerState<TechProfileScreen> createState() => _TechProfileScreenState();
}

class _TechProfileScreenState extends ConsumerState<TechProfileScreen> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // The profile used to depend on the jobs screen having fetched it first;
    // load our own data when it isn't there yet.
    if (ref.read(technicianMeProvider) == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    final me = await ref.read(technicianMeLoaderProvider)();
    if (!mounted) return;
    if (me != null) ref.read(technicianMeProvider.notifier).state = me;
    setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(technicianMeProvider);
    final verified = me?['verified'] == true;
    final t = context.l10n;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow(t.profileEyebrow),
                        const SizedBox(height: 3),
                        Text(t.profileTitle, style: context.type.titleMedium),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _refreshing ? null : _refresh,
                    icon: _refreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Expanded(
              child: me == null && _refreshing
                  ? const Center(child: CircularProgressIndicator())
                  : me == null
                  ? Center(
                      child: Text(
                        lastTechnicianMeStatus == null
                            ? t.profileLoadError
                            : '${t.profileLoadError} (HTTP $lastTechnicianMeStatus)',
                        style: context.type.bodyMedium,
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      children: [
                        Center(
                          child: CircleAvatar(
                            radius: 44,
                            backgroundColor:
                                context.scheme.surfaceContainerHigh,
                            backgroundImage: (me['photoUrl'] as String?) != null
                                ? NetworkImage(me['photoUrl'] as String)
                                : null,
                            child: (me['photoUrl'] as String?) == null
                                ? Icon(
                                    Icons.person_outline,
                                    color: context.care.inkFaint,
                                    size: 34,
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            (me['name'] as String?) ?? t.profileFallbackName,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Center(
                          child: StatusChip(
                            verified ? t.profileVerified : t.profileAwaitingReview,
                            tone: verified
                                ? ChipTone.success
                                : ChipTone.warning,
                          ),
                        ),
                        if (verified && (me['partnerCode'] as String?) != null) ...[
                          const SizedBox(height: 8),
                          Center(
                            child: Text(
                              t.profilePartnerCode(me['partnerCode'] as String),
                              style: context.type.bodySmall!
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        CareCard(
                          child: Row(
                            children: [
                              Expanded(
                                child: _stat(
                                  context,
                                  '★ ${me['rating'] ?? '—'}',
                                  t.profileRating,
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 30,
                                color: context.care.hairline,
                              ),
                              Expanded(
                                child: _stat(
                                  context,
                                  '${me['jobsCompleted'] ?? 0}',
                                  t.profileJobsDone,
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 30,
                                color: context.care.hairline,
                              ),
                              Expanded(
                                child: _stat(
                                  context,
                                  me['experienceYears'] != null
                                      ? '${me['experienceYears']}y'
                                      : '—',
                                  t.profileExperience,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () async {
                              await context.push('/tech/apply', extra: me);
                            },
                            child: Text(t.commonEditProfile),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 3),
      Text(label, style: context.type.bodySmall),
    ],
  );
}
