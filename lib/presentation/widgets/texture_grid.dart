import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../providers/providers.dart';

class TextureGrid extends ConsumerWidget {
  final GenreInfo genre;

  const TextureGrid({super.key, required this.genre});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textures = ref
        .watch(texturesProvider)
        .where((t) => t.genre == genre.name)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(genre.name,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                childAspectRatio: 0.5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: textures.length,
              itemBuilder: (context, i) {
                final t = textures[i];
                return Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    t.name,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
