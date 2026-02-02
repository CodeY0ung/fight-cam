import 'dart:ui';
import '../../../core/models/detected_person.dart';
import '../../../core/utils/kalman_filter.dart';
import '../../../core/constants/enums.dart';

class ManualRecorderService {
  final Map<int, Point> _trajectoryMap = {};
  final Map<int, double> _zoomMap = {};
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

  double get currentX => _currentX;
  double get currentY => _currentY;
  double get currentZoom => _currentZoom;
  bool get hasData => _trajectoryMap.isNotEmpty;

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

    double targetX = (_currentX + velX).clamp(halfW, 1.0 - halfW);
    double targetY = (_currentY + velY).clamp(halfH, 1.0 - halfH);

    _positionFilter.update(Point(targetX, targetY), 0.016);
    _currentX = _positionFilter.x.clamp(halfW, 1.0 - halfW);
    _currentY = _positionFilter.y.clamp(halfH, 1.0 - halfH);
  }

  void updateZoom(double delta) {
    _currentZoom = (_currentZoom + delta).clamp(0.5, 5.0);
    final boxSize = getBoxSize();
    _currentX = _currentX.clamp(boxSize.width / 2, 1.0 - boxSize.width / 2);
    _currentY = _currentY.clamp(boxSize.height / 2, 1.0 - boxSize.height / 2);
    _positionFilter.reset(Point(_currentX, _currentY));
  }

  void recordFrame(int positionMs) {
    final idx = (positionMs / 33).round();
    _trajectoryMap[idx] = Point(_currentX, _currentY);
    _zoomMap[idx] = _currentZoom;
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