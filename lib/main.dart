import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thesis_web/main_screens/mapping/mapping_management.dart';
import 'package:thesis_web/utils/lifecycle_observer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addObserver(AppLifecycleObserver());
  SystemChannels.lifecycle.setMessageHandler((message) async {
    return null;
  });
  if (kIsWeb) {
    await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: "AIzaSyBtVHxTLVPvqmTG-OVAmoT5T3XH9QvwPec",
            authDomain: "security-tour-patrol-43d70.firebaseapp.com",
            projectId: "security-tour-patrol-43d70",
            storageBucket: "security-tour-patrol-43d70.firebasestorage.app",
            messagingSenderId: "201439742312",
            appId: "1:201439742312:web:7b06302a31b2cd8f3eaedd",
            measurementId: "G-B26LCNYS48"));
  } else {
    await Firebase.initializeApp();
  }

  runApp(const SecurityGuardApp());
}

class SecurityGuardApp extends StatelessWidget {
  const SecurityGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Security Guard App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.white,
        cardColor: Colors.grey.shade50,
        dividerColor: Colors.grey.shade300,
        appBarTheme: const AppBarTheme(centerTitle: false),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.grey.shade100,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          labelStyle: const TextStyle(color: Colors.black87),
        ),
      ),
      home: const MappingManagementScreen(),
    );
  }
}
