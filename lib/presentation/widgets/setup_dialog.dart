import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/app_theme.dart';
import '../../data/services/setup_autodetect.dart';
import '../../domain/entities/app_config.dart';
import '../providers/providers.dart';

// Per-row inline descriptions — shown under each path title (P1).  Ported
// verbatim from the redesign brief (Claude Design prompt 1) so the four
// fields explain themselves without the user having to guess what each
// path is for.
const String _kDescTexconv =
    'Converts your cover PNGs to DDS textures the game can load.';
const String _kDescRepak =
    'Packs your library into a .pak archive ready to drop into the game.';
const String _kDescBasePak =
    'Workshop reads art, fonts, and shelf metadata from this file.';
const String _kDescModsFolder =
    'Where finished builds get installed. Created automatically if missing.';

/// Why a path didn't validate — drives the per-row actionable hint
/// rendering (P8).  `ok` means the path passes; everything else
/// represents a distinct user-actionable failure mode the hint can
/// speak to specifically (e.g. wrong basename → "Wrong file — expected
/// X, try Re-scan").
enum _ValidationKind {
  ok,
  empty,
  fileMissing,
  dirMissing,
  basenameMismatch,
}

/// Validate one path field.  Pulled out of `_PathRow` so the section
/// counter pill (P1) and the row itself share the exact same rule —
/// counter must match what the row's status indicator shows.  The
/// [kind] discriminator lets P8's hint builder pick the right copy.
({bool ok, _ValidationKind kind}) _validatePath(
    String value, String? expectedBasename) {
  if (value.isEmpty) return (ok: false, kind: _ValidationKind.empty);
  if (expectedBasename == null) {
    return Directory(value).existsSync()
        ? (ok: true, kind: _ValidationKind.ok)
        : (ok: false, kind: _ValidationKind.dirMissing);
  }
  if (!File(value).existsSync()) {
    return (ok: false, kind: _ValidationKind.fileMissing);
  }
  if (p.basename(value).toLowerCase() != expectedBasename.toLowerCase()) {
    return (ok: false, kind: _ValidationKind.basenameMismatch);
  }
  return (ok: true, kind: _ValidationKind.ok);
}

/// Run [exePath] with [args] and parse the first version-looking token
/// from stdout+stderr.  Used by the texconv / repak rows to show a real
/// version pill next to the row title (P2).  Times out after 2 s so a
/// hanging or non-responsive binary never freezes the dialog.
///
/// Returns null on any failure (file missing, non-zero exit with no
/// parseable output, timeout, exception).  The caller treats null as
/// "show no pill" rather than as an error — verification status is
/// already conveyed by the left-edge status indicator.
Future<String?> _detectExeVersion(String exePath, List<String> args) async {
  if (exePath.isEmpty || !File(exePath).existsSync()) return null;
  try {
    final r = await Process.run(exePath, args, runInShell: false)
        .timeout(const Duration(seconds: 2));
    final out = '${r.stdout}\n${r.stderr}';
    // Match "v10.0.20348.0", "0.2.6", "version 1.2.3" etc.  Anchored on
    // a digit-dot-digit core so we don't trip over copyright years.
    final m = RegExp(r'v?(\d+\.\d+(?:\.\d+){0,2})').firstMatch(out);
    if (m == null) return null;
    return 'v${m.group(1)}';
  } catch (_) {
    return null;
  }
}

/// Format file size in bytes as a short human-readable string.  Mirrors
/// what the briefing's screenshots show next to the base-pak row
/// (e.g. "8.4 GB").  Returns null when the path doesn't resolve.
String? _formatFileSize(String path) {
  if (path.isEmpty) return null;
  try {
    final bytes = File(path).statSync().size;
    if (bytes <= 0) return null;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var idx = 0;
    while (value >= 1024 && idx < units.length - 1) {
      value /= 1024;
      idx++;
    }
    return value >= 10
        ? '${value.toStringAsFixed(0)} ${units[idx]}'
        : '${value.toStringAsFixed(1)} ${units[idx]}';
  } catch (_) {
    return null;
  }
}

/// Short summary for a directory — "empty · ready" or "N entries".  Used
/// as the info pill next to the Mods folder row when the path validates.
String? _summarizeDir(String path) {
  if (path.isEmpty) return null;
  try {
    final dir = Directory(path);
    if (!dir.existsSync()) return null;
    final n = dir.listSync().length;
    if (n == 0) return 'empty · ready';
    return n == 1 ? '1 entry' : '$n entries';
  } catch (_) {
    return null;
  }
}

/// First-run / re-entry setup dialog.  Mirrors Python's `SetupDialog`
/// (RR_VHS_Tool.py:6211-6798): four required path fields, optional
/// dev-mode toggle, save disabled until every path resolves.
///
/// Open via [SetupDialog.show] — handles loading the current config,
/// presenting the modal, and invalidating dependent providers on save.
class SetupDialog extends ConsumerStatefulWidget {
  final AppConfig initial;

  /// When false, the user MUST save to dismiss — no close button rendered,
  /// no Android-back / Escape exit.  First-launch flow uses this so the
  /// app can't reach HomePage with an invalid config.  Python's first-run
  /// path has the same property (RR_VHS_Tool.py:14997-15008 — root stays
  /// withdrawn until `_save` succeeds).
  final bool dismissible;

  const SetupDialog._({required this.initial, required this.dismissible});

