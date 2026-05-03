import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

class BuildPanel extends ConsumerWidget {
  const BuildPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(buildControllerProvider);
    final controller = ref.read(buildControllerProvider.notifier);

    return Container(
      width: 360,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: state.isRunning ? null : controller.ship,
            icon: state.isRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.local_shipping_outlined),
            label: Text(state.isRunning ? 'Building...' : 'Ship to Store'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text('Build log',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              IconButton(
                tooltip: 'Copy log to clipboard',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.content_copy, size: 16),
                onPressed: state.log.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                            ClipboardData(text: state.log.join('\n')));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Log copied to clipboard'),
                                duration: Duration(seconds: 1)),
                          );
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              padding: const EdgeInsets.all(8),
              child: ListView.builder(
                itemCount: state.log.length,
                itemBuilder: (context, i) => Text(
                  state.log[i],
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
          if (state.lastErrorCode != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '[${state.lastErrorCode}] ${state.lastErrorMessage}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
