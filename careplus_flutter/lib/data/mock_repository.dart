// The repository interface is the seam between the app and its backend.
//
// Every screen depends on [CareRepository], never on a data source directly.
// [MockRepository] serves canned data so the app runs with no backend. To go
// live, write a FirestoreRepository that implements the same interface and
// swap the provider in lib/state/providers.dart — no screen changes.

import 'dart:async';
import 'models.dart';

abstract interface class CareRepository {
  List<ServiceItem> servicesFor(Appliance a);
  List<ServiceItem> catalog();
  List<Issue> issuesFor(Appliance a);
  ApplianceDetail applianceDetail(Appliance a);
  List<SavedAddress> addresses();
  List<PaymentMethod> paymentMethods();
  List<Booking> bookings({BookingStatus? status, bool completed = false});

  /// Look up a single booking (active or completed) by id, or null if it
  /// isn't in the currently loaded set. Used by the tracking screen to
  /// resolve the assigned technician's id for live location lookups — see
  /// TrackingScreen in lib/features/tracking/tracking_screen.dart.
  Booking? bookingById(String id);
  Technician get preferredTechnician;

  /// Simulated tracking feed. Emits an ETA (minutes) that counts down, so the
  /// tracking screen has something live to animate. Firestore version streams
  /// technicians/{id}/locations/live instead.
  Stream<int> etaStream(String bookingId);
}

class MockRepository implements CareRepository {
  static const _sandeep = Technician(
    id: 't_sandeep',
    name: 'Sandeep Pawar',
    initials: 'SP',
    rating: 4.94,
    jobsDone: 1860,
    years: 6,
    vehicle: 'MH15 CJ 8842',
  );

  @override
  Technician get preferredTechnician => _sandeep;

