import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'presentation/pages/home_page.dart';

void main() {
  runApp(const ProviderScope(child: RrMovieWorkshopApp()));
}

class RrMovieWorkshopApp extends StatelessWidget {
  const RrMovieWorkshopApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = buildAppTheme();
    return MaterialApp(
      title: 'RR Movie Workshop',
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      home: const HomePage(),
    );
  }
}