  /// Open the dialog, returning true when the user saved.  Loads the
  /// current config first so existing values pre-fill the fields.
  ///
  /// [dismissible] defaults to true (returning user amending paths).  Pass
  /// false from the first-launch gate so the user can't dismiss without
  /// saving — Python parity (RR_VHS_Tool.py:14997-15008).
  static Future<bool> show(
    BuildContext context,
    WidgetRef ref, {
    bool dismissible = true,
  }) async {
    final initial = await ref.read(configRepositoryProvider).load();
    if (!context.mounted) return false;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SetupDialog._(initial: initial, dismissible: dismissible),
    );
    if (saved == true) {
      // Refresh every provider that depends on config / paths.
      ref.invalidate(configFutureProvider);
      ref.invalidate(layoutPreloadProvider);
    }
    return saved == true;
  }

  @override
  ConsumerState<SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends ConsumerState<SetupDialog>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _texconv;
  late final TextEditingController _repak;
  late final TextEditingController _basePak;
  late final TextEditingController _modsFolder;
  late bool _devMode;
  bool _saving = false;

  /// H5 — inline status from the last AUTO-DETECT press.  Null until the
  /// user presses; cleared again 3s after a fully-OK press.  Persists
  /// indefinitely while any subgroup is `missing` so the user can read it.
  AutoDetectClassification? _autoStatus;
  bool _autoModsCreated = false;

  /// Consecutive `missing` outcomes per subgroup.  When either hits 2 we
  /// flash the corresponding row red→bright to draw attention (Python
  /// `_auto_detect_tools` repeat-press escalation, RR_VHS_Tool.py:7181-7236).
  int _toolsFailStreak = 0;
  int _gameFailStreak = 0;
  Timer? _autoClearTimer;
  late final AnimationController _flashController;

  /// Versions detected by the texconv / repak rows.  Lifted up here so the
  /// footer status line can render `texconv vX, repak vY` once both
  /// validate (P6).  Null while detection is pending or after a failed
  /// probe; the row reports back via `onVersionDetected`.
  String? _texconvVersion;
  String? _repakVersion;

  /// True while `_autoDetect` is mid-flight — drives the hero banner
  /// `Scanning…` state (P4).  Set true, then we yield a frame so the
  /// hero rebuilds before the (currently sync) Steam scan runs.
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _texconv = TextEditingController(text: widget.initial.texconv);
    _repak = TextEditingController(text: widget.initial.repak);
    _basePak = TextEditingController(text: widget.initial.baseGamePak);
    _modsFolder = TextEditingController(text: widget.initial.modsFolder);
    // Persist dev_mode across sessions — Python parity (M2).
    _devMode = widget.initial.devMode;
    for (final c in [_texconv, _repak, _basePak, _modsFolder]) {
      c.addListener(() => setState(() {}));
    }
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _autoClearTimer?.cancel();
    _flashController.dispose();
    _texconv.dispose();
    _repak.dispose();
    _basePak.dispose();
    _modsFolder.dispose();
    super.dispose();
  }

  /// Snapshot the current field values as an AppConfig.  Used to drive the
  /// disabled-Save label (H6) so the missing-fields list stays consistent
  /// with `isReady` / `missingFields` on the domain entity.
  AppConfig _currentDraft() => AppConfig(
        texconv: _texconv.text,
        repak: _repak.text,
        baseGamePak: _basePak.text,
        modsFolder: _modsFolder.text,
        devMode: _devMode,
      );

  bool get _canSave => _currentDraft().isReady;

  /// Hero-banner state driver (P4).  Pure derivation of `_scanning`,
  /// `_autoStatus`, and the current path readiness — no side effects.
  _HeroState _computeHeroState() {
    if (_scanning) return _HeroState.scanning;
    final readyCount = 4 - _currentDraft().missingFields.length;
    if (readyCount == 4) return _HeroState.complete;
    // Partial covers both "1-3 of 4 are ok" AND "0 of 4 ok after a
    // failed click" — once the user has tried, switching back to the
    // generic CTA copy would be misleading.
    if (readyCount > 0 || _autoStatus != null) return _HeroState.partial;
    return _HeroState.empty;
  }

  /// P8 hint builder — shared by texconv and repak rows.  Both have the
  /// same shape: an .exe whose recovery action is Re-scan (since they
  /// live inside the bundled Tools/ folder; manual Browse is the fall-
  /// through).
  Widget? _toolHint(String exeName, _ValidationKind kind) {
    switch (kind) {
      case _ValidationKind.ok:
      case _ValidationKind.empty:
      case _ValidationKind.dirMissing:
        return null;
      case _ValidationKind.fileMissing:
        return _ActionableHint(
          text: '$exeName was moved or deleted — try ',
          action: (label: 'Re-scan', callback: _autoDetect),
          tail: ', or click Browse to set a new path.',
        );
      case _ValidationKind.basenameMismatch:
        return _ActionableHint(
          text: 'Wrong file — expected $exeName. Try ',
          action: (label: 'Re-scan', callback: _autoDetect),
          tail: ', or pick the correct .exe with Browse.',
        );
    }
  }

  /// P8 hint builder — base-game-pak row.  Recovery action is the
  /// section-level Pick-game-folder (P5) since one click resolves both
  /// this field AND the mods folder underneath the same game root.
  Widget? _basePakHint(_ValidationKind kind) {
    switch (kind) {
      case _ValidationKind.ok:
      case _ValidationKind.empty:
      case _ValidationKind.dirMissing:
        return null;
      case _ValidationKind.fileMissing:
        return _ActionableHint(
          text: 'Not found in Steam libraries. Use ',
          action: (label: 'Pick game folder', callback: _browseGameFolder),
          tail: ', or set the path manually with Browse.',
        );
      case _ValidationKind.basenameMismatch:
        return _ActionableHint(
          text: 'Wrong file — expected $kBaseGamePakBasename. Use ',
          action: (label: 'Pick game folder', callback: _browseGameFolder),
          tail: ' to find it under the game root.',
        );
    }
  }

  /// P8 hint builder — mods-folder row.  Only dir-missing applies (the
  /// row accepts any directory, so basename/file-missing never fire).
  Widget? _modsFolderHint(_ValidationKind kind) {
    switch (kind) {
      case _ValidationKind.ok:
      case _ValidationKind.empty:
      case _ValidationKind.fileMissing:
      case _ValidationKind.basenameMismatch:
        return null;
      case _ValidationKind.dirMissing:
        return _ActionableHint(
          text: 'Directory not found. Use ',
          action: (label: 'Pick game folder', callback: _browseGameFolder),
          tail: ' to set ~mods automatically.',
        );
    }
  }

  /// "⚠ MISSING: texconv.exe, repak.exe, game pak file, mods folder" —
  /// Python `_update_all_status` parity (H6).  Returns the legacy generic
  /// label only when every field somehow has invalid content but no item
  /// flagged missing (shouldn't happen in practice).
  String _missingLabel() {
    final missing = _currentDraft().missingFields;
    if (missing.isEmpty) return 'FILL IN ALL FIELDS TO CONTINUE';
    return '⚠ MISSING: ${missing.join(', ')}';
  }

  Future<void> _autoDetect() async {
    // Flip into the hero's "Scanning…" state and let Flutter rebuild
    // before we start the (currently sync) Steam scan — otherwise the
    // user never sees the scanning copy.  Cheap to do; the body of the
    // scan is < 100 ms in practice but the yield is necessary.
    setState(() => _scanning = true);
    await Future<void>.delayed(Duration.zero);

    // Snapshot field state BEFORE detection — drives the H5 classifier
    // (newlyFound vs alreadyConfigured vs stillMissing per field).  We
    // also check *validity* per field: a non-empty-but-broken path (e.g.
    // user deleted the file externally) must count as "needs detection"
    // rather than alreadyConfigured, otherwise Re-scan reports "already
    // configured — nothing to update" while the row sits in the invalid
    // state.  Treating broken == empty for both the field-fill step and
    // the classifier call fixes that without touching classifyAutoDetect's
    // public API (and the H5 tests stay green).
    final beforeTx = _texconv.text;
    final beforeRp = _repak.text;
    final beforeBp = _basePak.text;
    final beforeMf = _modsFolder.text;
    final txValid = _validatePath(beforeTx, kTexconvBasename).ok;
    final rpValid = _validatePath(beforeRp, kRepakBasename).ok;
    final bpValid = _validatePath(beforeBp, kBaseGamePakBasename).ok;
    final mfValid = _validatePath(beforeMf, null).ok;

    final exeDir = ref.read(workingDirProvider);
    final r = SetupAutoDetect.detectAll(exeDir);
    setState(() {
      if (!txValid && r.texconv != null) _texconv.text = r.texconv!;
      if (!rpValid && r.repak != null) _repak.text = r.repak!;
      if (!bpValid && r.baseGamePak != null) _basePak.text = r.baseGamePak!;
      if (!mfValid && r.modsFolder != null) {
        _modsFolder.text = r.modsFolder!;
      }
    });
    // Auto-create the ~mods directory when we just derived its path —
    // Python parity (`_set_game_folder`, RR_VHS_Tool.py:7345-7366).  Only
    // run when WE set the field; user-typed paths are user-typed.
    var modsCreated = false;
    if (r.modsFolder != null && _modsFolder.text == r.modsFolder) {
      final ensure = SetupAutoDetect.ensureModsFolder(_modsFolder.text);
      modsCreated = ensure.wasCreated;
    }

    final classification = classifyAutoDetect(
      // Pass empty for invalid before-values so the classifier treats
      // them as "needs detection" instead of "already configured".
      beforeTexconv: txValid ? beforeTx : '',
      beforeRepak: rpValid ? beforeRp : '',
      beforeBasePak: bpValid ? beforeBp : '',
      beforeModsFolder: mfValid ? beforeMf : '',
      detected: r,
    );

    // Update per-subgroup consecutive-failure streak.  Hitting 2 in a
    // row triggers the flash escalation below.
    if (classification.toolsOutcome == AutoDetectSubgroupOutcome.missing) {
      _toolsFailStreak++;
    } else {
      _toolsFailStreak = 0;
    }
    if (classification.gameOutcome == AutoDetectSubgroupOutcome.missing) {
      _gameFailStreak++;
    } else {
      _gameFailStreak = 0;
    }

    _autoClearTimer?.cancel();
    setState(() {
      _autoStatus = classification;
      _autoModsCreated = modsCreated;
      _scanning = false;
    });

    if (_toolsFailStreak >= 2 || _gameFailStreak >= 2) {
      unawaited(_runFlash());
    }

    // Auto-fade success-only status after 3s; persist missing-status
    // indefinitely so the user can read which fields still need attention.
    if (!classification.anyMissing) {
      _autoClearTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _autoStatus = null);
      });
    }
  }

  /// 3-cycle red↔bright flash to escalate repeated AUTO-DETECT failures.
  /// Drives `_AutoDetectStatusPanel`'s flashing colour via the shared
  /// controller.  Bails out if the dialog unmounts mid-animation.
  Future<void> _runFlash() async {
    for (var i = 0; i < 3; i++) {
      if (!mounted) return;
      await _flashController.forward(from: 0);
      if (!mounted) return;
      await _flashController.reverse();
    }
  }

  /// Single-pick "find my game" flow.  User points at any of {game root,
  /// `RetroRewind/`, `Content/Paks/`, the pak file itself} and we fill BOTH
  /// `baseGamePak` and `modsFolder` from one click.  Auto-creates `~mods`
  /// if the pak resolves but the directory doesn't exist yet (H2 parity).
  /// Mirrors Python's `_browse_game_folder` (RR_VHS_Tool.py:7368-7392).
  Future<void> _browseGameFolder() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Pick game folder, RetroRewind/, or Content/Paks/',
    );
    if (picked == null) return;
    final resolved = SetupAutoDetect.resolveGameFolderPick(picked);
    if (resolved.baseGamePak == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kColorPanel,
        duration: const Duration(seconds: 4),
        content: const Text(
          'Could not find RetroRewind-Windows.pak under that folder.',
          style: TextStyle(color: kColorPink, fontFamily: kFontFamily),
        ),
      ));
      return;
    }
    final ensure = SetupAutoDetect.ensureModsFolder(resolved.modsFolder!);
    setState(() {
      _basePak.text = resolved.baseGamePak!;
      _modsFolder.text = resolved.modsFolder!;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: kColorPanel,
      duration: const Duration(seconds: 3),
      content: Text(
        ensure.wasCreated
            ? 'Game folder resolved (~mods created).'
            : 'Game folder resolved.',
        style: const TextStyle(color: kColorCyan, fontFamily: kFontFamily),
      ),
    ));
  }

  Future<void> _pickFile(TextEditingController c, String title,
      List<String> exts) async {
    final r = await FilePicker.platform.pickFiles(
      type: exts.isEmpty ? FileType.any : FileType.custom,
      allowedExtensions: exts.isEmpty ? null : exts,
      dialogTitle: title,
    );
    final path = r?.files.single.path;
    if (path != null) c.text = path;
  }

  Future<void> _pickDir(TextEditingController c, String title) async {
    final r = await FilePicker.platform.getDirectoryPath(dialogTitle: title);
    if (r != null) c.text = r;
  }

  Future<void> _save() async {
    if (!_canSave || _saving) return;
    setState(() => _saving = true);
    final cfg = _currentDraft();
    try {
      await ref.read(configRepositoryProvider).save(cfg);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: kColorPanel,
          content: Text('Save failed: $e',
              style: const TextStyle(color: kColorPink)),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Block Android-back / Escape from popping when not dismissible.  The
    // close button is also hidden in the header — together that means the
    // only exit from a first-launch dialog is a successful `_save`.
    return PopScope(
      canPop: widget.dismissible,
      child: Dialog(
        backgroundColor: kColorPanel,
        shape: const RoundedRectangleBorder(),
        insetPadding: const EdgeInsets.all(kSp6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(kSp4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  onClose: widget.dismissible
                      ? () => Navigator.of(context).pop(false)
                      : null,
                ),
                const SizedBox(height: kSp4),
                // Scrollable middle — prevents bottom-overflow when the
                // window is shorter than the intrinsic content height.
                // Header (above) and Save button (below) stay fixed as
                // anchors; this also sets up the sticky-footer structure
                // that P6 will turn into a proper modal footer.
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _AutoDetectHero(
                          state: _computeHeroState(),
                          readyCount:
                              4 - _currentDraft().missingFields.length,
                          onPressed: _scanning ? null : _autoDetect,
                        ),
                        if (_autoStatus != null) ...[
                          const SizedBox(height: kSp2),
                          _AutoDetectStatusPanel(
                            classification: _autoStatus!,
                            modsCreated: _autoModsCreated,
                            flashController: _flashController,
                            toolsFlashing: _toolsFailStreak >= 2,
                            gameFlashing: _gameFailStreak >= 2,
                          ),
                        ],
                        const SizedBox(height: kSp4),
                        // ── Section 1: Workshop tools ─────────────────────
                        _SectionHeader(
                          title: 'WORKSHOP TOOLS',
                          subtitle:
                              'Bundled with this download. Found inside the unzipped folder.',
                          verified: [
                            _validatePath(_texconv.text, kTexconvBasename).ok,
                            _validatePath(_repak.text, kRepakBasename).ok,
                          ].where((ok) => ok).length,
                          total: 2,
                        ),
                        const SizedBox(height: kSp2),
                        _PathRow(
                          label: 'texconv',
                          description: _kDescTexconv,
                          hint: kTexconvBasename,
                          controller: _texconv,
                          expectedBasename: kTexconvBasename,
                          onBrowse: () => _pickFile(_texconv,
                              'Pick $kTexconvBasename', const ['exe']),
                          // No flag — texconv prints a banner with the
                          // DirectXTex version when called without args.
                          versionDetector: (p) => _detectExeVersion(p, const []),
                          onVersionDetected: (v) =>
                              setState(() => _texconvVersion = v),
                          hintBuilder: (k) => _toolHint(kTexconvBasename, k),
                        ),
                        const SizedBox(height: kSp3),
                        _PathRow(
                          label: 'repak',
                          description: _kDescRepak,
                          hint: kRepakBasename,
                          controller: _repak,
                          expectedBasename: kRepakBasename,
                          onBrowse: () => _pickFile(
                              _repak, 'Pick $kRepakBasename', const ['exe']),
                          versionDetector: (p) =>
                              _detectExeVersion(p, const ['--version']),
                          onVersionDetected: (v) =>
                              setState(() => _repakVersion = v),
                          hintBuilder: (k) => _toolHint(kRepakBasename, k),
                        ),
                        const SizedBox(height: kSp4),
                        // ── Section 2: Retro Rewind install ───────────────
                        _SectionHeader(
                          title: 'RETRO REWIND INSTALL',
                          subtitle: 'Where you installed the game on this PC.',
                          verified: [
                            _validatePath(_basePak.text, kBaseGamePakBasename)
                                .ok,
                            _validatePath(_modsFolder.text, null).ok,
                          ].where((ok) => ok).length,
                          total: 2,
                          action: _PickGameFolderButton(
                            onPressed: _browseGameFolder,
                          ),
                        ),
                        const SizedBox(height: kSp2),
                        _PathRow(
                          label: 'Base game pak',
                          description: _kDescBasePak,
                          hint: kBaseGamePakBasename,
                          controller: _basePak,
                          expectedBasename: kBaseGamePakBasename,
                          onBrowse: () => _pickFile(_basePak,
                              'Pick $kBaseGamePakBasename', const ['pak']),
                          infoDetector: _formatFileSize,
                          hintBuilder: _basePakHint,
                        ),
                        const SizedBox(height: kSp3),
                        _PathRow(
                          label: 'Mods folder',
                          description: _kDescModsFolder,
                          hint: '…/Paks/~mods',
                          controller: _modsFolder,
                          expectedBasename: null,
                          onBrowse: () =>
                              _pickDir(_modsFolder, 'Pick ~mods directory'),
                          infoDetector: _summarizeDir,
                          hintBuilder: _modsFolderHint,
                        ),
                        const SizedBox(height: kSp4),
                        _AdvancedDisclosure(
                          child: CheckboxListTile(
                            value: _devMode,
                            onChanged: (v) =>
                                setState(() => _devMode = v ?? false),
                            title: const Text('Developer mode',
                                style: TextStyle(
                                    fontFamily: kFontFamily,
                                    fontSize: kFsBody,
                                    fontWeight: FontWeight.w600,
                                    color: kColorText)),
                            subtitle: const Text(
                                'Extra logging, internal diagnostics panel, and raw build output.',
                                style: TextStyle(
                                    fontFamily: kFontFamily,
                                    fontSize: kFsMeta,
                                    color: kColorText3)),
                            controlAffinity:
                                ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            checkColor: kColorTextInv,
                            activeColor: kColorCyan,
                            dense: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: kSp3),
                // Sticky footer (P6) — status line on the left, Cancel +
                // Continue on the right.  Recessed background + top
                // border act as the visual separator from the scrollable
                // body above; the dialog's outer kSp4 padding still
                // insets the footer from the dialog edges (a clean
                // "panel-style footer", not flush — flush would need a
                // bigger Dialog/Padding restructure).
                Container(
                  decoration: const BoxDecoration(
                    color: kColorBg,
                    border: Border(top: BorderSide(color: kColorBorder)),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: kSp3, vertical: kSp3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: _FooterStatus(
                          missing: _currentDraft().missingFields,
                          saving: _saving,
                          texconvVersion: _texconvVersion,
                          repakVersion: _repakVersion,
                        ),
                      ),
                      if (widget.dismissible) ...[
                        OutlinedButton(
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: kColorText2,
                            side: const BorderSide(color: kColorBorder),
                            shape: const RoundedRectangleBorder(),
                            visualDensity: VisualDensity.compact,
                          ),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: kSp2),
                      ],
                      Tooltip(
                        message: _canSave ? '' : _missingLabel(),
                        child: ElevatedButton.icon(
                          onPressed: _canSave && !_saving ? _save : null,
                          icon: const Icon(Icons.keyboard_return, size: 14),
                          label: Text(_saving ? 'Saving…' : 'Continue'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kColorCyan,
                            foregroundColor: kColorTextInv,
                            disabledBackgroundColor: kColorDisabled,
                            disabledForegroundColor: kColorText3,
                            shape: const RoundedRectangleBorder(),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ),
      ),
    ),
    );
  }
}

class _Header extends StatelessWidget {
  /// When null, no close button is rendered — first-launch flow uses this
  /// so the user can only exit via a successful `_save`.
  final VoidCallback? onClose;
  const _Header({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'SETUP',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: kFsApp,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: kColorPink,
            ),
          ),
        ),
        if (onClose != null)
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, size: 18),
            color: kColorText3,
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

/// Section header used by P1 — title in uppercase mono with a counter
/// pill (X / Y verified) plus a subtitle line below.  Pure layout widget;
/// the verified count is computed in `_SetupDialogState.build` so it
/// stays in sync with whatever the rows show.
///
/// Optional [action] is rendered on the far right of the title row —
/// P5 uses it to attach the "Pick game folder" button to the
/// "RETRO REWIND INSTALL" section.
class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final int verified;
  final int total;
  final Widget? action;

  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.verified,
    required this.total,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: kFsMeta,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w600,
                color: kColorText2,
              ),
            ),
            const SizedBox(width: kSp2),
            _CounterPill(verified: verified, total: total),
            if (action != null) ...[
              const Spacer(),
              action!,
            ],
          ],
        ),
        const SizedBox(height: kSp1),
        Text(
          subtitle,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: kFsMeta,
            color: kColorText3,
          ),
        ),
      ],
    );
  }
}