  @override
  List<ServiceItem> servicesFor(Appliance a) => switch (a) {
        Appliance.chimney => [
            ServiceItem(
              id: 'svc_chimney_deep_clean_full',
              appliance: a,
              title: 'Deep clean — filters, motor, duct',
              blurb: 'Degreasing bath for baffle filters, blower and oil collector · 90 min',
              pricePaise: 159900,
              durationMin: 90,
              mostBooked: true,
              included: const [
                'Baffle or mesh filters soaked and scrubbed',
                'Blower wheel and motor housing degreased',
                'Oil collector emptied and washed',
                'Duct checked for blockage and leak',
                'Suction reading before and after, logged in app',
                'Floor sheeting and full cleanup',
              ],
              notIncluded: 'Replacement filters, motor rewinding, control boards and duct '
                  'extensions beyond 6 ft. Quoted in the app before work starts.',
              requirements: const [
                'Bucket & water',
                'Power point nearby',
                'Ladder or stool',
              ],
            ),
            ServiceItem(
              id: 'svc_chimney_filter_clean',
              appliance: a,
              title: 'Normal filter clean',
              blurb: 'Baffle or mesh filters degreased and refitted · 30 min',
              pricePaise: 89900,
              durationMin: 30,
              included: const [
                'Baffle or mesh filters removed and degreased',
                'Filters rinsed, dried and refitted',
                'Quick suction check after refitting',
              ],
              notIncluded: 'Motor, blower, duct and oil-collector cleaning — see Deep clean '
                  'for the full service.',
            ),
            ServiceItem(
              id: 'svc_chimney_repair_visit',
              appliance: a,
              title: 'Repair visit and diagnosis',
              blurb: 'Fee waived if you approve the repair quote · parts extra',
              pricePaise: 39900,
              durationMin: 45,
              included: const [
                'Full diagnostic of suction, motor and electronics',
                'Fault identified and quoted before anything is opened',
                'Minor adjustments — belt tension, loose mounts — included',
                'Written report logged in the app',
              ],
              notIncluded: 'Replacement parts (motor, PCB, capacitor) — quoted separately '
                  'and fitted only after your approval.',
            ),
            ServiceItem(
              id: 'svc_chimney_install',
              appliance: a,
              title: 'Installation with duct work',
              blurb: 'Wall or island mount, up to 6 ft of ducting included',
              pricePaise: 169900,
              durationMin: 120,
              included: const [
                'Wall or island mounting hardware and bracket fitting',
                'Up to 6 ft of ducting connected and sealed',
                'Suction tested after fitting',
              ],
              notIncluded: 'Ducting beyond 6 ft, false-ceiling cutting and electrical '
                  'point extension.',
            ),
            ServiceItem(
              id: 'svc_chimney_uninstall',
              appliance: a,
              title: 'Uninstall and shift',
              blurb: 'Safe removal, capping and packing for a move',
              pricePaise: 59900,
              durationMin: 60,
              included: const [
                'Safe disconnection of power and ducting',
                'Chimney body wrapped and packed for transport',
                'Duct capped to prevent drafts',
              ],
              notIncluded: 'Wall or ceiling patch-up and repainting after removal.',
            ),
          ],
        Appliance.hob => [
            ServiceItem(
              id: 'svc_hob_deep_clean_full',
              appliance: a,
              title: 'Deep clean — burners, valves, igniters',
              blurb: 'Ultrasonic bath for burner caps, igniter contacts tested · 60 min',
              pricePaise: 79900,
              durationMin: 60,
              mostBooked: true,
              included: const [
                'Burner caps and pan supports soaked and scrubbed',
                'Igniter contacts cleaned and tested',
                'Gas valve and knob action checked',
                'Flame colour and evenness verified',
                'Leak test on every joint',
                'Countertop wiped and degreased',
              ],
              notIncluded: 'Burner replacement, valve rebuilds and glass-top panels. '
                  'Quoted in the app before work starts.',
            ),
            ServiceItem(
              id: 'svc_hob_repair_visit',
              appliance: a,
              title: 'Repair visit and diagnosis',
              blurb: 'Fee waived if you approve the repair quote · parts extra',
              pricePaise: 39900,
              durationMin: 45,
              included: const [
                'Igniter, valve and burner diagnosis',
                'Leak check on every joint',
                'Minor cleaning and adjustment included',
                'Written fault report',
              ],
              notIncluded: 'Replacement igniters, valves or burner caps — quoted and '
                  'fitted only after approval.',
            ),
            ServiceItem(
              id: 'svc_hob_install',
              appliance: a,
              title: 'Installation with gas line check',
              blurb: 'Countertop or built-in mount, leak-tested on every joint',
              pricePaise: 69900,
              durationMin: 75,
              included: const [
                'Countertop or built-in mounting',
                'Gas line connection, every joint leak-tested',
                'Flame test on every burner after fitting',
              ],
              notIncluded: 'New gas line runs, cutout enlargement and regulator '
                  'replacement.',
            ),
            ServiceItem(
              id: 'svc_hob_uninstall',
              appliance: a,
              title: 'Uninstall and cap the line',
              blurb: 'Safe gas disconnection and capping for a move',
              pricePaise: 39900,
              durationMin: 45,
              included: const [
                'Safe gas disconnection',
                'Line capped to prevent leaks',
                'Hob wrapped and packed for transport',
              ],
              notIncluded: 'Countertop patch-up after removal.',
            ),
          ],
        Appliance.cooktop => [
            ServiceItem(
              id: 'svc_cooktop_deep_clean_full',
              appliance: a,
              title: 'Deep clean and calibration',
              blurb: 'Glass surface polish, sensor and touch panel check · 50 min',
              pricePaise: 49900,
              durationMin: 50,
              mostBooked: true,
              included: const [
                'Glass surface polished and checked for cracks',
                'Induction coil and sensor tested',
                'Touch panel calibrated',
                'Ventilation checked for overheating',
                'Power draw tested under load',
                'Countertop wiped and degreased',
              ],
              notIncluded: 'Glass-top replacement, coil rewinding and control boards. '
                  'Quoted before work starts.',
            ),
            ServiceItem(
              id: 'svc_cooktop_repair_visit',
              appliance: a,
              title: 'Repair visit and diagnosis',
              blurb: 'Fee waived if you approve the repair quote · parts extra',
              pricePaise: 39900,
              durationMin: 45,
              included: const [
                'Induction coil, sensor and control-panel diagnosis',
                'Error code read out and explained',
                'Minor recalibration included',
              ],
              notIncluded: 'Replacement glass top, coil or control board — quoted and '
                  'fitted only after approval.',
            ),
            ServiceItem(
              id: 'svc_cooktop_install',
              appliance: a,
              title: 'Installation and panel fitting',
              blurb: 'Countertop cutout fitting and power point check',
              pricePaise: 39900,
              durationMin: 60,
              included: const [
                'Countertop cutout fitting',
                'Power point and load check',
                'Panel calibrated after fitting',
              ],
              notIncluded: 'Countertop cutting/enlargement and new power point wiring.',
            ),
            ServiceItem(
              id: 'svc_cooktop_uninstall',
              appliance: a,
              title: 'Uninstall and pack for a move',
              blurb: 'Safe removal and packing, glass surface protected',
              pricePaise: 29900,
              durationMin: 40,
              included: const [
                'Safe removal with glass surface protected',
                'Power disconnected and capped',
                'Packed for transport',
              ],
              notIncluded: 'Countertop patch-up after removal.',
            ),
          ],
        Appliance.dishwasher => [
            ServiceItem(
              id: 'svc_dishwasher_deep_clean_full',
              appliance: a,
              title: 'Deep clean — filter, spray arms, seals',
              blurb: 'Filter basket, spray arms and door seals descaled · 75 min',
              pricePaise: 119900,
              durationMin: 75,
              mostBooked: true,
              included: const [
                'Filter basket and sump cleaned',
                'Spray arms unclogged and tested',
                'Door seals inspected for leaks',
                'Drain pump and hose checked',
                'A full cycle run and verified',
                'Interior wiped down',
              ],
              notIncluded: 'Drain pump replacement, control boards and door seal kits. '
                  'Quoted before work starts.',
            ),
            ServiceItem(
              id: 'svc_dishwasher_repair_visit',
              appliance: a,
              title: 'Repair visit and diagnosis',
              blurb: 'Fee waived if you approve the repair quote · parts extra',
              pricePaise: 59900,
              durationMin: 45,
              included: const [
                'Drain pump, spray arm and control-board diagnosis',
                'A full test cycle to confirm the fault',
                'Written report before any part is quoted',
              ],
              notIncluded: 'Replacement pump, control board or seal kit — fitted only '
                  'after your approval.',
            ),
            ServiceItem(
              id: 'svc_dishwasher_install',
              appliance: a,
              title: 'Installation and plumbing connection',
              blurb: 'Water inlet, drain hose and levelling included',
              pricePaise: 149900,
              durationMin: 90,
              included: const [
                'Water inlet, drain hose and levelling',
                'First cycle run to confirm no leaks',
              ],
              notIncluded: 'New plumbing points and cabinet modification.',
            ),
            ServiceItem(
              id: 'svc_dishwasher_uninstall',
              appliance: a,
              title: 'Uninstall and cap the lines',
              blurb: 'Safe disconnection and capping for a move',
              pricePaise: 59900,
              durationMin: 60,
              included: const [
                'Safe disconnection of water and drain lines',
                'Lines capped',
                'Unit packed for transport',
              ],
              notIncluded: 'Plumbing patch-up after removal.',
            ),
          ],
        Appliance.microwave => [
            ServiceItem(
              id: 'svc_microwave_deep_clean_full',
              appliance: a,
              title: 'Deep clean and safety check',
              blurb: 'Interior degrease, door switch and leakage test · 45 min',
              pricePaise: 54900,
              durationMin: 45,
              mostBooked: true,
              included: const [
                'Interior cavity deep cleaned',
                'Door seal and switch tested',
                'Turntable motor and roller checked',
                'Magnetron leakage safety tested',
                'Control panel and display verified',
                'Vent and housing wiped down',
              ],
              notIncluded: 'Magnetron replacement and control board repairs. Quoted '
                  'before work starts.',
            ),
            ServiceItem(
              id: 'svc_microwave_repair_visit',
              appliance: a,
              title: 'Repair visit and diagnosis',
              blurb: 'Fee waived if you approve the repair quote · parts extra',
              pricePaise: 39900,
              durationMin: 45,
              included: const [
                'Magnetron, door switch and control-panel diagnosis',
                'Leakage safety test included',
                'Written fault report',
              ],
              notIncluded: 'Replacement magnetron or control board — quoted and fitted '
                  'only after approval.',
            ),
            ServiceItem(
              id: 'svc_microwave_install',
              appliance: a,
              title: 'Built-in installation and trim kit',
              blurb: 'Cabinet mount, trim kit and vent check',
              pricePaise: 99900,
              durationMin: 75,
              included: const [
                'Cabinet mount and trim kit fitting',
                'Vent check',
                'Test run to confirm heating',
              ],
              notIncluded: 'Cabinet cutout modification and new power point.',
            ),
            ServiceItem(
              id: 'svc_microwave_uninstall',
              appliance: a,
              title: 'Uninstall and cap the housing',
              blurb: 'Safe removal and packing for a move',
              pricePaise: 59900,
              durationMin: 45,
              included: const [
                'Safe removal from housing',
                'Packed for transport',
                'Housing left clean',
              ],
              notIncluded: 'Cabinet patch-up after removal.',
            ),
          ],
        Appliance.otg => [
            ServiceItem(
              id: 'svc_otg_deep_clean_full',
              appliance: a,
              title: 'Deep clean and element check',
              blurb: 'Interior degrease and heating element inspection · 40 min',
              pricePaise: 54900,
              durationMin: 40,
              mostBooked: true,
              included: const [
                'Heating elements inspected and cleaned',
                'Thermostat accuracy tested',
                'Timer and knob action checked',
                'Interior cavity degreased',
                'Door seal and glass checked',
                'Test bake run and verified',
              ],
              notIncluded: 'Heating element replacement and thermostat swaps. Quoted '
                  'before work starts.',
            ),
            ServiceItem(
              id: 'svc_otg_repair_visit',
              appliance: a,
              title: 'Repair visit and diagnosis',
              blurb: 'Fee waived if you approve the repair quote · parts extra',
              pricePaise: 39900,
              durationMin: 45,
              included: const [
                'Heating element and thermostat diagnosis',
                'Test bake to confirm even heating',
                'Written fault report',
              ],
              notIncluded: 'Replacement heating element or thermostat — quoted and '
                  'fitted only after approval.',
            ),
            ServiceItem(
              id: 'svc_otg_install',
              appliance: a,
              title: 'Installation and test bake',
              blurb: 'Placement, wiring check and a verified test bake',
              pricePaise: 99900,
              durationMin: 60,
              included: const [
                'Placement and wiring check',
                'A verified test bake',
              ],
              notIncluded: 'New power point and cabinet modification.',
            ),
            ServiceItem(
              id: 'svc_otg_uninstall',
              appliance: a,
              title: 'Uninstall and pack for a move',
              blurb: 'Safe removal and packing for a move',
              pricePaise: 59900,
              durationMin: 45,
              included: const [
                'Safe disconnection',
                'Packed for a move',
              ],
              notIncluded: 'Wall or counter patch-up after removal.',
            ),
          ],
        Appliance.refrigerator || Appliance.purifier => const [],
      };

