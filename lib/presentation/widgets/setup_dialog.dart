import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/app_theme.dart';
import '../../data/services/setup_autodetect.dart';
import '../../domain/entities/app_config.dart';
import '../providers/providers.dart';

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

class _SetupDialogState extends ConsumerState<SetupDialog> {
  late final TextEditingController _texconv;
  late final TextEditingController _repak;
  late final TextEditingController _basePak;
  late final TextEditingController _modsFolder;
  late bool _devMode;
  bool _saving = false;

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
  }

  @override
  void dispose() {
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
    final exeDir = ref.read(workingDirProvider);
    final r = SetupAutoDetect.detectAll(exeDir);
    setState(() {
      if (_texconv.text.isEmpty && r.texconv != null) _texconv.text = r.texconv!;
      if (_repak.text.isEmpty && r.repak != null) _repak.text = r.repak!;
      if (_basePak.text.isEmpty && r.baseGamePak != null) {
        _basePak.text = r.baseGamePak!;
      }
      if (_modsFolder.text.isEmpty && r.modsFolder != null) {
        _modsFolder.text = r.modsFolder!;
      }
    });
    // Auto-create the ~mods directory when we just derived its path —
    // Python parity (`_set_game_folder`, RR_VHS_Tool.py:7345-7366).  The
    // engine expects the dir to exist before it loads any pak from there,
    // and without this the user's _canSave gate fails and they have to
    // create the folder manually.  Only run when we set the field
    // ourselves; user-typed paths are user-typed.
    var modsCreated = false;
    if (r.modsFolder != null && _modsFolder.text == r.modsFolder) {
      final ensure = SetupAutoDetect.ensureModsFolder(_modsFolder.text);
      modsCreated = ensure.wasCreated;
    }
    final found = [
      if (r.texconv != null) 'texconv',
      if (r.repak != null) 'repak',
      if (r.baseGamePak != null) 'base pak',
      if (r.modsFolder != null) modsCreated ? '~mods (created)' : '~mods',
    ];
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kColorPanel,
        duration: const Duration(seconds: 3),
        content: Text(
          found.isEmpty
              ? 'Auto-detect found nothing.'
              : 'Auto-detect filled: ${found.join(", ")}.',
          style: const TextStyle(color: kColorCyan, fontFamily: kFontFamily),
        ),
      ));
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
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _autoDetect,
                    icon: const Icon(Icons.auto_fix_high, size: 16),
                    label: const Text('AUTO-DETECT'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kColorCyan,
                      side: const BorderSide(color: kColorCyan),
                      shape: const RoundedRectangleBorder(),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: kSp2),
                  OutlinedButton.icon(
                    onPressed: _browseGameFolder,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('BROWSE GAME FOLDER'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kColorText,
                      side: const BorderSide(color: kColorBorder),
                      shape: const RoundedRectangleBorder(),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: kSp4),
              _PathRow(
                label: 'TEXCONV',
                hint: kTexconvBasename,
                controller: _texconv,
                expectedBasename: kTexconvBasename,
                onBrowse: () => _pickFile(
                    _texconv, 'Pick $kTexconvBasename', const ['exe']),
              ),
              const SizedBox(height: kSp2),
              _PathRow(
                label: 'REPAK',
                hint: kRepakBasename,
                controller: _repak,
                expectedBasename: kRepakBasename,
                onBrowse: () => _pickFile(
                    _repak, 'Pick $kRepakBasename', const ['exe']),
              ),
              const SizedBox(height: kSp2),
              _PathRow(
                label: 'BASE PAK',
                hint: kBaseGamePakBasename,
                controller: _basePak,
                expectedBasename: kBaseGamePakBasename,
                onBrowse: () => _pickFile(
                    _basePak, 'Pick $kBaseGamePakBasename', const ['pak']),
              ),
              const SizedBox(height: kSp2),
              _PathRow(
                label: 'MODS DIR',
                hint: '…/Paks/~mods',
                controller: _modsFolder,
                expectedBasename: null, // any directory is accepted
                onBrowse: () => _pickDir(_modsFolder, 'Pick ~mods directory'),
              ),
              const SizedBox(height: kSp4),
              CheckboxListTile(
                value: _devMode,
                onChanged: (v) => setState(() => _devMode = v ?? false),
                title: const Text('DEV MODE',
                    style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: kFsBody,
                        color: kColorText)),
                subtitle: const Text('Extra logging + diagnostics',
                    style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: kFsMeta,
                        color: kColorText3)),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                checkColor: kColorTextInv,
                activeColor: kColorCyan,
                dense: true,
              ),
              const SizedBox(height: kSp4),
              SizedBox(
                height: 44,
                child: ElevatedButton(
                  onPressed: _canSave && !_saving ? _save : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kColorCyan,
                    foregroundColor: kColorTextInv,
                    disabledBackgroundColor: kColorDisabled,
                    disabledForegroundColor: kColorText3,
                    shape: const RoundedRectangleBorder(),
                    textStyle: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: kFsBody,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5),
                  ),
                  child: Text(_saving
                      ? 'SAVING…'
                      : _canSave
                          ? 'SETUP COMPLETE — GO TO MAIN MENU'
                          : _missingLabel()),
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

class _PathRow extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  /// When non-null, the picked file's basename must match (case-insensitive)
  /// — protects against e.g. picking `repak.exe` for the texconv field.
  /// When null, the row validates as "any existing directory".
  final String? expectedBasename;
  final VoidCallback onBrowse;

  const _PathRow({
    required this.label,
    required this.hint,
    required this.controller,
    required this.expectedBasename,
    required this.onBrowse,
  });

  ({bool ok, String? warning}) _validate() {
    final s = controller.text;
    if (s.isEmpty) return (ok: false, warning: null);
    if (expectedBasename == null) {
      return Directory(s).existsSync()
          ? (ok: true, warning: null)
          : (ok: false, warning: 'Directory does not exist');
    }
    if (!File(s).existsSync()) {
      return (ok: false, warning: 'File does not exist');
    }
    if (p.basename(s).toLowerCase() != expectedBasename!.toLowerCase()) {
      return (ok: false, warning: 'Expected $expectedBasename');
    }
    return (ok: true, warning: null);
  }

  @override
  Widget build(BuildContext context) {
    final v = _validate();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 96,
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
              child: TextField(
                controller: controller,
                style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: kFsBody,
                    color: kColorText),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(color: kColorText3),
                  filled: true,
                  fillColor: kColorSurface,
                  isDense: true,
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
                    borderSide: BorderSide(color: kColorCyan),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: kSp2, vertical: kSp2),
                ),
              ),
            ),
            const SizedBox(width: kSp2),
            OutlinedButton(
              onPressed: onBrowse,
              style: OutlinedButton.styleFrom(
                foregroundColor: kColorText,
                side: const BorderSide(color: kColorBorder),
                shape: const RoundedRectangleBorder(),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('BROWSE'),
            ),
            const SizedBox(width: kSp2),
            _StatusDot(ok: v.ok),
          ],
        ),
        if (v.warning != null)
          Padding(
            padding: const EdgeInsets.only(left: 96 + kSp2, top: kSp1),
            child: Text(
              v.warning!,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: kFsMeta,
                color: kColorPink,
              ),
            ),
          ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool ok;
  const _StatusDot({required this.ok});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: ok ? 'Found' : 'Missing',
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: ok ? kColorCyan : kColorPink,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
