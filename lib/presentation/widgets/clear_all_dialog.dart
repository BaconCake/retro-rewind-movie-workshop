import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../providers/providers.dart';

/// Typed-confirmation dialog for wiping the entire custom library.
///
/// Per design briefing §5.4: "destructive wipe of the entire custom library.
/// Should use a typed-confirmation pattern given the blast radius."  We ask
/// the user to type the library count rather than a fixed word — forces
/// reading the breakdown above the input, so an accidental DELETE is
/// effectively impossible.
///
/// Returns the count of slots actually removed on success, null on cancel
/// or empty library.  Caller is responsible for surfacing the "nothing to
/// remove" branch — this dialog never opens for an empty library.
class ClearAllDialog extends ConsumerStatefulWidget {
  final int genreCount;
  final int nrCount;

  const ClearAllDialog({
    super.key,
    required this.genreCount,
    required this.nrCount,
  });

  /// Convenience: counts slots, opens the dialog (or a "nothing to remove"
  /// info box if the library is empty), runs the mutator on confirm.
  /// Returns the count removed, or null on cancel / empty.
  static Future<int?> show(BuildContext context, WidgetRef ref) async {
    final genreSlots = await ref.read(customSlotsProvider.future);
    final nrs = await ref.read(nrSlotsProvider.future);
    final genreCount =
        genreSlots.values.fold<int>(0, (acc, list) => acc + list.length);
    final nrCount = nrs.length;

    if (genreCount == 0 && nrCount == 0) {
      if (!context.mounted) return null;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: kColorPanel,
          shape: const RoundedRectangleBorder(),
          title: const Text('Nothing to remove'),
          content: const Text(
            'The custom library is already empty.',
            style: TextStyle(color: kColorText),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return null;
    }

    if (!context.mounted) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => ClearAllDialog(
        genreCount: genreCount,
        nrCount: nrCount,
      ),
    );
    if (confirmed != true) return null;
    return ref.read(clearAllControllerProvider).call();
  }

  @override
  ConsumerState<ClearAllDialog> createState() => _ClearAllDialogState();
}

class _ClearAllDialogState extends ConsumerState<ClearAllDialog> {
  final _inputCtrl = TextEditingController();
  bool _busy = false;

  int get _total => widget.genreCount + widget.nrCount;
  bool get _matches => _inputCtrl.text.trim() == _total.toString();

  String _breakdown() {
    final parts = <String>[];
    if (widget.genreCount > 0) {
      parts.add(
        '${widget.genreCount} genre movie${widget.genreCount == 1 ? '' : 's'}',
      );
    }
    if (widget.nrCount > 0) {
      parts.add(
        '${widget.nrCount} new release${widget.nrCount == 1 ? '' : 's'}',
      );
    }
    return parts.join(' and ');
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _onConfirm() async {
    if (!_matches || _busy) return;
    setState(() => _busy = true);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kColorPanel,
      shape: const RoundedRectangleBorder(),
      title: const Text('Remove all custom movies'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This will permanently remove ${_breakdown()}, '
            'their cover images, and reset edit/build tracking.',
            style: const TextStyle(color: kColorText),
          ),
          const SizedBox(height: kSp3),
          const Text(
            'This cannot be undone.',
            style: TextStyle(color: kColorPink, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: kSp4),
          Text(
            'Type $_total to confirm:',
            style: const TextStyle(color: kColorText2),
          ),
          const SizedBox(height: kSp2),
          TextField(
            controller: _inputCtrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _onConfirm(),
            style: const TextStyle(
              color: kColorText,
              fontFamily: kFontFamily,
              fontFamilyFallback: kFontFamilyFallback,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: '$_total',
              hintStyle: const TextStyle(color: kColorText3),
              filled: true,
              fillColor: kColorSurface,
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: kColorBorder),
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: kColorBorder),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: BorderSide(color: kColorPink),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: kColorPink,
            foregroundColor: kColorTextInv,
            disabledBackgroundColor: kColorDisabled,
            disabledForegroundColor: kColorText3,
            shape: const RoundedRectangleBorder(),
          ),
          onPressed: (_matches && !_busy) ? _onConfirm : null,
          child: const Text('DELETE'),
        ),
      ],
    );
  }
}
