import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../models.dart' show SavedAddress;

/// What AccountScreen shows for the signed-in person. All fields fall back
/// to whatever Firebase Auth itself knows (displayName/email/phoneNumber)
/// when the Firestore doc hasn't caught up yet or a field was never filled
/// in — see [UserProfileService.watchProfile].
class UserProfile {
  const UserProfile({
    required this.name,
    required this.phone,
    required this.email,
    required this.address,
    this.photoUrl,
    this.lat,
    this.lng,
    this.addresses = const [],
  });
  final String name;
  final String phone;
  final String email;
  final String address;
  final String? photoUrl;
  final double? lat;
  final double? lng;

  /// Real saved addresses (Home/Work/Shop/...), each with its own type,
  /// pin code and optional location photo — set through the map picker's
  /// address-details step (AddressDetailsScreen), not registration. Empty
  /// for anyone who's never saved one yet; [address] above (the single
  /// signup-time address) is a separate, older field kept for backward
  /// compatibility with profiles written before this existed.
  final List<SavedAddress> addresses;
}

/// Best-effort profile write-through to Firestore, called once right after
/// someone finishes the "about you" step of registration. Never blocks
/// onboarding: in mock mode (no Firebase project configured yet) or if the
/// write fails for any reason, this is a silent no-op and the person still
/// gets into the app — see RegisterScreen in auth_screens.dart.
class UserProfileService {
  /// True when this Firebase identity already has the minimum customer
  /// profile needed to use the app. A missing or incomplete document routes
  /// the user through registration after sign-in; Firestore failures safely
  /// fall back to that same completion flow.
  Future<bool> hasCompletedProfile() async {
    if (Firebase.apps.isEmpty) return false;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get()
          .timeout(const Duration(seconds: 6));
      final data = snapshot.data();
      if (data == null) return false;
      return (data['name'] as String?)?.trim().isNotEmpty == true &&
          (data['phone'] as String?)?.trim().isNotEmpty == true &&
          (data['address'] as String?)?.trim().isNotEmpty == true;
    } catch (_) {
      return false;
    }
  }

  /// Live view of the signed-in person's profile — null in mock mode or
  /// when nobody's signed in, so AccountScreen knows to show its own demo
  /// fallback instead. Streamed (not a one-off get) so the screen updates
  /// the moment [saveProfile]'s write actually lands, rather than showing
  /// stale/blank fields if it's opened right after registration.
  Stream<UserProfile?> watchProfile() {
    if (Firebase.apps.isEmpty) return Stream.value(null);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return Stream.value(null);
    return FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .map((doc) {
      final data = doc.data();
      return UserProfile(
        name: (data?['name'] as String?)?.trim().isNotEmpty == true
            ? data!['name'] as String
            : (user.displayName ?? ''),
        phone: (data?['phone'] as String?) ?? (user.phoneNumber ?? ''),
        email: (data?['email'] as String?)?.trim().isNotEmpty == true
            ? data!['email'] as String
            : (user.email ?? ''),
        address: (data?['address'] as String?) ?? '',
        photoUrl: data?['photoUrl'] as String?,
        lat: (data?['addressLat'] as num?)?.toDouble(),
        lng: (data?['addressLng'] as num?)?.toDouble(),
        addresses: ((data?['addresses'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SavedAddress.fromMap)
            .whereType<SavedAddress>()
            .toList(),
      );
    });
  }

  /// Uploads a new profile photo to Firebase Storage and saves its URL to
  /// the profile doc. Returns the download URL on success, null on any
  /// failure (mock mode, not signed in, upload error) — the caller keeps
  /// showing the initials-blob fallback in that case rather than a broken
  /// image.
  Future<String?> uploadPhoto(File file) async {
    if (Firebase.apps.isEmpty) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      final ext = file.path.split('.').last;
      final ref = FirebaseStorage.instance.ref('user_profiles/${user.uid}/photo.$ext');
      await ref.putFile(file).timeout(const Duration(seconds: 30));
      final url = await ref.getDownloadURL();
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {'photoUrl': url, 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      ).timeout(const Duration(seconds: 6));
      return url;
    } catch (e) {
      // Swallowed for the UI (which just shows the initials-blob fallback),
      // but logged here because the two most common causes — Storage not
      // enabled for the project, or default "deny all" security rules —
      // are invisible otherwise. Look for this in `flutter logs`/logcat.
      debugPrint('Profile photo upload failed: $e');
      return null;
    }
  }

  /// Sets just the display name — the only field AccountScreen lets someone
  /// edit after the fact (registration's "about you" step sets the rest,
  /// but people who sign in with phone OTP alone never see that step).
  Future<bool> updateName(String name) async {
    if (Firebase.apps.isEmpty) return false;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {'name': name, 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      ).timeout(const Duration(seconds: 6));
      return true;
    } catch (e) {
      debugPrint('Profile name update failed: $e');
      return false;
    }
  }

  /// Sets the phone number shown here — mirrors [updateName]. This is
  /// purely the display copy; the number the cancellation-OTP SMS and the
  /// technician's "Call" action actually use lives on the Flask backend
  /// (see ApiRepository.updatePhone, called alongside this from
  /// AccountScreen so the two stay in sync). Stored in the same +91E.164
  /// shape as a real verified phone-sign-in number, so [_formatIndianPhone]
  /// (account_screens.dart) displays it the same way either way.
  Future<bool> updatePhone(String phone) async {
    if (Firebase.apps.isEmpty) return false;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        {'phone': '+91$phone', 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      ).timeout(const Duration(seconds: 6));
      return true;
    } catch (e) {
      debugPrint('Profile phone update failed: $e');
      return false;
    }
  }

  /// Uploads a photo of a location (not the person) — the "Location
  /// Photos" recommendation on the address-details form, meant to help a
  /// technician recognize the entrance. Same best-effort/never-throw
  /// contract as [uploadPhoto]; returns null on any failure. Kept as a
  /// single path segment directly under `user_profiles/{uid}/` (not a
  /// nested `addresses/...` subpath) so the existing Storage security
  /// rule — written for `user_profiles/{userId}/{fileName}`, one segment
  /// — covers it without needing a console change.
  Future<String?> uploadAddressPhoto(File file, String addressId) async {
    if (Firebase.apps.isEmpty) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      final ext = file.path.split('.').last;
      final ref =
          FirebaseStorage.instance.ref('user_profiles/${user.uid}/address_$addressId.$ext');
      await ref.putFile(file).timeout(const Duration(seconds: 30));
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('Address photo upload failed: $e');
      return null;
    }
  }

  /// Appends a newly confirmed address (from AddressDetailsScreen) to the
  /// real saved-addresses list, so it shows up next time without
  /// re-entering it — this is what backs SelectLocationScreen's "Saved
  /// addresses" section. Best-effort: on failure the address still works
  /// for the booking/pick that just created it, it just won't be there
  /// next time.
  Future<void> addAddress(SavedAddress address) async {
    if (Firebase.apps.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'addresses': FieldValue.arrayUnion([address.toMap()]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('Saving address failed: $e');
    }
  }

  /// Removes one saved address by id — read-modify-write rather than
  /// arrayRemove, since arrayRemove needs an exact map match and the
  /// stored copy may not byte-for-byte equal what the client has.
  Future<bool> deleteAddress(String addressId) async {
    if (Firebase.apps.isEmpty) return false;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      final doc = FirebaseFirestore.instance.collection('users').doc(user.uid);
      final snap = await doc.get().timeout(const Duration(seconds: 6));
      final current = ((snap.data()?['addresses'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      current.removeWhere((m) => m['id'] == addressId);
      await doc.set({'addresses': current, 'updatedAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true)).timeout(const Duration(seconds: 6));
      return true;
    } catch (e) {
      debugPrint('Deleting address failed: $e');
      return false;
    }
  }

  Future<void> saveProfile({
    required String name,
    required String email,
    required String address,
    double? lat,
    double? lng,
    required Set<String> ownedAppliances,
    // Only passed for email/Google sign-ups — phone-OTP sign-in already has
    // a verified number on the Firebase user itself (user.phoneNumber),
    // which this falls back to when null. Ten bare digits, formatted below
    // the same +91E.164 way as a real phone sign-in.
    String? phone,
  }) async {
    if (Firebase.apps.isEmpty) return; // mock mode — nothing to write to
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'name': name,
        'email': email,
        'address': address,
        'addressLat': lat,
        'addressLng': lng,
        'phone': phone != null ? '+91$phone' : user.phoneNumber,
        'ownedAppliances': ownedAppliances.toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 6));
    } catch (_) {
      // Profile is convenience data — a Firestore hiccup (including one
      // that would otherwise hang, e.g. no Firestore database created yet
      // in the console) shouldn't strand someone mid-onboarding. The
      // timeout above turns a silent hang into a catchable error here.
    }
  }
}
