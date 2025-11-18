import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:thesis_web/main_screens/dashboard/dashboard_screen.dart';
import 'package:thesis_web/services/app_logger.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController idController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  bool _isLoading = false;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance; // Firestore instance

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: idController.text.trim(),
        password: passwordController.text.trim(),
      );

      User? user = userCredential.user;

      if (user != null) {
        DocumentSnapshot adminDoc =
        await _firestore.collection('Accounts').doc(user.uid).get();

        if (adminDoc.exists) {
          Map<String, dynamic> adminData =
          adminDoc.data() as Map<String, dynamic>;
          String? userRole = adminData['role'] as String?;

          if (userRole == 'Admin') {
            await AppLogger.log(
              type: 'Login',
              message: 'Admin logged in successfully.',
              userId: user.uid,
              metadata: {'email': user.email, 'role': userRole},
            );
            if (mounted) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const DashboardScreen()),
              );
            }
            return;
          } else {
            await AppLogger.log(
              type: 'Login Attempt',
              message: 'Login blocked - User does not have Admin privileges.',
              userId: user.uid,
              metadata: {'email': user.email, 'attempted_role': userRole ?? 'Unknown'},
            );
            await _auth.signOut(); // Sign out the user
            _showError('Access Denied: You do not have admin privileges.');
          }
        } else {
          // Document for the user UID not found in 'Accounts' collection
          await AppLogger.log(
            type: 'Login Attempt',
            message: 'Login failed - Account details not found in database.',
            userId: user.uid, // user.uid is available even if DB doc isn't
            metadata: {'email': user.email},
          );
          await _auth.signOut(); // Sign out the user
          _showError('User account information not found. Please contact support.');
        }
      } else {
        // This case should ideally not be reached if signInWithEmailAndPassword succeeds
        // and doesn't throw, but as a fallback:
        _showError('Login failed: Could not retrieve user details after sign-in.');
        // AppLogger.log might be useful here too, but without user.uid/email it's harder
      }
    } on FirebaseAuthException catch (e) {
      String errorMessage = 'An unexpected error occurred. Please try again.';
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        errorMessage = 'Invalid email or password.';
      } else if (e.code == 'invalid-email') {
        errorMessage = 'The email address is not valid.';
      } else if (e.code == 'network-request-failed') {
        errorMessage = 'Login failed. Please check your internet connection.';
      } else {
        errorMessage = 'Login failed: ${e.message}'; // Generic Firebase message
      }
      _showError(errorMessage);
      // Log failed login attempt due to FirebaseAuthException
      await AppLogger.log(
        type: 'Login Attempt',
        message: 'Login failed due to FirebaseAuthException: ${e.code}',
        userId: null, // UID might not be available yet
        metadata: {'email_attempted': idController.text.trim(), 'firebase_error_code': e.code},
      );
    } catch (e) {
      print("Login Error (Catch All): $e"); // Log the full error for debugging
      _showError('An unexpected error occurred. Please try again.');
      await AppLogger.log(
        type: 'Login Attempt',
        message: 'Login failed due to an unexpected error: $e',
        userId: null,
        metadata: {'email_attempted': idController.text.trim()},
      );
    } finally {
      if (mounted) { // Ensure widget is still mounted before calling setState
        setState(() {
          _isLoading = false; // Stop loading
        });
      }
    }
  }

  @override
  void dispose() {
    idController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade300),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center, // Center content vertically
                children: [
                  SizedBox(
                    height: 90,
                    width: 90,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        'assets/widgets/DMMMSU_LOGO.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Column(
                    children: [
                      Text(
                        'DMMMSU NLUC',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Security Tour Patrol',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.9),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: idController,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                    decoration: InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined, color: Colors.grey.shade700),
                      labelStyle: TextStyle(color: Colors.grey.shade700),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Theme.of(context).colorScheme.primary),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.red.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.red.shade600),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter Email Address';
                      }
                      // Basic email format check
                      if (!RegExp(r"^[a-zA-Z0-9.a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9]+\.[a-zA-Z]+").hasMatch(value)) {
                        return 'Please enter a valid email';
                      }
                      return null;
                    },
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: passwordController,
                    obscureText: _obscurePassword,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      labelStyle: TextStyle(color: Colors.grey.shade700),
                      prefixIcon: Icon(Icons.lock_outline, color: Colors.grey.shade700),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: Colors.grey.shade700,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Theme.of(context).colorScheme.primary),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.red.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.red.shade600),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter password';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 30),
                  _isLoading
                      ? CircularProgressIndicator(color: Theme.of(context).colorScheme.primary)
                      : ElevatedButton.icon(
                          onPressed: _login,
                          icon: const Icon(Icons.login),
                          label: const Text('Login'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            foregroundColor: Theme.of(context).colorScheme.onPrimary,
                            padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 15),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                        ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}