import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'dart:developer';
import 'config/feature_flags.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'overlay_main.dart';

@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        canvasColor: Colors.transparent,
        scaffoldBackgroundColor: Colors.transparent,
        cardColor: Colors.white,
        dialogBackgroundColor: Colors.transparent,
        primaryColor: const Color(0xFF4F46E5),
        useMaterial3: true,
        colorScheme: const ColorScheme.light(
          background: Colors.transparent,
          primary: Color(0xFF4F46E5),
          surface: Colors.white,
          onSurface: Color(0xFF1E293B),
          onPrimary: Colors.white,
        ),
      ),
      builder: (context, child) {
        return Container(color: Colors.transparent, child: child);
      },
      home: const OverlayApp(),
    ),
  );
}

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

void Function(String task)? onOverlayTask;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (FeatureFlags.floatingOverlayEnabled) {
    FlutterOverlayWindow.overlayListener.listen((event) {
      log("Main app received from overlay: $event");
      if (event is String && event.trim().isNotEmpty) {
        if (onOverlayTask != null) {
          onOverlayTask!(event.trim());
        } else {
          log("Warning: overlay task received but no handler registered yet");
        }
      }
    });
  }

  final prefs = await SharedPreferences.getInstance();
  final themeStr = prefs.getString('themeMode');
  if (themeStr == 'dark') {
    themeNotifier.value = ThemeMode.dark;
  } else {
    themeNotifier.value = ThemeMode.light;
  }

  final onboardingCompleted = prefs.getBool('onboarding_completed') ?? false;

  runApp(PrivateAgentApp(onboardingCompleted: onboardingCompleted));
}

class PrivateAgentApp extends StatelessWidget {
  final bool onboardingCompleted;
  const PrivateAgentApp({super.key, required this.onboardingCompleted});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, ThemeMode currentMode, child) {
        return MaterialApp(
          title: 'PrivateAgent',
          debugShowCheckedModeBanner: false,
          themeMode: currentMode,
          theme: ThemeData(
            brightness: Brightness.light,
            primaryColor: const Color(0xFF4F46E5), // Indigo-600
            scaffoldBackgroundColor: const Color(
              0xFFF8FAFC,
            ), // Slate-50 background
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF4F46E5), // Indigo-600
              secondary: Color(0xFF0EA5E9), // Sky-500
              surface: Color(0xFFFFFFFF),
              onSurface: Color(0xFF1E293B), // Slate-800
              surfaceContainerHighest: Color(0xFFF1F5F9), // Slate-100
              error: Colors.redAccent,
            ),
            useMaterial3: true,
            appBarTheme: const AppBarTheme(
              centerTitle: true,
              elevation: 0,
              scrolledUnderElevation: 0,
              backgroundColor: Colors.transparent,
              foregroundColor: Color(0xFF1E293B),
              iconTheme: IconThemeData(color: Color(0xFF1E293B)),
              systemOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.dark,
                statusBarBrightness: Brightness.light,
              ),
            ),
            cardTheme: CardThemeData(
              elevation: 0,
              color: const Color(0xFFFFFFFF),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(
                  color: Color(0xFFE2E8F0),
                  width: 1.2,
                ), // Slate-200
              ),
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            primaryColor: const Color(0xFF6366F1), // Indigo-500
            scaffoldBackgroundColor: const Color(
              0xFF0B0F19,
            ), // Midnight deep slate
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF6366F1), // Indigo-500
              secondary: Color(0xFF38BDF8), // Sky-400
              surface: Color(0xFF151D30), // Midnight gray-blue card background
              onSurface: Color(0xFFF8FAFC), // Slate-50 text
              surfaceContainerHighest: Color(0xFF1E293B), // Slate-800
              error: Colors.redAccent,
            ),
            useMaterial3: true,
            appBarTheme: const AppBarTheme(
              centerTitle: true,
              elevation: 0,
              scrolledUnderElevation: 0,
              backgroundColor: Colors.transparent,
              foregroundColor: Color(0xFFF8FAFC),
              iconTheme: IconThemeData(color: Color(0xFFF8FAFC)),
              systemOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.light,
                statusBarBrightness: Brightness.dark,
              ),
            ),
            cardTheme: CardThemeData(
              elevation: 0,
              color: const Color(0xFF151D30),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: const Color(0xFF243049).withOpacity(0.4),
                  width: 1.2,
                ),
              ),
            ),
          ),
          home: onboardingCompleted
              ? const HomeScreen()
              : const OnboardingScreen(),
        );
      },
    );
  }
}