  @override
  List<ServiceItem> catalog() {
    final items = <ServiceItem>[];
    for (final a in Appliance.values) {
      final services = servicesFor(a);
      if (services.isNotEmpty) items.add(services.first);
    }
    return items;
  }

  @override
  List<Issue> issuesFor(Appliance a) => switch (a) {
        Appliance.chimney => const [
            Issue('Weak or no suction', 'Most common on 2+ year old units', selected: true),
            Issue('Oil dripping from the hood', 'Collector or filter saturation', selected: true),
            Issue('Loud or rattling motor', 'Blower imbalance or loose mount', selected: true),
            Issue('Auto-clean not working', 'Heating coil or timer fault'),
            Issue('Lights not turning on', 'LED or switch failure'),
            Issue('Not switching on at all', 'Power, PCB or capacitor'),
          ],
        Appliance.hob => const [
            Issue('Igniter not sparking', 'Most common on 2+ year old units', selected: true),
            Issue('Flame is weak or uneven', 'Burner clogged or valve issue', selected: true),
            Issue('Gas smell near the knob', 'Valve seal or connection fault', selected: true),
            Issue('Burner won\'t light at all', 'Igniter or gas supply issue'),
            Issue('Knob is loose or stuck', 'Valve mechanism worn'),
            Issue('Auto-ignition clicking non-stop', 'Igniter switch fault'),
          ],
        Appliance.cooktop => const [
            Issue('Not heating at all', 'Power or induction coil fault', selected: true),
            Issue('Error code on display', 'Sensor or control board issue', selected: true),
            Issue('Touch panel not responding', 'Panel calibration or moisture', selected: true),
            Issue('Cracked or scratched glass', 'Surface damage'),
            Issue('Overheating or shuts off', 'Ventilation or sensor fault'),
            Issue('Uneven heating', 'Coil or zone fault'),
          ],
        Appliance.dishwasher => const [
            Issue('Not draining properly', 'Pump or filter blockage', selected: true),
            Issue('Dishes not coming out clean', 'Spray arm or filter clog', selected: true),
            Issue('Error code on display', 'Sensor or control fault', selected: true),
            Issue('Leaking from the door', 'Seal or gasket worn'),
            Issue('Making loud noise during cycle', 'Pump or motor issue'),
            Issue('Not starting at all', 'Power or door latch fault'),
          ],
        Appliance.microwave => const [
            Issue('Not heating food', 'Magnetron fault', selected: true),
            Issue('Turntable not spinning', 'Motor or roller worn', selected: true),
            Issue('Sparking inside', 'Metal object or panel damage', selected: true),
            Issue('Door not closing properly', 'Hinge or switch fault'),
            Issue('Display or buttons not working', 'Control panel fault'),
            Issue('Unusual smell or noise', 'Component wear'),
          ],
        Appliance.otg => const [
            Issue('Not heating properly', 'Element or thermostat fault', selected: true),
            Issue('Uneven baking', 'Heating element issue', selected: true),
            Issue('Timer not working', 'Timer mechanism fault', selected: true),
            Issue('Door glass loose or cracked', 'Hinge or glass damage'),
            Issue('Knobs stiff or not turning', 'Mechanism worn'),
            Issue('Not switching on at all', 'Power or wiring fault'),
          ],
        Appliance.refrigerator || Appliance.purifier => const [],
      };