/// `X / Y` mono pill next to a section title.  Cyan when the section is
/// fully verified, border-grey otherwise.  Flat/sharp — no rounded corners,
/// no fill (per app_theme.dart's "no shadows, no blur, no gradients" rule).
class _CounterPill extends StatelessWidget {
  final int verified;
  final int total;

  const _CounterPill({required this.verified, required this.total});

  @override
  Widget build(BuildContext context) {
    final allOk = verified == total;
    final colour = allOk ? kColorCyan : kColorText3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kSp2, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: allOk ? kColorCyan : kColorBorder),
      ),
      child: Text(
        '$verified / $total',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: kFsMeta,
          color: colour,
        ),
      ),
    );
  }
}

/// Section-action button attached to the "Retro Rewind install" header
/// (P5) — the convenience entry point that resolves both Base Pak AND
/// Mods folder from a single directory pick.  Replaces the standalone
/// BROWSE GAME FOLDER button that lived under the hero before P5.
///
/// Ghost style: transparent fill, subtle border, secondary text colour
/// — visually quieter than the hero's primary action since it's a
/// shortcut, not the headline CTA.
class _PickGameFolderButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _PickGameFolderButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.folder_open, size: 12),
      label: const Text('Pick game folder'),
      style: OutlinedButton.styleFrom(
        foregroundColor: kColorText2,
        side: const BorderSide(color: kColorBorder),
        shape: const RoundedRectangleBorder(),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: kSp2, vertical: 2),
        textStyle: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: kFsMeta,
        ),
      ),
    );
  }
}

