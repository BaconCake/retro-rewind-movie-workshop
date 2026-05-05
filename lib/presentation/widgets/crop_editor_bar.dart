import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Two-row cropper editor bar mirroring Python's `_ctrl_f` panel
/// (RR_VHS_Tool.py:7969-8028):
///
///  * Row 1 — `−` / zoom slider (0.5–3.0) / `+` / zoom readout.
///  * Row 2 — three equal-width action buttons: `↻ Rotate`,
///    `⬜ Fill Canvas`, `⛶ Fit Visible`.
///
/// The slider operates in *transient* mode: dragging fires [onZoomPreview]
/// every tick (the parent reflects it in the cropper without saving), and
/// release fires [onZoomCommit] with the final value (parent persists).
/// `+` / `−` snap the new zoom to 1.00 when within 0.05, matching
/// `_zoom_step` (RR_VHS_Tool.py:11636-11655).
class CropEditorBar extends StatefulWidget {
  /// The currently displayed zoom (live during slider drag, otherwise the
  /// saved value from `replacements.json`).
  final double zoom;

  /// True when an image is set on the slot.  Disables every control when
  /// false — there's nothing to act on.
  final bool enabled;

  /// Live preview while the slider is being dragged.
  final ValueChanged<double> onZoomPreview;

  /// Persistent commit on slider release / button click.
  final ValueChanged<double> onZoomCommit;

  /// Action callbacks — fired when the corresponding button is clicked.
  final VoidCallback? onRotate;
  final VoidCallback? onFillCanvas;
  final VoidCallback? onFitVisible;

  const CropEditorBar({
    super.key,
    required this.zoom,
    required this.enabled,
    required this.onZoomPreview,
    required this.onZoomCommit,
    this.onRotate,
    this.onFillCanvas,
    this.onFitVisible,
  });

  @override
  State<CropEditorBar> createState() => _CropEditorBarState();
}

class _CropEditorBarState extends State<CropEditorBar> {
  // Briefly tints the zoom label cyan when a step / snap lands on 1.00.
  bool _snapHighlight = false;

  // Snap-to-1.0 logic from Python's `_zoom_step` (RR_VHS_Tool.py:11644-11650).
  // Returns the new zoom and whether we just snapped.
  ({double zoom, bool snapped}) _stepZoom(double delta) {
    var next = double.parse((widget.zoom + delta).toStringAsFixed(2));
    next = next.clamp(0.5, 3.0).toDouble();
    var snapped = false;
    if ((next - 1.0).abs() < 0.05) {
      next = 1.0;
      snapped = true;
    }
    return (zoom: next, snapped: snapped);
  }

  void _flashSnap() {
    setState(() => _snapHighlight = true);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _snapHighlight = false);
    });
  }

  void _onStepDelta(double delta) {
    if (!widget.enabled) return;
    final r = _stepZoom(delta);
    if (r.snapped) _flashSnap();
    widget.onZoomCommit(r.zoom);
  }

  @override
  Widget build(BuildContext context) {
    final zoomLabelColor = _snapHighlight ? kColorCyan : kColorText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Row 1: − [Slider] + 1.0x ─────────────────────────────────
        Row(
          children: [
            _StepButton(
              label: '−',
              enabled: widget.enabled,
              onTap: () => _onStepDelta(-0.05),
            ),
            const SizedBox(width: kSp1),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  activeTrackColor: kColorCyan,
                  inactiveTrackColor: kColorBorder,
                  thumbColor: kColorCyan,
                  overlayColor: kColorCyan.withValues(alpha: 0.18),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  min: 0.5,
                  max: 3.0,
                  value: widget.zoom.clamp(0.5, 3.0),
                  onChanged: widget.enabled
                      ? (v) => widget.onZoomPreview(
                          double.parse(v.toStringAsFixed(2)))
                      : null,
                  onChangeEnd: widget.enabled
                      ? (v) => widget.onZoomCommit(
                          double.parse(v.toStringAsFixed(2)))
                      : null,
                ),
              ),
            ),
            const SizedBox(width: kSp1),
            _StepButton(
              label: '+',
              enabled: widget.enabled,
              onTap: () => _onStepDelta(0.05),
            ),
            const SizedBox(width: kSp2),
            SizedBox(
              width: 40,
              child: Text(
                '${widget.zoom.toStringAsFixed(1)}x',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: kFsMeta,
                  color: widget.enabled ? zoomLabelColor : kColorDisabled,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: kSp1),
        // ── Row 2: action buttons (equal-width) ──────────────────────
        Row(
          children: [
            Expanded(
              child: _ActionButton(
                label: '↻ Rotate',
                tooltip: 'Rotate image 90° clockwise',
                enabled: widget.enabled && widget.onRotate != null,
                onTap: widget.onRotate,
              ),
            ),
            const SizedBox(width: kSp1),
            Expanded(
              child: _ActionButton(
                label: '⬜ Fill Canvas',
                tooltip: 'Scale image to fill the entire canvas (1024×2048)',
                enabled: widget.enabled && widget.onFillCanvas != null,
                onTap: widget.onFillCanvas,
              ),
            ),
            const SizedBox(width: kSp1),
            Expanded(
              child: _ActionButton(
                label: '⛶ Fit Visible',
                tooltip: 'Scale image to fill the visible tape area',
                enabled: widget.enabled && widget.onFitVisible != null,
                onTap: widget.onFitVisible,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepButton extends StatefulWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _StepButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = !widget.enabled
        ? kColorDivider
        : (_hover ? kColorSurface : kColorBorder);
    final fg = widget.enabled ? kColorText : kColorDisabled;
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: kSp2, vertical: 2),
          color: bg,
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: kFsMeta,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final String label;
  final String tooltip;
  final bool enabled;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.label,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = !widget.enabled
        ? kColorDivider
        : (_hover ? kColorSurface : kColorBorder);
    final fg = widget.enabled ? kColorText2 : kColorDisabled;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: kSp2,
              vertical: kSp1,
            ),
            color: bg,
            alignment: Alignment.center,
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: kFsMeta,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