  @override
  ApplianceDetail applianceDetail(Appliance a) => switch (a) {
        Appliance.chimney => const ApplianceDetail(
            heading: 'Chimney care',
            blurb:
                'Suction loss, oil dripping, loud motor, auto-clean failure — diagnosed and fixed by technicians trained on Elica, Faber, Hindware, Glen and Bosch units.',
          ),
        Appliance.hob => const ApplianceDetail(
            heading: 'Hob care',
            blurb:
                'Igniter failure, low or uneven flame, burner clogging, knob and valve faults — fixed by technicians trained on Elica, Prestige, Sunflame, Faber and Bosch hobs.',
          ),
        Appliance.cooktop => const ApplianceDetail(
            heading: 'Cooktop care',
            blurb:
                'Induction coil faults, glass-top cracks, touch panel errors and sensor issues — diagnosed and repaired on all major induction and radiant cooktop brands.',
          ),
        Appliance.dishwasher => const ApplianceDetail(
            heading: 'Dishwasher care',
            blurb:
                'Not draining, not cleaning properly, error codes and noisy cycles — fixed by technicians trained on Bosch, Siemens, IFB and LG dishwashers.',
          ),
        Appliance.microwave => const ApplianceDetail(
            heading: 'Microwave care',
            blurb:
                'Magnetron faults, turntable not spinning, door switch failures and control panel issues — fixed on all major built-in and OTR microwave brands.',
          ),
        Appliance.otg => const ApplianceDetail(
            heading: 'OTG care',
            blurb:
                'Heating element failure, thermostat drift and timer faults — diagnosed and fixed on all major oven-toaster-griller brands.',
          ),
        Appliance.refrigerator => const ApplianceDetail(
            heading: 'Refrigerator care',
            blurb:
                'We\'re still training and certifying technicians on refrigerator repair. Booking will open here shortly.',
            comingSoon: true,
          ),
        Appliance.purifier => const ApplianceDetail(
            heading: 'Purifier care',
            blurb:
                'We\'re still training and certifying technicians on RO and UV/UF purifier service. Booking will open here shortly.',
            comingSoon: true,
          ),
      };