class _PathRow extends StatefulWidget {
  final String label;
  final String description;
  final String hint;
  final TextEditingController controller;
  /// When non-null, the picked file's basename must match (case-insensitive)
  /// — protects against e.g. picking `repak.exe` for the texconv field.
  /// When null, the row validates as "any existing directory".
  final String? expectedBasename;
  final VoidCallback onBrowse;

  /// Optional async version probe — run when the path validates ok.
  /// Result is shown in the info pill next to the row title.  Cached
  /// per path; never re-runs for the same string.
  final Future<String?> Function(String path)? versionDetector;

  /// Optional sync info probe — falls back when [versionDetector] is null
  /// or returned null.  Used for base-pak (file size) and mods-folder
  /// (entry count), both of which are cheap and always available.
  final String? Function(String path)? infoDetector;

  /// Fires every time [versionDetector] resolves — including with null
  /// (failed probe) and on text-edits that invalidate a cached version.
  /// The footer status line (P6) listens on the texconv/repak rows so it
  /// can render `texconv vX, repak vY` when everything is ready.
  final ValueChanged<String?>? onVersionDetected;

  /// Builds the per-row actionable hint (P8) shown under the path pill
  /// when validation fails.  Receives the [_ValidationKind] so the
  /// builder can speak to the specific failure (missing vs wrong-name
  /// vs wrong-folder) with row-appropriate copy and inline action.
  /// Return null to show no hint for a given kind.
  final Widget? Function(_ValidationKind kind)? hintBuilder;

