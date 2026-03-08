/// AI 및 수동 트래킹의 공통 궤적 데이터 단위
/// ManualRecorderService와 AiTrackingService 양쪽에서 사용
class TrajectoryPoint {
  /// 30fps 기준 프레임 인덱스 (frameIndex * 33ms = 해당 시각)
  final int frameIndex;

  /// 정규화 좌표 (0.0 ~ 1.0)
  final double centerX;
  final double centerY;

  /// 줌 배율
  final double zoom;

  /// 사용자가 수동으로 덮어쓴 프레임인지 여부
  final bool isManualOverride;

  const TrajectoryPoint({
    required this.frameIndex,
    required this.centerX,
    required this.centerY,
    this.zoom = 1.0,
    this.isManualOverride = false,
  });

  TrajectoryPoint copyWithOverride(double cx, double cy, double z) {
    return TrajectoryPoint(
      frameIndex: frameIndex,
      centerX: cx,
      centerY: cy,
      zoom: z,
      isManualOverride: true,
    );
  }

  @override
  String toString() =>
      'TrajectoryPoint(frame=$frameIndex, x=${centerX.toStringAsFixed(3)}, y=${centerY.toStringAsFixed(3)}, zoom=$zoom, manual=$isManualOverride)';
}
