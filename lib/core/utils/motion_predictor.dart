import '../models/detected_person.dart';

/// 모션 예측기 - 타겟 소실 시 선형 예측으로 복구
///
/// 원리:
/// - 최근 N프레임의 속도(velocity)를 계산
/// - 타겟 소실 시 예측 위치로 최대 M프레임 유지
/// - 예측이 계속 실패하면 FREEZE
class MotionPredictor {
  /// 속도 계산에 사용할 최근 프레임 수
  final int historySize;

  /// 예측으로 유지 가능한 최대 프레임 수
  final int maxPredictionFrames;

  /// 최근 위치 히스토리 [(타임스탬프, Point)]
  final List<({double timestamp, Point point})> _history = [];

  /// 현재 예측 중인 프레임 수
  int _predictionCount = 0;

  MotionPredictor({
    this.historySize = 3,
    this.maxPredictionFrames = 5,
  });

  /// 히스토리 리셋
  void reset() {
    _history.clear();
    _predictionCount = 0;
  }

  /// 실제 감지 데이터 추가 (예측 카운터 리셋)
  void addDetection(Point point, double timestamp) {
    _history.add((timestamp: timestamp, point: point));

    // 오래된 데이터 제거
    while (_history.length > historySize) {
      _history.removeAt(0);
    }

    // 예측 카운터 리셋
    _predictionCount = 0;
  }

  /// 타겟 소실 시 예측 위치 계산
  ///
  /// Returns: 예측된 Point, 또는 예측 불가 시 null
  Point? predict(double timestamp) {
    // 히스토리 부족
    if (_history.length < 2) {
      return null;
    }

    // 예측 한계 도달
    if (_predictionCount >= maxPredictionFrames) {
      return null;
    }

    // 평균 속도 계산 (최근 N프레임)
    double totalVx = 0.0;
    double totalVy = 0.0;
    int count = 0;

    for (int i = 1; i < _history.length; i++) {
      final prev = _history[i - 1];
      final curr = _history[i];

      final dt = curr.timestamp - prev.timestamp;
      if (dt <= 0) continue;

      final vx = (curr.point.x - prev.point.x) / dt;
      final vy = (curr.point.y - prev.point.y) / dt;

      totalVx += vx;
      totalVy += vy;
      count++;
    }

    if (count == 0) {
      return null;
    }

    // 평균 속도
    final avgVx = totalVx / count;
    final avgVy = totalVy / count;

    // 마지막 위치에서 예측
    final lastEntry = _history.last;
    final dt = timestamp - lastEntry.timestamp;

    final predictedX = (lastEntry.point.x + avgVx * dt).clamp(0.0, 1.0);
    final predictedY = (lastEntry.point.y + avgVy * dt).clamp(0.0, 1.0);

    // 예측 카운터 증가
    _predictionCount++;

    return Point(predictedX, predictedY);
  }

  /// 현재 예측 중인지 여부
  bool get isPredicting => _predictionCount > 0;

  /// 예측 프레임 수
  int get predictionCount => _predictionCount;
}
