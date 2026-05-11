import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/sort.dart';
import '../providers/providers.dart';

/// Thin shelf header bar with a "Sort:" trigger on the right.  Renders
/// above the grid for every tab except "All Movies" (briefing §5.4 +
/// §9.2 — the multi-genre overview is intentionally unsorted).
///
/// Trigger label is the current option's name + arrow ("Created at ▴").
/// Tapping opens a popup with all six options; selection persists to
/// `sort_preferences.json` per-tab.
///
/// Visual style is intentionally minimal — a small text-and-arrow chip,
/// matching Python's flat shelf header (RR_VHS_Tool.py:8104-8141).
class SortHeaderBar extends ConsumerWidget {
  final String tabName;
  const SortHeaderBar({super.key, required this.tabName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(sortPrefsProvider.notifier);
    // Watch the raw state so a setForTab on another tab doesn't trigger
    // this rebuild — only the current tab's value matters.
    final current = ref.watch(sortPrefsProvider.select(
      (m) => SortKey.fromWireKey(m[tabName]),
    ));

    return Container(
      padding: const EdgeInsets.fromLTRB(kSp3, kSp2, kSp3, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const Text(
            'Sort:',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: kFsMeta,
              color: kColorText3,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: kSp1),
          PopupMenuButton<SortKey>(
            tooltip: 'Sort order',
            initialValue: current,
            position: PopupMenuPosition.under,
            color: kColorPanel,
            onSelected: (k) => prefs.setForTab(tabName, k),
            itemBuilder: (context) => [
              for (final k in SortKey.values)
                PopupMenuItem<SortKey>(
                  value: k,
                  height: 32,
                  child: Text(
                    '${k.label}  ${k.arrow}',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: kFsBody,
                      color: k == current ? kColorCyan : kColorText,
                    ),
                  ),
                ),
            ],
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: kSp2, vertical: 2),
              decoration: BoxDecoration(
                color: kColorSurface,
                border: Border.all(color: kColorBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${current.label}  ${current.arrow}',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: kFsMeta,
                      color: kColorText,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: kSp1),
                  const Icon(Icons.arrow_drop_down,
                      color: kColorText3, size: 14),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