  const _PathRow({
    required this.label,
    required this.description,
    required this.hint,
    required this.controller,
    required this.expectedBasename,
    required this.onBrowse,
    this.versionDetector,
    this.infoDetector,
    this.onVersionDetected,
    this.hintBuilder,
  });

  @override
  State<_PathRow> createState() => _PathRowState();
}

class _PathRowState extends State<_PathRow> {
  /// Last detected async version string.  Null while detection is pending
  /// or after a failed probe.  Cleared on every controller-text change.
  String? _detectedVersion;

  /// Path the cached version was detected for — guards against an old
  /// async result landing after the user re-edited the field.
  String? _detectedFor;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    _maybeDetectVersion();
  }

  @override
  void didUpdateWidget(_PathRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChange);
      widget.controller.addListener(_onControllerChange);
    }
    _maybeDetectVersion();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() {
    // Clear stale version the instant the text changes; a fresh probe
    // fires only if the new value validates ok.
    if (_detectedVersion != null && widget.controller.text != _detectedFor) {
      setState(() {
        _detectedVersion = null;
        _detectedFor = null;
      });
      widget.onVersionDetected?.call(null);
    }
    _maybeDetectVersion();
  }

  Future<void> _maybeDetectVersion() async {
    final probe = widget.versionDetector;
    if (probe == null) return;
    final path = widget.controller.text;
    if (path == _detectedFor) return;
    final v = _validatePath(path, widget.expectedBasename);
    if (!v.ok) return;
    final version = await probe(path);
    if (!mounted) return;
    if (widget.controller.text != path) return; // user moved on
    setState(() {
      _detectedVersion = version;
      _detectedFor = path;
    });
    widget.onVersionDetected?.call(version);
  }

  @override
  Widget build(BuildContext context) {
    final v = _validatePath(widget.controller.text, widget.expectedBasename);
    final pillText = v.ok
        ? (_detectedVersion ?? widget.infoDetector?.call(widget.controller.text))
        : null;
    final state = widget.controller.text.isEmpty
        ? _StatusKind.empty
        : (v.ok ? _StatusKind.verified : _StatusKind.invalid);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // Nudge the indicator down so it lines up with the row title
          // baseline rather than the strict top of the column.
          padding: const EdgeInsets.only(top: 1),
          child: _StatusIndicator(state: state),
        ),
        const SizedBox(width: kSp2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: kFsBody,
                        fontWeight: FontWeight.w700,
                        color: kColorText,
                      ),
                    ),
                  ),
                  if (pillText != null) ...[
                    const SizedBox(width: kSp2),
                    _InfoPill(text: pillText),
                  ],
                ],
              ),
              const SizedBox(height: kSp1),
              Text(
                widget.description,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: kFsMeta,
                  color: kColorText3,
                ),
              ),
              const SizedBox(height: kSp2),
              _PathBreadcrumb(
                controller: widget.controller,
                placeholder: widget.expectedBasename == null
                    ? 'Drop a folder here, or click Browse'
                    : 'Drop a file here, or click Browse',
                state: state,
                onTap: widget.onBrowse,
                onDropped: (path) {
                  widget.controller.text = path;
                },
              ),
              if (!v.ok &&
                  widget.controller.text.isNotEmpty &&
                  widget.hintBuilder != null)
                widget.hintBuilder!(v.kind) ?? const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Three-state validation indicator shown on the LEFT of each path row