  // No canned demo addresses — a real customer's saved addresses come from
  // their profile (the one collected at signup) and whatever they've picked
  // on the map during booking. See savedAddressesProvider in
  // lib/state/providers.dart, which is what screens actually watch.
  @override
  List<SavedAddress> addresses() => const [];

  // Purely a display list for the checkout "Pay with" selector — see
  // PaymentMethod's doc comment. "cod" reads "UPI to technician" only
  // (no cash), matching an earlier explicit request to drop cash as an
  // option once payment collection became visibly UPI-only.
  @override
  List<PaymentMethod> paymentMethods() => const [
        PaymentMethod('cod', 'Pay after the visit', 'UPI to technician', '₹',
            section: 'Pay on delivery'),
        PaymentMethod('upi_gpay', 'Google Pay', 'Pay by UPI', '▲', section: 'UPI apps'),
        PaymentMethod('upi_phonepe', 'PhonePe', 'Pay by UPI', '▲', section: 'UPI apps'),
        PaymentMethod('upi_paytm', 'Paytm', 'Pay by UPI', '▲', section: 'UPI apps'),
        PaymentMethod('card', 'Add a card', 'Credit or debit', '▭',
            section: 'Credit & debit cards'),
        PaymentMethod('netbank', 'Net banking', '12+ banks', '▤', section: 'More options'),
        PaymentMethod('wallet', 'Wallets', 'PhonePe, Amazon Pay & more', '◍',
            section: 'More options'),
      ];

