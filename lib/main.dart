import 'package:flutter/material.dart';
import 'features/home/home_screen.dart';
import 'core/services/cleanup_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 앱 시작 시 오래된 임시 파일 자동 정리 (24시간 이상)
  final cleanupService = CleanupService();
  await cleanupService.cleanupOldFiles(age: const Duration(hours: 24));

  runApp(const FightCamApp());
}

class FightCamApp extends StatelessWidget {
  const FightCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fight-Cam',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF3B3B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
