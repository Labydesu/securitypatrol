import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AddEditGuardScreen extends StatefulWidget {
  final String? guardDocumentId;
  final Map<String, dynamic>? initialData;

  const AddEditGuardScreen({
    super.key,
    this.guardDocumentId,
    this.initialData,
  });

  bool get isEditing => guardDocumentId != null;

  @override
  State<AddEditGuardScreen> createState() => _AddEditGuardScreenState();
}

class _AddEditGuardScreenState extends State<AddEditGuardScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _emailController;
  late TextEditingController _addressController;
  late TextEditingController _contactController;
  late TextEditingController _guardIdController;

  String? _selectedSex;
  String? _selectedPosition;

  bool _isLoading = false;

  final List<String> _sexes = ['Male', 'Female'];
  final List<String> _positions = [
    'Security Guard 1',
    'Security Guard 2',
    'Security Guard 3',
    'Security Officer 1',
    'Chief Security',
  ];

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.initialData?['first_name'] as String? ?? '');
    _lastNameController = TextEditingController(text: widget.initialData?['last_name'] as String? ?? '');
    _emailController = TextEditingController(text: widget.initialData?['email'] as String? ?? '');
    _addressController = TextEditingController(text: widget.initialData?['address'] as String? ?? '');
    _contactController = TextEditingController(text: widget.initialData?['contact'] as String? ?? '');
    _guardIdController = TextEditingController(text: widget.initialData?['guard_id'] as String? ?? '');
    _selectedSex = widget.initialData?['sex'] as String?;
    _selectedPosition = widget.initialData?['position'] as String?;
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _contactController.dispose();
    _guardIdController.dispose();
    super.dispose();
  }

  Future<void> _saveGuard() async {
    final guardIdPattern = RegExp(r'^[A-Z]{2}\d{3}$');
    if (_guardIdController.text.isNotEmpty && !guardIdPattern.hasMatch(_guardIdController.text.trim())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Guard ID must be in the format XX000 (e.g., SG001).')),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final combinedName = '$firstName $lastName'.trim();

    final guardData = {
      'first_name': firstName,
      'last_name': lastName,
      'name': combinedName,
      'email': _emailController.text.trim(),
      'sex': _selectedSex,
      'address': _addressController.text.trim(),
      'contact': _contactController.text.trim(),
      'guard_id': _guardIdController.text.trim(),
      'position': _selectedPosition,
      'role': 'Security',
    };

    try {
      if (widget.isEditing) {
        await FirebaseFirestore.instance.collection('Accounts').doc(widget.guardDocumentId!).update(guardData);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Guard details updated successfully!')),
          );
        }
      } else {
        final emailQuery = await FirebaseFirestore.instance
            .collection('Accounts')
            .where('email', isEqualTo: _emailController.text.trim())
            .limit(1)
            .get();

        if (emailQuery.docs.isNotEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Email "${_emailController.text.trim()}" already exists.')),
            );
          }
          setState(() => _isLoading = false);
          return;
        }

        final existingGuard = await FirebaseFirestore.instance
            .collection('Accounts')
            .where('guard_id', isEqualTo: _guardIdController.text.trim())
            .limit(1)
            .get();

        if (existingGuard.docs.isNotEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: Guard ID "${_guardIdController.text.trim()}" already exists.')),
            );
          }
          setState(() => _isLoading = false);
          return;
        }

        await FirebaseFirestore.instance.collection('Accounts').add({
          ...guardData,
          'status': 'Off Duty',
          'account_status': 'Active',
          'createdAt': FieldValue.serverTimestamp(),
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Guard added successfully!')),
          );
        }
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving guard: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
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

  Widget _buildTextField(
    TextEditingController controller,
    String label, {
    bool isNumber = false,
    bool isEmail = false,
    bool readOnly = false,
    IconData? prefixIcon,
    String? helper,
    String? Function(String?)? validator,
    TextCapitalization capitalization = TextCapitalization.none,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        keyboardType: isNumber
            ? TextInputType.phone
            : isEmail
                ? TextInputType.emailAddress
                : TextInputType.text,
        textCapitalization: capitalization,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          prefixIcon: prefixIcon != null ? Icon(prefixIcon) : null,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        validator: validator ??
            (value) {
              final trimmedValue = value?.trim() ?? '';
              if (trimmedValue.isEmpty) return '$label is required.';

              if (isNumber) {
                if (!RegExp(r'^09\d{9}$').hasMatch(trimmedValue)) {
                  return 'Contact must start with 09 and be 11 digits.';
                }
              }
              if (isEmail) {
                if (!RegExp(r"^[a-zA-Z0-9.a-zA-Z0-9.!#\$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,253}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,253}[a-zA-Z0-9])?)*$").hasMatch(trimmedValue)) {
                  return 'Enter a valid email address.';
                }
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit Security Guard' : 'Add New Guard'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: 2.0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.isEditing ? 'Update Guard Credentials' : 'Enter Guard Credentials',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              _sectionCard(
                icon: Icons.badge_outlined,
                title: 'Personal Information',
                children: [
                  _twoColumn(
                    left: _buildTextField(
                      _firstNameController,
                      'First Name',
                      prefixIcon: Icons.person_outline,
                      capitalization: TextCapitalization.words,
                    ),
                    right: _buildTextField(
                      _lastNameController,
                      'Last Name',
                      prefixIcon: Icons.person_outline,
                      capitalization: TextCapitalization.words,
                    ),
                  ),
                  _twoColumn(
                    left: _buildDropdown(
                      'Sex',
                      _sexes,
                      _selectedSex,
                      (val) => setState(() => _selectedSex = val),
                      prefixIcon: Icons.transgender_outlined,
                    ),
                    right: _buildTextField(
                      _emailController,
                      'Email',
                      isEmail: true,
                      readOnly: widget.isEditing,
                      prefixIcon: Icons.alternate_email_outlined,
                      helper: widget.isEditing ? 'Email is view only for existing guards' : 'We will send credentials to this email.',
                    ),
                  ),
                  _buildTextField(
                    _addressController,
                    'Address',
                    prefixIcon: Icons.home_outlined,
                    capitalization: TextCapitalization.sentences,
                  ),
                  _buildTextField(
                    _contactController,
                    'Contact Number',
                    isNumber: true,
                    prefixIcon: Icons.call_outlined,
                    helper: 'Format: 09XXXXXXXXX',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sectionCard(
                icon: Icons.assignment_ind_outlined,
                title: 'Employment Details',
                children: [
                  _twoColumn(
                    left: _buildTextField(
                      _guardIdController,
                      'Security Guard ID (Unique)',
                      readOnly: widget.isEditing,
                      prefixIcon: Icons.confirmation_number_outlined,
                      capitalization: TextCapitalization.characters,
                      validator: (value) {
                        final trimmedValue = value?.trim() ?? '';
                        if (trimmedValue.isEmpty) return 'Security Guard ID is required.';
                        if (!RegExp(r'^[A-Z]{2}\d{3}$').hasMatch(trimmedValue)) {
                          return 'Format must be XX000 (e.g., SG001).';
                        }
                        return null;
                      },
                    ),
                    right: _buildDropdown(
                      'Security Guard Position',
                      _positions,
                      _selectedPosition,
                      (val) => setState(() => _selectedPosition = val),
                      prefixIcon: Icons.work_outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isLoading
                          ? null
                          : () {
                              _formKey.currentState?.reset();
                              setState(() {
                                _selectedSex = widget.initialData?['sex'] as String?;
                                _selectedPosition = widget.initialData?['position'] as String?;
                              });
                            },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset'),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: Icon(widget.isEditing ? Icons.save_outlined : Icons.add_circle_outline),
                      onPressed: _isLoading ? null : _saveGuard,
                      label: Text(widget.isEditing ? 'Save Changes' : 'Add Guard'),
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
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