/// (P2).  Square per the theme's "no rounded corners" rule; the icon
/// inside conveys the state at a glance:
///   - verified → cyan fill + dark check
///   - invalid  → pink fill + dark X
///   - empty    → transparent fill, grey outline (no icon)
enum _StatusKind { verified, invalid, empty }

class _StatusIndicator extends StatelessWidget {
  final _StatusKind state;
  const _StatusIndicator({required this.state});

  @override
  Widget build(BuildContext context) {
    final (Color fill, Color border, IconData? icon, String tip) =
        switch (state) {
      _StatusKind.verified => (kColorCyan, kColorCyan, Icons.check, 'Verified'),
      _StatusKind.invalid => (kColorPink, kColorPink, Icons.close, 'Invalid'),
      _StatusKind.empty => (Colors.transparent, kColorBorder, null, 'Not set'),
    };
    return Tooltip(
      message: tip,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border, width: 1),
        ),
        alignment: Alignment.center,
        child: icon == null
            ? null
            : Icon(icon, size: 12, color: kColorTextInv),
      ),
    );
  }
}

/// Small mono pill rendered next to a row title when verified (P2).
/// Shows the detected exe version, file size, or directory summary
/// depending on which detector the row was wired with.  Cyan border +
/// cyan text on a dark fill — flat/sharp, no rounded corners.
class _InfoPill extends StatelessWidget {
  final String text;
  const _InfoPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: kColorSurface,
        border: Border.all(color: kColorCyan),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: kFsMeta,
          color: kColorCyan,
          height: 1.2,
        ),
      ),
    );
  }
}

/// Clickable path display with middle-truncated breadcrumb segments (P3).
/// Replaces the per-row TextField + BROWSE button — the entire pill is
/// one combined widget: breadcrumb on the left, vertical divider, Browse
/// action on the right, shared outline.  Click anywhere → opens the
/// file/folder picker via [onTap].  Drag-drop from the OS file manager
/// → [onDropped] with the first dropped path.
///
/// Trade-off: removes direct keyboard paste/edit of the path string.
/// Users set paths via Auto-Detect, the per-row Browse action, the
/// section-level Pick-game-folder (P5), or OS drag-drop.  If a power
/// user really needs to paste, a future P8 hint can offer it explicitly.
class _PathBreadcrumb extends StatefulWidget {
  final TextEditingController controller;
  final String placeholder;
  final _StatusKind state;
  final VoidCallback onTap;
  final ValueChanged<String> onDropped;

  const _PathBreadcrumb({
    required this.controller,
    required this.placeholder,
    required this.state,
    required this.onTap,
    required this.onDropped,
  });

  @override
  State<_PathBreadcrumb> createState() => _PathBreadcrumbState();
}

