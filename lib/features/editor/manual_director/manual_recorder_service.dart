import 'dart:ui';
import '../../../core/models/detected_person.dart';
import '../../../core/models/trajectory_point.dart';
import '../../../core/utils/kalman_filter.dart';
import '../../../core/constants/enums.dart';

class ManualRecorderService {
  final Map<int, Point> _trajectoryMap = {};
  final Map<int, double> _zoomMap = {};

  /// 수동으로 오버라이드된 프레임 인덱스 집합
  final Set<int> _manualOverrideSet = {};
  static const int frameIntervalMs = 33;

  // UI와 렌더러가 공유할 핵심 상수 (0.8 = 화면의 80% 가시성 기준)
  static const double kDefaultBoxScale = 0.8;

  final AlphaBetaGammaFilter2D _positionFilter = AlphaBetaGammaFilter2D(
    alpha: 0.15,  
    beta: 0.05,   
    gamma: 0.01,
  );

  double _currentX = 0.5;
  double _currentY = 0.5;
  double _currentZoom = 1.0;
  int _totalDurationMs = 0;
  double _videoAspectRatio = 16 / 9;
  TargetAspectRatio _selectedRatio = TargetAspectRatio.vertical_9_16;

  /// 디스플레이 scale 보정값 (초록 아티팩트 크롭용, 기본 1.0)
  /// 1.0/displayScale 이상의 raw_x는 화면 왼쪽 밖이므로 이동 금지
  double _displayScale = 1.0;
  void setDisplayScale(double scale) => _displayScale = scale;

  double get currentX => _currentX;
  double get currentY => _currentY;
  double get currentZoom => _currentZoom;
  bool get hasData => _trajectoryMap.isNotEmpty;

  /// 특정 프레임이 수동 오버라이드인지 여부 (UI 표시용)
  bool isManualOverride(int frameIndex) => _manualOverrideSet.contains(frameIndex);

  /// AI 생성 궤적을 임포트하여 _trajectoryMap/_zoomMap 초기화
  /// 기존 수동 데이터는 모두 초기화됨
  void importAiTrajectory(List<TrajectoryPoint> trajectory) {
    _trajectoryMap.clear();
    _zoomMap.clear();
    _manualOverrideSet.clear();
    for (final p in trajectory) {
      _trajectoryMap[p.frameIndex] = Point(p.centerX, p.centerY);
      _zoomMap[p.frameIndex] = p.zoom;
    }
  }

  void initialize({required int totalDurationMs, required double videoAspectRatio, TargetAspectRatio? ratio}) {
    _totalDurationMs = totalDurationMs;
    _videoAspectRatio = videoAspectRatio;
    if (ratio != null) _selectedRatio = ratio;
    _positionFilter.init(Point(0.5, 0.5));
    _currentX = 0.5; _currentY = 0.5; _currentZoom = 1.0;
  }

  void setAspectRatio(TargetAspectRatio ratio) => _selectedRatio = ratio;

  Size getBoxSize() {
    double targetAspect;
    switch (_selectedRatio) {
      case TargetAspectRatio.vertical_9_16: targetAspect = 9 / 16; break;
      case TargetAspectRatio.square_1_1: targetAspect = 1.0; break;
      case TargetAspectRatio.portrait_4_5: targetAspect = 4 / 5; break;
      case TargetAspectRatio.landscape_16_9: targetAspect = 16 / 9; break;
    }

    // kDefaultBoxScale(0.8)을 사용하여 렌더러와 기준점 일치
    double h = (kDefaultBoxScale / _currentZoom).clamp(0.05, 1.0);
    double w = (h * targetAspect) / _videoAspectRatio;

    if (w > 1.0) {
      w = 1.0;
      h = (w * _videoAspectRatio) / targetAspect;
    }
    return Size(w, h);
  }

  void updatePosition(double velX, double velY) {
    final boxSize = getBoxSize();
    final halfW = boxSize.width / 2;
    final halfH = boxSize.height / 2;

    // [rotation 180° 보정] raw 프레임 좌표계 ↔ display 좌표계 방향 반전
    // velX/Y 부호 반전은 여기서만 1회 적용 (중복 없음)
    //
    // X 상한: raw_x > 1/_displayScale 이면 screen_x < 0 (화면 왼쪽 밖) → 금지
    // max(halfW, ...) 로 clamp 인자 역전 방지 (극단적 줌아웃 시 RangeError 차단)
    final double maxX = ((1.0 / _displayScale) - halfW).clamp(halfW, 1.0 - halfW);
    double targetX = (_currentX - velX).clamp(halfW, maxX);
    double targetY = (_currentY - velY).clamp(halfH, 1.0 - halfH);

    // 필터를 현재 목표 위치로 리셋 후 업데이트
    // → AI 트래킹용 anti-jump 누적 속도(vy) 초기화로 드리프트 원천 차단
    _positionFilter.reset(Point(_currentX, _currentY));
    _positionFilter.update(Point(targetX, targetY), 0.016);
    _currentX = _positionFilter.x.clamp(halfW, maxX);
    _currentY = _positionFilter.y.clamp(halfH, 1.0 - halfH);
  }

