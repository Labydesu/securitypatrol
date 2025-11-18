import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// import 'package:cloud_functions/cloud_functions.dart'; // Not needed for this version
import 'package:thesis_web/main_screens/models/users_model.dart';
import 'package:thesis_web/services/app_logger.dart';
import 'package:thesis_web/main_screens/security_guard_management/add_security_guard.dart';
import 'package:thesis_web/widgets/app_nav.dart';
import 'package:thesis_web/widgets/app_nav.dart';

class ManageUsersPage extends StatefulWidget {
  const ManageUsersPage({super.key});

  @override
  State<ManageUsersPage> createState() => _ManageUsersPageState();
}

class _ManageUsersPageState extends State<ManageUsersPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  // final FirebaseFunctions _functions = FirebaseFunctions.instance; // Not needed for this version
  final GlobalKey<FormState> _editFormKey = GlobalKey<FormState>();

  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _emailController;

  final List<String> _roles = ['Security'];

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController();
    _lastNameController = TextEditingController();
    _emailController = TextEditingController();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  // This color function now uses 'account_status'
  Color _getAccountStatusColor(String accountStatus) {
    switch (accountStatus) {
      case 'Active':
        return Colors.green.shade100;
      case 'Inactive': // Represents a locally "deactivated" account in Firestore
        return Colors.red.shade100;
      default:
        return Colors.grey.shade200;
    }
  }

  Future<void> _updateUser(UserModel userToUpdate, String newFirstName, String newLastName, String newEmail, String newRole) async {
    if (!_editFormKey.currentState!.validate()) {
      return;
    }
    _editFormKey.currentState!.save();

    try {
      await _firestore.collection('Accounts').doc(userToUpdate.id).update({
        'first_name': newFirstName.trim(),
        'last_name': newLastName.trim(),
        'name': '${newFirstName.trim()} ${newLastName.trim()}'.trim(),
        'email': newEmail.trim(),
        'role': newRole,
      });
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${userToUpdate.name} updated successfully.'), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error updating user: $e'), backgroundColor: Theme.of(context).colorScheme.error),
      );
    }
  }

  void _showEditUserDialog(UserModel user) {
    _firstNameController.text = user.firstName;
    _lastNameController.text = user.lastName;
    _emailController.text = user.email;

    String? dialogSelectedRole = _roles.contains(user.role) ? user.role : (_roles.isNotEmpty ? _roles.first : null);

    showDialog(
        context: context,
        builder: (BuildContext dialogContext) {
          return StatefulBuilder(
              builder: (context, setDialogState) {
                return AlertDialog(
                  title: Text('Edit User: ${user.name}'),
                  content: SingleChildScrollView(
                    child: Form(
                      key: _editFormKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          TextFormField(
                            controller: _firstNameController,
                            decoration: const InputDecoration(labelText: 'First Name', border: OutlineInputBorder()),
                            validator: (value) => (value == null || value.trim().isEmpty) ? 'First name cannot be empty' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _lastNameController,
                            decoration: const InputDecoration(labelText: 'Last Name', border: OutlineInputBorder()),
                            validator: (value) => (value == null || value.trim().isEmpty) ? 'Last name cannot be empty' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                              controller: _emailController,
                              decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                              keyboardType: TextInputType.emailAddress,
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) return 'Email cannot be empty';
                                if (!RegExp(r"^[a-zA-Z0-9.]+@[a-zA-Z0-9]+\.[a-zA-Z]+").hasMatch(value)) return 'Enter a valid email';
                                return null;
                              }
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            decoration: const InputDecoration(labelText: 'Role', border: OutlineInputBorder()),
                            value: dialogSelectedRole,
                            items: _roles.map<DropdownMenuItem<String>>((String value) {
                              return DropdownMenuItem<String>(value: value, child: Text(value));
                            }).toList(),
                            onChanged: (String? newValue) {
                              if (newValue != null) {
                                setDialogState(() {
                                  dialogSelectedRole = newValue;
                                });
                              }
                            },
                            validator: (value) => value == null ? 'Please select a role' : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: <Widget>[
                    TextButton(
                      child: const Text('Cancel'),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                    ElevatedButton(
                        child: const Text('Save Changes'),
                        onPressed: () {
                          if (_editFormKey.currentState!.validate()) {
                            _updateUser(user, _firstNameController.text, _lastNameController.text, _emailController.text, dialogSelectedRole!);
                          }
                        }
                    ),
                  ],
                );
              }
          );
        });
  }

  // Sets 'account_status' to 'Inactive' regardless of current value
  Future<void> _deactivateUserAccount(UserModel user) async {
    try {
      await _firestore.collection('Accounts').doc(user.id).update({
        'account_status': 'Inactive',
      });

      // Log transaction
      await AppLogger.log(
        type: 'UserAccount',
        message: 'Account deactivated',
        metadata: {
          'userId': user.id,
          'name': user.name,
          'email': user.email,
          'previousStatus': user.accountStatus,
          'newStatus': 'Inactive',
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${user.name} has been set to Inactive.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating account status: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  // Sets 'account_status' to 'Active' regardless of current value
  Future<void> _activateUserAccount(UserModel user) async {
    try {
      await _firestore.collection('Accounts').doc(user.id).update({
        'account_status': 'Active',
      });

      // Log transaction
      await AppLogger.log(
        type: 'UserAccount',
        message: 'Account activated',
        metadata: {
          'userId': user.id,
          'name': user.name,
          'email': user.email,
          'previousStatus': user.accountStatus,
          'newStatus': 'Active',
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${user.name} has been set to Active.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating account status: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  // Confirmation dialog to set 'account_status' to 'Inactive'
  void _showDeactivateAccountConfirmationDialog(UserModel user) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Deactivate Account'),
          content: Text('Are you sure you want to set ${user.name}\'s account status to Inactive?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Deactivate'),
              onPressed: () {
                Navigator.of(dialogContext).pop(); // Close this confirmation dialog
                _deactivateUserAccount(user); // Set 'account_status' to 'Inactive'
              },
            ),
          ],
        );
      },
    );
  }

  // Confirmation dialog to set 'account_status' to 'Active'
  void _showActivateAccountConfirmationDialog(UserModel user) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Activate Account'),
          content: Text('Are you sure you want to set ${user.name}\'s account status to Active?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.green),
              child: const Text('Activate'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _activateUserAccount(user);
              },
            ),
          ],
        );
      },
    );
  }

  void _navigateToAddUserScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddSecurityGuardScreen()),
    ).then((value) {
      if (value == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('New user added. List will refresh shortly.'), duration: Duration(seconds: 3)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final nav = appNavList(context, closeDrawer: true);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: const Text('Manage Users'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1_outlined),
            tooltip: 'Add New User',
            onPressed: _navigateToAddUserScreen,
          ),
        ],
      ),
      drawer: Drawer(child: nav),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _firestore
            .collection('Accounts')
            .where('role', isNotEqualTo: 'admin')
            .orderBy('role')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            print("🔴 Firestore Stream Error: ${snapshot.error}");
            print("🔴 Stack Trace: ${snapshot.stackTrace}");
            return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, color: colorScheme.error, size: 50),
                      const SizedBox(height: 10),
                      Text(
                        'Error loading users!',
                        style: TextStyle(color: colorScheme.error, fontSize: 18, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "${snapshot.error}",
                        style: TextStyle(color: colorScheme.errorContainer, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        "This often means a Firestore index is required. Please check your Firebase console for a message with a link to create the index (under Firestore Database > Indexes).",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text("Retry / Refresh Page"),
                        onPressed: () => setState(() {}),
                      )
                    ],
                  ),
                ));
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.people_outline, size: 60, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('No users found matching the criteria (excluding "admin" role).', style: TextStyle(fontSize: 16), textAlign: TextAlign.center,),
                  ],
                ));
          }

          List<UserModel> users;
          try {
            // Ensure your UserModel.fromFirestore correctly parses 'account_status'
            // If 'account_status' might be missing from older documents, provide a default in UserModel.
            users = snapshot.data!.docs
                .map((doc) => UserModel.fromFirestore(doc))
                .toList();
            if (users.isEmpty) {
              return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.people, size: 60, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('No users available after processing.', style: TextStyle(fontSize: 16), textAlign: TextAlign.center,),
                    ],
                  ));
            }
          } catch (e, s) {
            print("🔴 Error parsing user data: $e\n$s");
            return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text('Error displaying users due to parsing issue: $e', style: TextStyle(color: colorScheme.error), textAlign: TextAlign.center,),
                ));
          }

          return RefreshIndicator(
            onRefresh: () async {
              setState(() {});
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(12.0),
              itemCount: users.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (context, index) {
                final user = users[index];

                const double nameColumnWidth = 200.0;
                const double roleColumnWidth = 130.0;

                // UI elements now based on user.accountStatus
                bool isAccountCurrentlyActive = user.accountStatus == 'Active';
                IconData toggleIcon = isAccountCurrentlyActive ? Icons.person_off_outlined : Icons.person_add_alt_1_outlined;
                String toggleTooltip = isAccountCurrentlyActive ? 'Deactivate Account (Local Status)' : 'Activate Account (Local Status)';
                Color toggleIconColor = isAccountCurrentlyActive ? colorScheme.error : Colors.green.shade700;

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6.0),
                  elevation: 2.5,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                    child: Row(
                      children: <Widget>[
                        CircleAvatar(
                          backgroundColor: colorScheme.primaryContainer,
                          foregroundColor: colorScheme.onPrimaryContainer,
                          child: Text(user.name.isNotEmpty ? user.name[0].toUpperCase() : 'U'),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Row(
                            children: <Widget>[
                              Container(
                                width: nameColumnWidth,
                                padding: const EdgeInsets.only(right: 12.0),
                                child: Text(
                                  user.name.isNotEmpty ? user.name : "Unnamed User",
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  overflow: TextOverflow.ellipsis, maxLines: 1,
                                ),
                              ),
                              Container(
                                width: roleColumnWidth,
                                padding: const EdgeInsets.only(right: 12.0),
                                child: Text(
                                  user.role,
                                  style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                                  overflow: TextOverflow.ellipsis, maxLines: 1,
                                ),
                              ),
                              Expanded(
                                child: (user.email.isNotEmpty && user.email != "No Email")
                                    ? Text(
                                  user.email,
                                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                                  overflow: TextOverflow.ellipsis, maxLines: 1,
                                )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: 'Account Status: ${user.accountStatus}', // Tooltip reflects 'account_status'
                          child: Chip(
                            avatar: Icon(
                              user.accountStatus == 'Active' ? Icons.check_circle : Icons.remove_circle_outline,
                              color: user.accountStatus == 'Active' ? Colors.green.shade700 : Colors.red.shade700,
                              size: 16,
                            ),
                            label: Text(
                              user.accountStatus, // Display 'account_status'
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: user.accountStatus == 'Active' ? Colors.green.shade900 : Colors.red.shade900),
                            ),
                            backgroundColor: _getAccountStatusColor(user.accountStatus), // Color based on 'account_status'
                            padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 0.0),
                            labelPadding: const EdgeInsets.only(left: 2.0, right: 4.0),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.edit_note_outlined, color: colorScheme.primary, size: 24),
                          tooltip: 'Edit User Details',
                          onPressed: () => _showEditUserDialog(user),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        IconButton(
                          icon: const Icon(Icons.person_off_outlined, color: Colors.red, size: 24),
                          tooltip: 'Deactivate Account (Set Inactive)',
                          onPressed: () => _showDeactivateAccountConfirmationDialog(user),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        IconButton(
                          icon: const Icon(Icons.person_add_alt_1_outlined, color: Colors.green, size: 24),
                          tooltip: 'Activate Account (Set Active)',
                          onPressed: () => _showActivateAccountConfirmationDialog(user),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