class _PathBreadcrumbState extends State<_PathBreadcrumb> {
  bool _dragHover = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(_PathBreadcrumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Outline shifts to cyan during drag-over OR when the path is
    // already verified, so the pill itself encodes the same state the
    // left-edge status indicator does — redundant but reassuring.
    final Color borderColour;
    if (_dragHover) {
      borderColour = kColorCyan;
    } else if (widget.state == _StatusKind.invalid) {
      borderColour = kColorPink;
    } else {
      borderColour = kColorBorder;
    }
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragHover = true),
      onDragExited: (_) => setState(() => _dragHover = false),
      onDragDone: (details) {
        setState(() => _dragHover = false);
        if (details.files.isEmpty) return;
        widget.onDropped(details.files.first.path);
      },
      child: Container(
        decoration: BoxDecoration(
          color: kColorSurface,
          border: Border.all(color: borderColour),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: InkWell(
                  onTap: widget.onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: kSp2, vertical: kSp2),
                    child: widget.controller.text.isEmpty
                        ? Text(
                            widget.placeholder,
                            style: const TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: kFsBody,
                              color: kColorText3,
                              fontStyle: FontStyle.italic,
                            ),
                          )
                        : _buildBreadcrumb(widget.controller.text),
                  ),
                ),
              ),
              Container(width: 1, color: kColorBorder),
              InkWell(
                onTap: widget.onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: kSp2, vertical: kSp2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.folder_open, size: 14, color: kColorText2),
                      SizedBox(width: kSp1),
                      Text(
                        'Browse',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: kFsBody,
                          color: kColorText2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build the segment row for a non-empty path.  Splits on the
  /// platform separator, then shows either all segments (≤3) or
  /// `first › … › secondLast › leaf` (>3).  The leaf is bold and high-
  /// contrast; everything else is dimmed.  Full path on hover via
  /// the surrounding Tooltip.
  Widget _buildBreadcrumb(String fullPath) {
    final segments = p.split(fullPath).where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      return Text(
        fullPath,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: kFsBody,
          color: kColorText,
        ),
      );
    }
    final spans = <InlineSpan>[];
    if (segments.length > 3) {
      _addSegment(spans, segments.first, isLeaf: false);
      _addSeparator(spans);
      _addSegment(spans, '…', isLeaf: false);
      _addSeparator(spans);
      _addSegment(spans, segments[segments.length - 2], isLeaf: false);
      _addSeparator(spans);
      _addSegment(spans, segments.last, isLeaf: true);
    } else {
      for (var i = 0; i < segments.length; i++) {
        if (i > 0) _addSeparator(spans);
        _addSegment(spans, segments[i], isLeaf: i == segments.length - 1);
      }
    }
    return Tooltip(
      message: fullPath,
      waitDuration: const Duration(milliseconds: 400),
      child: Text.rich(
        TextSpan(children: spans),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  static void _addSegment(List<InlineSpan> out, String text,
      {required bool isLeaf}) {
    out.add(TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: kFontFamily,
        fontSize: kFsBody,
        color: isLeaf ? kColorText : kColorText3,
        fontWeight: isLeaf ? FontWeight.w700 : FontWeight.normal,
      ),
    ));
  }

  static void _addSeparator(List<InlineSpan> out) {
    out.add(const TextSpan(
      text: ' › ',
      style: TextStyle(
        fontFamily: kFontFamily,
        fontSize: kFsBody,
        color: kColorText3,
      ),
    ));
  }
}

/// Inline status panel rendered below the AUTO-DETECT / BROWSE row after
/// any AUTO-DETECT press.  Shows two lines (tools, game) classified
/// independently by [classifyAutoDetect] (H5) — cyan when the subgroup
/// resolved, dimmed when already-configured, pink/missing-list when
/// stillMissing.  When the same subgroup misses twice in a row the
/// caller drives [flashController]; we lerp toward bright-red while
/// the controller animates.
class _AutoDetectStatusPanel extends StatelessWidget {
  final AutoDetectClassification classification;
  final bool modsCreated;
  final AnimationController flashController;
  final bool toolsFlashing;
  final bool gameFlashing;

  const _AutoDetectStatusPanel({
    required this.classification,
    required this.modsCreated,
    required this.flashController,
    required this.toolsFlashing,
    required this.gameFlashing,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: flashController,
      builder: (context, _) {
        final t = flashController.value;
        // Pink → bright red.  Same anchor for both rows; per-row flag
        // decides whether to use the animated colour or stay on plain pink.
        final flashColour = Color.lerp(kColorPink, const Color(0xFFFF4040), t)!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AutoStatusLine(
              label: 'TOOLS',
              outcome: classification.toolsOutcome,
              missingLabels: classification.toolsMissingLabels,
              flashing: toolsFlashing,
              flashColour: flashColour,
            ),
            const SizedBox(height: kSp1),
            _AutoStatusLine(
              label: 'GAME',
              outcome: classification.gameOutcome,
              missingLabels: classification.gameMissingLabels,
              flashing: gameFlashing,
              flashColour: flashColour,
              modsCreatedTag:
                  modsCreated &&
                          classification.gameOutcome !=
                              AutoDetectSubgroupOutcome.missing
                      ? '(~mods created)'
                      : null,
            ),
          ],
        );
      },
    );
  }
}

class _AutoStatusLine extends StatelessWidget {
  final String label;
  final AutoDetectSubgroupOutcome outcome;
  final List<String> missingLabels;
  final bool flashing;
  final Color flashColour;
  final String? modsCreatedTag;

  const _AutoStatusLine({
    required this.label,
    required this.outcome,
    required this.missingLabels,
    required this.flashing,
    required this.flashColour,
    this.modsCreatedTag,
  });

  @override
  Widget build(BuildContext context) {
    final (Color colour, String message) = switch (outcome) {
      AutoDetectSubgroupOutcome.newlyResolved => (
          kColorCyan,
          'auto-detected successfully${modsCreatedTag != null ? ' $modsCreatedTag' : ''}',
        ),
      AutoDetectSubgroupOutcome.alreadyConfigured => (
          kColorText3,
          'already configured — nothing to update',
        ),
      AutoDetectSubgroupOutcome.missing => (
          flashing ? flashColour : kColorPink,
          'could not auto-detect: ${missingLabels.join(', ')} — please browse manually',
        ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: kFsMeta,
              letterSpacing: 1.5,
              color: kColorText2,
            ),
          ),
        ),
        Expanded(
          child: Text(
            message,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: kFsMeta,
              color: colour,
            ),
          ),
        ),
      ],
    );
  }
}

/// Footer status line (P6) — left-side text shown next to the Cancel /
/// Continue buttons.  Three states:
///   - saving → cyan dot + "Saving…"
///   - ready  → cyan dot + "All 4 paths verified" (+ versions if known)
///   - else   → gold dot + "X of 4 paths ready · Y missing"
class _FooterStatus extends StatelessWidget {
  final List<String> missing;
  final bool saving;
  final String? texconvVersion;
  final String? repakVersion;

