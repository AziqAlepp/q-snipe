import 'package:flutter/material.dart';

import 'app/home_page.dart';
import 'services/sniper_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureSniperService();
  runApp(const QueueSniperApp());
}

class QueueSniperApp extends StatelessWidget {
  const QueueSniperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Queue Sniper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF3DDC84),
      ),
      home: const HomePage(),
    );
  }
}