  void updateZoom(double delta) {
    _currentZoom = (_currentZoom + delta).clamp(0.5, 5.0);
    final boxSize = getBoxSize();
    final double maxX = ((1.0 / _displayScale) - boxSize.width / 2).clamp(boxSize.width / 2, 1.0 - boxSize.width / 2);
    _currentX = _currentX.clamp(boxSize.width / 2, maxX);
    _currentY = _currentY.clamp(boxSize.height / 2, 1.0 - boxSize.height / 2);
    _positionFilter.reset(Point(_currentX, _currentY));
  }

  void recordFrame(int positionMs) {
    final idx = (positionMs / 33).round();
    _trajectoryMap[idx] = Point(_currentX, _currentY);
    _zoomMap[idx] = _currentZoom;
    _manualOverrideSet.add(idx); // AI 좌표 위에 수동 입력으로 덮어쓴 프레임 기록
  }

  bool restoreFromFrame(int ms) {
    final idx = (ms / 33).round();
    if (_trajectoryMap.containsKey(idx)) {
      _currentX = _trajectoryMap[idx]!.x;
      _currentY = _trajectoryMap[idx]!.y;
      _currentZoom = _zoomMap[idx] ?? 1.0;
      return true;
    }
    return false;
  }

  /// 조이스틱 첫 터치 시 AI 궤적 좌표로 동기화 (튐 방지)
  /// 수동 오버라이드된 프레임은 사용자가 이미 설정한 값이므로 덮어쓰지 않음
  void syncToAiPosition(int ms) {
    final idx = (ms / 33).round();
    if (_trajectoryMap.containsKey(idx) && !_manualOverrideSet.contains(idx)) {
      _currentX = _trajectoryMap[idx]!.x;
      _currentY = _trajectoryMap[idx]!.y;
      _currentZoom = _zoomMap[idx] ?? _currentZoom;
      _positionFilter.reset(Point(_currentX, _currentY));
    }
  }

  (List<Point>, List<double>) getContinuousTrajectory() {
    final totalFrames = (_totalDurationMs / 33).ceil();
    final List<Point> trajectory = [];
    final List<double> zoomLevels = [];
    final sortedKeys = _trajectoryMap.keys.toList()..sort();

    if (sortedKeys.isEmpty) {
      return (List.generate(totalFrames, (_) => Point(0.5, 0.5)), List.generate(totalFrames, (_) => 1.0));
    }

    Point lastP = _trajectoryMap[sortedKeys.first]!;
    double lastZ = _zoomMap[sortedKeys.first]!;

    for (int i = 0; i < totalFrames; i++) {
      if (_trajectoryMap.containsKey(i)) {
        lastP = _trajectoryMap[i]!;
        lastZ = _zoomMap[i]!;
      }
      trajectory.add(lastP);
      zoomLevels.add(lastZ);
    }
    return (trajectory, zoomLevels);
  }

  List<Point> applyMovingAverageToTrajectory(List<Point> t, {int windowFrames = 36}) {
    if (t.length < windowFrames) return t;
    final smoothed = <Point>[];
    for (int i = 0; i < t.length; i++) {
      double sx = 0, sy = 0; int count = 0;
      for (int j = i - windowFrames ~/ 2; j <= i + windowFrames ~/ 2; j++) {
        if (j >= 0 && j < t.length) { sx += t[j].x; sy += t[j].y; count++; }
      }
      smoothed.add(Point(sx / count, sy / count));
    }
    return smoothed;
  }

  List<double> applyTrailingAverageToZoom(List<double> z, {int windowFrames = 60}) {
    if (z.length < windowFrames) return z;
    final smoothed = <double>[];
    for (int i = 0; i < z.length; i++) {
      double sum = 0; int count = 0;
      for (int j = i; j >= 0 && j > i - windowFrames; j--) { sum += z[j]; count++; }
      smoothed.add(sum / count);
    }
    return smoothed;
  }
}