  const _FooterStatus({
    required this.missing,
    required this.saving,
    required this.texconvVersion,
    required this.repakVersion,
  });

  @override
  Widget build(BuildContext context) {
    final ready = missing.isEmpty;
    final Color dotColour;
    final String text;
    if (saving) {
      dotColour = kColorCyan;
      text = 'Saving…';
    } else if (ready) {
      dotColour = kColorCyan;
      final parts = <String>[
        if (texconvVersion != null) 'texconv $texconvVersion',
        if (repakVersion != null) 'repak $repakVersion',
      ];
      text = parts.isEmpty
          ? 'All 4 paths verified'
          : 'All 4 paths verified · ${parts.join(', ')}';
    } else {
      dotColour = kColorGold;
      final readyCount = 4 - missing.length;
      text = '$readyCount of 4 paths ready · ${missing.length} missing';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(width: 8, height: 8, color: dotColour),
        const SizedBox(width: kSp2),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: kFsMeta,
              color: kColorText2,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}

/// Hero banner state — pure data, no UI implications.  Computed every
/// build from `_scanning` + path readiness + `_autoStatus`.
enum _HeroState { empty, partial, complete, scanning }

/// Top-of-dialog Auto-Detect banner (P4) — replaces the bare
/// AUTO-DETECT button.  Sparkle icon block on the left, dynamic title
/// + subtitle in the middle, primary action on the right.  Flat cyan-
/// border surface (no gradient — the design system forbids it).
class _AutoDetectHero extends StatelessWidget {
  final _HeroState state;
  final int readyCount;
  final VoidCallback? onPressed;

  const _AutoDetectHero({
    required this.state,
    required this.readyCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final (String title, String subtitle, String buttonLabel,
        IconData buttonIcon, bool buttonEnabled) = switch (state) {
      _HeroState.scanning => (
          'Scanning your system…',
          'Checking Steam libraries, common Tools folder, registry…',
          'Scanning…',
          Icons.auto_awesome,
          false,
        ),
      _HeroState.complete => (
          'Everything detected.',
          'All paths verified ✓',
          'Re-scan',
          Icons.refresh,
          true,
        ),
      _HeroState.partial => (
          'Found $readyCount of 4 paths.',
          readyCount == 0
              ? 'Set the missing fields manually below.'
              : 'Found $readyCount of 4 paths. Set the missing fields manually below.',
          'Auto-detect',
          Icons.auto_awesome,
          true,
        ),
      _HeroState.empty => (
          'Detect everything automatically',
          'Checks Steam libraries, the bundled Tools folder, and common install locations.',
          'Auto-detect',
          Icons.auto_awesome,
          true,
        ),
    };
    return Container(
      padding: const EdgeInsets.all(kSp3),
      decoration: BoxDecoration(
        color: kColorSurface,
        border: Border.all(color: kColorCyan),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 36×36 icon block — flat panel with cyan outline + cyan sparkle.
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: kColorPanel,
              border: Border.all(color: kColorCyan),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.auto_awesome,
                color: kColorCyan, size: 20),
          ),
          const SizedBox(width: kSp3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: kFsBody,
                    fontWeight: FontWeight.w700,
                    color: kColorText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: kFsMeta,
                    color: kColorText3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: kSp3),
          OutlinedButton.icon(
            onPressed: buttonEnabled ? onPressed : null,
            icon: Icon(buttonIcon, size: 16),
            label: Text(buttonLabel),
            style: OutlinedButton.styleFrom(
              foregroundColor: kColorCyan,
              disabledForegroundColor: kColorDisabled,
              side: const BorderSide(color: kColorCyan),
              shape: const RoundedRectangleBorder(),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsible "ADVANCED" section (P7).  Tucks the Dev Mode checkbox
/// (and any future opt-in toggles) under a chevron-disclosed header so
/// first-time users never see it unless they go looking.  Collapsed by
/// default — matches the briefing's intent.
///
/// Header style mirrors `_SectionHeader` (mono uppercase, letter-spaced
/// kColorText2) so the disclosure visually belongs to the same family
/// as the WORKSHOP TOOLS / RETRO REWIND INSTALL section headers above.
class _AdvancedDisclosure extends StatefulWidget {
  final Widget child;

  const _AdvancedDisclosure({required this.child});

  @override
  State<_AdvancedDisclosure> createState() => _AdvancedDisclosureState();
}

class _AdvancedDisclosureState extends State<_AdvancedDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: kSp1),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeInOut,
                  child: const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: kColorText3,
                  ),
                ),
                const SizedBox(width: kSp1),
                const Text(
                  'ADVANCED',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: kFsMeta,
                    letterSpacing: 1.8,
                    fontWeight: FontWeight.w600,
                    color: kColorText2,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: kSp4, top: kSp1),
            child: widget.child,
          ),
      ],
    );
  }
}

/// One-line actionable hint shown under a path pill (P8).  Renders as
/// `× <text> <Action> <tail>` with the action as an underlined cyan
/// link that fires the supplied callback on click.  Plain pink text
/// otherwise — same colour as the old generic warnings so the visual
/// weight matches the row's left-edge invalid status indicator.
class _ActionableHint extends StatelessWidget {
  final String text;
  final ({String label, VoidCallback callback})? action;
  final String? tail;

  const _ActionableHint({
    required this.text,
    this.action,
    this.tail,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: kSp1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.close, size: 12, color: kColorPink),
          ),
          const SizedBox(width: kSp1),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: kFsMeta,
                  color: kColorPink,
                ),
                children: [
                  TextSpan(text: text),
                  if (action != null)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: _HintLink(
                        label: action!.label,
                        onTap: action!.callback,
                      ),
                    ),
                  if (tail != null) TextSpan(text: tail),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline clickable link inside an [_ActionableHint] (P8).  Underlined
/// cyan text with a pointer cursor on hover.  Wrapped in WidgetSpan so
/// the hint reads as one continuous sentence rather than a button row.
class _HintLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _HintLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: kFsMeta,
            color: kColorCyan,
            decoration: TextDecoration.underline,
            decorationColor: kColorCyan,
          ),
        ),
      ),
    );
  }
}
