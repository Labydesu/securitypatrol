import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AddSecurityGuardScreen extends StatefulWidget {
  const AddSecurityGuardScreen({super.key});

  @override
  State<AddSecurityGuardScreen> createState() => _AddSecurityGuardScreenState();
}

class _AddSecurityGuardScreenState extends State<AddSecurityGuardScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController firstnameController = TextEditingController();
  final TextEditingController lastnameController = TextEditingController();
  final TextEditingController addressController = TextEditingController();
  final TextEditingController contactController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController secuidController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController retypePasswordController = TextEditingController();

  String? selectedSex;
  String? selectedPosition;

  final List<String> sexes = ['Male', 'Female'];
  final List<String> positions = ['Security Guard 1', 'Security Guard 2', 'Security Guard 3', 'Security Officer 1', 'Chief Security'];

  bool _obscurePassword = true;
  bool _obscureRetype = true;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  void dispose() {
    firstnameController.dispose();
    lastnameController.dispose();
    addressController.dispose();
    contactController.dispose();
    emailController.dispose();
    secuidController.dispose();
    passwordController.dispose();
    retypePasswordController.dispose();
    super.dispose();
  }

  void _resetFormFields() {
    _formKey.currentState?.reset();
    firstnameController.clear();
    lastnameController.clear();
    addressController.clear();
    contactController.clear();
    emailController.clear();
    secuidController.clear();
    passwordController.clear();
    retypePasswordController.clear();
    setState(() {
      selectedSex = null;
      selectedPosition = null;
    });
  }

  Future<void> _submitForm() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const Dialog(
          child: Padding(
            padding: EdgeInsets.all(20.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("Creating Account..."),
              ],
            ),
          ),
        );
      },
    );

    final email = emailController.text.trim();
    final guardIdFromInput = secuidController.text.trim();
    final firstName = firstnameController.text.trim();
    final lastName = lastnameController.text.trim();

    try {
      final existingEmailQuery = await _firestore
          .collection('Accounts')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();

      if (existingEmailQuery.docs.isNotEmpty) {
        if (mounted) Navigator.of(context).pop();
        _showError('Email already registered in Accounts. Please use a different email.');
        return;
      }

      final existingGuardIdQuery = await _firestore
          .collection('Accounts')
          .where('guard_id', isEqualTo: guardIdFromInput)
          .limit(1)
          .get();

      if (existingGuardIdQuery.docs.isNotEmpty) {
        if (mounted) Navigator.of(context).pop();
        _showError('Security Guard ID "$guardIdFromInput" already exists. Please use a different ID.');
        return;
      }

      UserCredential credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: passwordController.text.trim(),
      );

      String fullName = '$firstName $lastName'.trim();
      if (fullName.isEmpty && firstName.isNotEmpty) {
        fullName = firstName;
      } else if (fullName.isEmpty && lastName.isNotEmpty) {
        fullName = lastName;
      }

      await _firestore.collection('Accounts').doc(credential.user!.uid).set({
        'uid': credential.user!.uid,
        'first_name': firstName,
        'last_name': lastName,
        'name': fullName,
        'email': email,
        'initial_password': passwordController.text.trim(),
        'sex': selectedSex,
        'address': addressController.text.trim(),
        'contact': contactController.text.trim(),
        'guard_id': guardIdFromInput,
        'position': selectedPosition,
        'role': 'Security',
        'status': 'Off Duty',
        'account_status': 'Active',
        'createdAt': FieldValue.serverTimestamp(),
        'isApproved': true,
      });

      if (mounted) Navigator.of(context).pop();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Security guard account created successfully!'),
              backgroundColor: Colors.green),
        );
        _resetFormFields();
        Navigator.pop(context, true);
      }

    } on FirebaseAuthException catch (e) {
      if (mounted) Navigator.of(context).pop();
      String errorMessage = 'Registration Error: ${e.message ?? e.code}';
      if (e.code == 'email-already-in-use') {
        errorMessage = 'This email is already registered. Please use a different email or log in.';
      }
      _showError(errorMessage);
      print("FirebaseAuthException: ${e.code} - ${e.message}");
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _showError('An unexpected error occurred: $e');
      print("Generic Error during registration: $e");
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Security Guard'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionCard(
                icon: Icons.badge_outlined,
                title: 'Personal Information',
                children: [
                  _twoColumn(
                    left: _buildTextField(firstnameController, 'First Name', prefixIcon: Icons.person_outline),
                    right: _buildTextField(lastnameController, 'Last Name', prefixIcon: Icons.person_outline),
                  ),
                  _twoColumn(
                    left: _buildDropdown('Sex', sexes, selectedSex, (val) => setState(() => selectedSex = val), prefixIcon: Icons.transgender_outlined),
                    right: _buildTextField(emailController, 'Email', isEmail: true, prefixIcon: Icons.alternate_email_outlined, helper: 'We will send credentials to this email.'),
                  ),
                  _buildTextField(addressController, 'Address', prefixIcon: Icons.home_outlined),
                  _buildTextField(contactController, 'Contact Number', isNumber: true, prefixIcon: Icons.call_outlined, helper: 'Format: 09XXXXXXXXX'),
                ],
              ),

              const SizedBox(height: 16),

              _sectionCard(
                icon: Icons.assignment_ind_outlined,
                title: 'Employment Details',
                children: [
                  _twoColumn(
                    left: _buildTextField(secuidController, 'Security Guard ID (Unique)', prefixIcon: Icons.confirmation_number_outlined),
                    right: _buildDropdown('Security Guard Position', positions, selectedPosition, (val) => setState(() => selectedPosition = val), prefixIcon: Icons.work_outline),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              _sectionCard(
                icon: Icons.lock_outline,
                title: 'Set Password',
                children: [
                  _twoColumn(
                    left: _buildPasswordField(passwordController, 'Password', _obscurePassword, () { setState(() => _obscurePassword = !_obscurePassword); }),
                    right: _buildPasswordField(retypePasswordController, 'Retype Password', _obscureRetype, () { setState(() => _obscureRetype = !_obscureRetype); }, isConfirm: true),
                  ),
                ],
              ),

              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _resetFormFields,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset'),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _submitForm,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Create Account'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard({required IconData icon, required String title, required List<Widget> children}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4)),
        ],
        border: Border.all(color: Colors.grey.shade200),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: colorScheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, color: colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 10),
              Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: colorScheme.onSurface)),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _twoColumn({required Widget left, required Widget right}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 700) {
          return Row(
            children: [
              Expanded(child: left),
              const SizedBox(width: 12),
              Expanded(child: right),
            ],
          );
        }
        return Column(
          children: [left, right],
        );
      },
    );
  }

  Widget _buildTextField(TextEditingController controller, String label, {bool isNumber = false, bool isEmail = false, IconData? prefixIcon, String? helper}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: isNumber
            ? TextInputType.phone
            : isEmail
            ? TextInputType.emailAddress
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          prefixIcon: prefixIcon != null ? Icon(prefixIcon) : null,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        validator: (value) {
          final trimmedValue = value?.trim() ?? '';
          if (trimmedValue.isEmpty) return '$label is required.';

          if (isNumber) {
            if (!RegExp(r'^09\d{9}').hasMatch(trimmedValue)) {
              return 'Contact must start with 09 and be 11 digits.';
            }
          }
          if (isEmail) {
            if (!RegExp(r"^[a-zA-Z0-9.a-zA-Z0-9.!#\$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,253}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,253}[a-zA-Z0-9])?)*$").hasMatch(trimmedValue)) {
              return 'Enter a valid email address.';
            }
          }
          if (label == 'Security Guard ID (Unique)' && trimmedValue.length < 3) {
            return 'Security Guard ID must be at least 3 characters.';
          }
          return null;
        },
      ),
    );
  }

  Widget _buildDropdown(String label, List<String> items, String? selected, ValueChanged<String?> onChanged, {IconData? prefixIcon}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: selected,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: prefixIcon != null ? Icon(prefixIcon) : null,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        items: items.map((val) => DropdownMenuItem(value: val, child: Text(val))).toList(),
        onChanged: onChanged,
        validator: (value) => value == null ? 'Please select $label.' : null,
      ),
    );
  }

  Widget _buildPasswordField(
      TextEditingController controller,
      String label,
      bool obscure,
      VoidCallback toggle, {
        bool isConfirm = false,
      }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.lock_outline),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          suffixIcon: IconButton(
            icon: Icon(obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            onPressed: toggle,
          ),
        ),
        validator: (value) {
          final trimmedValue = value?.trim() ?? '';
          if (trimmedValue.isEmpty) return '$label is required.';
          if (label == 'Password' && trimmedValue.length < 6) {
            return 'Password must be at least 6 characters.';
          }
          if (isConfirm && trimmedValue != passwordController.text.trim()) {
            return 'Passwords do not match.';
          }
          return null;
        },
      ),
    );
  }
}
