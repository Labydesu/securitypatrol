// main_screens/models/users_model.dart
import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String id;
  final String firstName;
  final String lastName;
  String name;
  final String email;
  final String role;
  final String status; // Operational status like "On Duty" / "Off Duty"
  final String accountStatus; // "Active" / "Inactive" based on Firebase Auth disable state
  // Add any other fields like 'sex', 'address', 'contact', 'guard_id', 'position' if needed by this page

  UserModel({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.name,
    required this.email,
    required this.role,
    required this.status,
    required this.accountStatus,
  });

  factory UserModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    String calculatedName = ('${data['first_name'] ?? ''} ${data['last_name'] ?? ''}').trim();
    if (calculatedName.isEmpty) {
      calculatedName = data['name'] ?? 'Unnamed User';
    }


    return UserModel(
      id: doc.id,
      firstName: data['first_name'] as String? ?? '',
      lastName: data['last_name'] as String? ?? '',
      name: calculatedName,
      email: data['email'] as String? ?? 'No Email',
      role: data['role'] as String? ?? 'No Role',
      status: data['status'] as String? ?? 'Unknown',
      accountStatus: data['account_status'] as String? ?? 'Inactive',
    );
  }
}
