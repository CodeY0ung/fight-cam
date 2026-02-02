import 'dart:math';

/// 감지된 사람 정보
class DetectedPerson {
  /// 화면 내 바운딩 박스 (정규화된 좌표 0.0 ~ 1.0)
  final BoundingBox boundingBox;

  /// 중심점 좌표 (정규화된 좌표)
  final Point center;

  /// 신뢰도 (0.0 ~ 1.0)
  final double confidence;

  /// 색상 시그니처 (옷 색깔 기반 타겟 구별용)
  /// 박스 중앙(몸통) 영역의 대표 색상
  final ColorSignature? dominantColor;

  DetectedPerson({
    required this.boundingBox,
    required this.center,
    required this.confidence,
    this.dominantColor,
  });

  @override
  String toString() {
    return 'DetectedPerson(center: $center, confidence: ${confidence.toStringAsFixed(2)}, color: $dominantColor)';
  }
}

/// 색상 시그니처 (RGB)
class ColorSignature {
  final int r;
  final int g;
  final int b;

  ColorSignature(this.r, this.g, this.b);

  /// 두 색상 간 유클리드 거리 제곱 계산
  int distanceSquaredTo(ColorSignature other) {
    final dr = r - other.r;
    final dg = g - other.g;
    final db = b - other.b;
    return dr * dr + dg * dg + db * db;
  }

  @override
  String toString() {
    return 'RGB($r,$g,$b)';
  }
}

/// 바운딩 박스 (정규화된 좌표)
class BoundingBox {
  final double left;   // 0.0 ~ 1.0
  final double top;    // 0.0 ~ 1.0
  final double width;  // 0.0 ~ 1.0
  final double height; // 0.0 ~ 1.0

  BoundingBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  double get right => left + width;
  double get bottom => top + height;
  double get centerX => left + (width / 2);
  double get centerY => top + (height / 2);

  @override
  String toString() {
    return 'BoundingBox(x: ${left.toStringAsFixed(2)}, y: ${top.toStringAsFixed(2)}, '
        'w: ${width.toStringAsFixed(2)}, h: ${height.toStringAsFixed(2)})';
  }
}

/// 2D 좌표
class Point {
  final double x; // 0.0 ~ 1.0 (정규화)
  final double y; // 0.0 ~ 1.0 (정규화)

  Point(this.x, this.y);

  /// 두 점 사이의 유클리드 거리
  double distanceTo(Point other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return sqrt(dx * dx + dy * dy);
  }

  @override
  String toString() {
    return 'Point(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
  }
}

/// 첫 프레임 분석 결과
class FirstFrameResult {
  final String framePath; // 추출된 프레임 이미지 경로
  final List<DetectedPerson> people; // 감지된 사람들

  FirstFrameResult({
    required this.framePath,
    required this.people,
  });
}

/// 타겟 추적 데이터 (1인 또는 2인 모드)
class TrackingData {
  final List<Point> trajectoryA; // 타겟 A의 프레임별 좌표
  final List<Point>? trajectoryB; // 타겟 B의 프레임별 좌표 (스파링 모드에서만 사용)
  final List<BoundingBox> trajectoryBoxA; // 타겟 A의 프레임별 BoundingBox
  final List<BoundingBox>? trajectoryBoxB; // 타겟 B의 프레임별 BoundingBox (스파링 모드에서만 사용)
  final List<bool> freezeFlags; // 프레임별 FREEZE 상태 (true = 타겟 놓침, 줌 풀기)
  final List<double>? confidenceScores; // V5.1: 프레임별 추적 신뢰도 (0.0~1.0, 줌 댐핑용)
  final int totalFrames;
  final double fps;
  final Duration startTime; // 추적 시작 시점

  TrackingData({
    required this.trajectoryA,
    this.trajectoryB,
    required this.trajectoryBoxA,
    this.trajectoryBoxB,
    required this.freezeFlags,
    this.confidenceScores, // V5.1: 신뢰도 점수 (optional)
    required this.totalFrames,
    required this.fps,
    this.startTime = Duration.zero,
  });

  /// 스파링 모드 여부 (2인 추적)
  bool get isSparringMode => trajectoryB != null && trajectoryBoxB != null;

  /// V5.1: 평균 신뢰도 계산
  double get averageConfidence {
    if (confidenceScores == null || confidenceScores!.isEmpty) return 1.0;
    return confidenceScores!.reduce((a, b) => a + b) / confidenceScores!.length;
  }

  /// V5.1: 저신뢰도 프레임 비율 (50% 미만)
  double get lowConfidenceRatio {
    if (confidenceScores == null || confidenceScores!.isEmpty) return 0.0;
    final lowCount = confidenceScores!.where((c) => c < 0.5).length;
    return lowCount / confidenceScores!.length;
  }

  /// 하위 호환성을 위한 단일 trajectory 접근
  @Deprecated('Use trajectoryA instead')
  List<Point> get trajectory => trajectoryA;

  @override
  String toString() {
    return 'TrackingData(frames: $totalFrames, fps: $fps, '
        'pointsA: ${trajectoryA.length}, '
        'pointsB: ${trajectoryB?.length ?? 0}, '
        'sparring: $isSparringMode, '
        'avgConfidence: ${(averageConfidence * 100).toStringAsFixed(1)}%, '
        'startTime: ${startTime.inSeconds}s)';
  }
}
