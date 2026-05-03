import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../providers/providers.dart';

/// Right-hand operations column.  Single primary CTA (cyan, per the Python
/// design rule "ONE primary button per screen"), then a section header for
/// the build log with a copy-to-clipboard control, then the log itself, and
/// finally an error banner when the most recent build failed.
class BuildPanel extends ConsumerWidget {
  const BuildPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(buildControllerProvider);
    final controller = ref.read(buildControllerProvider.notifier);

    return Container(
      width: 360,
      color: kColorPanel,
      padding: const EdgeInsets.all(kSp3),
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
                : const Icon(Icons.local_shipping_outlined, size: 18),
            label: Text(
              state.isRunning ? 'BUILDING...' : 'SHIP TO STORE',
              style: const TextStyle(letterSpacing: 1.5),
            ),
          ),
          const SizedBox(height: kSp3),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'BUILD LOG',
                  style: TextStyle(
                    fontSize: kFsMeta,
                    fontWeight: FontWeight.w700,
                    color: kColorCyan,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy log to clipboard',
                visualDensity: VisualDensity.compact,
                color: kColorText2,
                icon: const Icon(Icons.content_copy, size: 14),
                onPressed: state.log.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                            ClipboardData(text: state.log.join('\n')));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Log copied to clipboard'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: kSp1),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: kColorBg,
                border: Border.all(color: kColorBorder),
              ),
              padding: const EdgeInsets.all(kSp2),
              child: ListView.builder(
                itemCount: state.log.length,
                itemBuilder: (context, i) {
                  final line = state.log[i];
                  return Text(
                    line,
                    style: TextStyle(
                      fontSize: kFsMeta,
                      color: _logLineColor(line),
                      height: 1.3,
                    ),
                  );
                },
              ),
            ),
          ),
          if (state.lastErrorCode != null) ...[
            const SizedBox(height: kSp2),
            Container(
              padding: const EdgeInsets.all(kSp2),
              decoration: BoxDecoration(
                color: kColorPanel,
                border: Border.all(color: kColorPink),
              ),
              child: Text(
                '[${state.lastErrorCode}] ${state.lastErrorMessage}',
                style: const TextStyle(
                  color: kColorPink,
                  fontSize: kFsMeta,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Tint individual log lines so the operator can scan progress at a glance.
  /// Anything containing FAIL/ERROR is pink, OK/INJECT/PLACEHOLDER are cyan,
  /// the rest stays in the muted text colour.
  Color _logLineColor(String line) {
    final l = line.toUpperCase();
    if (l.contains('FAIL') || l.contains('ERROR') || l.contains('[E0')) {
      return kColorPink;
    }
    if (l.contains(' OK') ||
        l.contains('INJECT ') ||
        l.contains('PLACEHOLDER ') ||
        l.contains('SUCCEEDED') ||
        l.contains('INSTALLED')) {
      return kColorCyan;
    }
    return kColorText2;
  }
}
