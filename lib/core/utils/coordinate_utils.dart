import 'dart:ui';

/// 스크린 좌표 → RAW 프레임 좌표 (정규화 0~1)
///
/// 변환 체인: screen → display → raw
///   Transform.scale(displayScale, Alignment.centerRight) 역변환:
///     display_x = 1.0 + (screen_x - 1.0) / displayScale
///     display_y = 0.5 + (screen_y - 0.5) / displayScale
///   180° 회전 역변환:
///     raw_x = 1.0 - display_x
///     raw_y = 1.0 - display_y
///
/// 합산식:
///   raw_x = (1.0 - screen_x) / displayScale
///   raw_y = 0.5 - (screen_y - 0.5) / displayScale
Offset screenToRaw(Offset screen, double displayScale) {
  return Offset(
    ((1.0 - screen.dx) / displayScale).clamp(0.0, 1.0),
    (0.5 - (screen.dy - 0.5) / displayScale).clamp(0.0, 1.0),
  );
}

/// RAW 프레임 좌표 → 스크린 좌표 (screenToRaw 역함수)
///
/// 합산식 (GuidePainter와 동일):
///   screen_x = 1.0 - raw_x * displayScale
///   screen_y = 0.5 + (0.5 - raw_y) * displayScale
Offset rawToScreen(Offset raw, double displayScale) {
  return Offset(
    1.0 - raw.dx * displayScale,
    0.5 + (0.5 - raw.dy) * displayScale,
  );
}
