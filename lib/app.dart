// The shell: MaterialApp and the route to the one screen. Sits with the
// SCREENS band (it knows screens; nothing below).
import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

class CairnApp extends StatelessWidget {
  const CairnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cairn',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6B705C))),
      home: const HomeScreen(),
    );
  }
}