  @override
  List<Booking> bookings({BookingStatus? status, bool completed = false}) {
    final all = <Booking>[
      Booking(
        id: 'CP-2481-NSK',
        title: 'Chimney deep clean',
        appliance: Appliance.chimney,
        status: BookingStatus.onTheWay,
        whenLabel: 'Today · 10:00–11:00 am · Home',
        addressLabel: 'Home',
        totalPaise: 80000,
        technician: _sandeep,
      ),
      const Booking(
        id: 'CP-2496-NSK',
        title: 'RO purifier — filter change',
        appliance: Appliance.purifier,
        status: BookingStatus.scheduled,
        whenLabel: '02 Aug · 4:00–6:00 pm · Parents',
        addressLabel: 'Parents',
        totalPaise: 129900,
      ),
      const Booking(
        id: 'CP-2109-NSK',
        title: 'Dishwasher — drain pump',
        appliance: Appliance.dishwasher,
        status: BookingStatus.completed,
        whenLabel: '12 Jun · Home',
        addressLabel: 'Home',
        totalPaise: 324000,
        stars: 5,
      ),
      const Booking(
        id: 'CP-1884-NSK',
        title: 'Chimney deep clean',
        appliance: Appliance.chimney,
        status: BookingStatus.completed,
        whenLabel: '12 Feb · Home',
        addressLabel: 'Home',
        totalPaise: 89900,
        stars: 5,
      ),
    ];
    if (completed) {
      return all.where((b) => b.status == BookingStatus.completed).toList();
    }
    return all
        .where((b) => b.status != BookingStatus.completed)
        .where((b) => status == null || b.status == status)
        .toList();
  }

  @override
  Booking? bookingById(String id) {
    for (final b in [...bookings(), ...bookings(completed: true)]) {
      if (b.id == id) return b;
    }
    return null;
  }

  @override
  Stream<int> etaStream(String bookingId) async* {
    var eta = 14;
    yield eta;
    while (eta > 0) {
      await Future<void>.delayed(const Duration(seconds: 4));
      eta -= 1;
      yield eta;
    }
  }

}
