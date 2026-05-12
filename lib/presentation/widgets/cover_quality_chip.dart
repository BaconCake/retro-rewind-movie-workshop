import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/cover_quality.dart';

/// Small "image quality" chip shown in the cropper info row.  Briefing §6.3
/// + §10.2: "warning chip when the image is being scaled past its native
/// resolution and quality will suffer".
///
/// Hidden when the assessment is [CoverQualityLevel.ok]; otherwise amber
/// for soft warns and pink for hard warns — matching the project's accent
/// palette (`kColorBadgeEdited` for caution, `kColorPink` for destructive
/// /problematic state).
class CoverQualityChip extends StatelessWidget {
  final CoverQualityAssessment assessment;
  const CoverQualityChip({super.key, required this.assessment});

  @override
  Widget build(BuildContext context) {
    if (assessment.level == CoverQualityLevel.ok) {
      return const SizedBox.shrink();
    }
    final isHard = assessment.level == CoverQualityLevel.hardWarn;
    final fg = isHard ? kColorPink : kColorBadgeEdited;

    return Tooltip(
      message: isHard
          ? 'Output texture will look noticeably degraded — '
              'consider a higher-resolution source or a smaller zoom.'
          : 'Output may show some quality loss — fine for most covers, '
              'but a higher-resolution source would look sharper.',
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: kSp2, vertical: 2),
        decoration: BoxDecoration(
          color: kColorPanel,
          border: Border.all(color: fg),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isHard
                  ? Icons.error_outline
                  : Icons.warning_amber_outlined,
              size: 12,
              color: fg,
            ),
            const SizedBox(width: 4),
            Text(
              assessment.reason,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontFamilyFallback: kFontFamilyFallback,
                fontSize: kFsMeta,
                color: fg,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
