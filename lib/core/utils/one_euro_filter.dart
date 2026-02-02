import 'dart:math';

/// One Euro Filter - 저주파 지터 제거 + 고주파 반응성 유지
///
/// 원리:
/// - 저속 움직임: 강한 스무딩 (떨림 방지)
/// - 고속 움직임: 약한 스무딩 (반응성 유지)
///
/// References:
/// - Casiez, G., Roussel, N., & Vogel, D. (2012).
///   1€ Filter: A Simple Speed-based Low-pass Filter for Noisy Input
/// - https://gery.casiez.net/1euro/
class OneEuroFilter {
  /// 최소 컷오프 주파수 (Hz) - 낮을수록 스무딩 강함
  final double minCutoff;

  /// 속도 계수 - 높을수록 고속 움직임에서 반응 빠름
  final double beta;

  /// 미분 컷오프 주파수 (Hz) - 속도 계산 스무딩
  final double dCutoff;

  /// 이전 필터링된 값
  double? _xPrev;

  /// 이전 미분값 (속도)
  double? _dxPrev;

  /// 이전 타임스탬프
  double? _tPrev;

  OneEuroFilter({
    this.minCutoff = 1.0, // 1Hz (기본값: 보수적 스무딩)
    this.beta = 0.007,    // 속도 민감도 (높을수록 빠른 반응)
    this.dCutoff = 1.0,   // 속도 스무딩
  });

  /// 필터 리셋 (새 추적 시작 시 호출)
  void reset() {
    _xPrev = null;
    _dxPrev = null;
    _tPrev = null;
  }

  /// 값 필터링
  ///
  /// [x] 입력값 (정규화된 좌표 0.0~1.0)
  /// [timestamp] 타임스탬프 (초 단위)
  ///
  /// Returns: 필터링된 값
  double filter(double x, double timestamp) {
    // 첫 샘플: 그대로 반환
    if (_xPrev == null) {
      _xPrev = x;
      _dxPrev = 0.0;
      _tPrev = timestamp;
      return x;
    }

    // 시간 간격 계산
    final dt = timestamp - _tPrev!;
    if (dt <= 0) {
      // 같은 타임스탬프: 이전 값 반환
      return _xPrev!;
    }

    // 미분 (속도) 계산
    final dx = (x - _xPrev!) / dt;

    // 미분값 스무딩 (속도 노이즈 제거)
    final edx = _exponentialSmoothing(
      dx,
      _dxPrev!,
      _alpha(dt, dCutoff),
    );

    // 적응형 컷오프 주파수
    // 속도가 빠를수록 컷오프 올라감 → 스무딩 약해짐 (반응성↑)
    final cutoff = minCutoff + beta * edx.abs();

    // 입력값 스무딩
    final xFiltered = _exponentialSmoothing(
      x,
      _xPrev!,
      _alpha(dt, cutoff),
    );

    // 상태 업데이트
    _xPrev = xFiltered;
    _dxPrev = edx;
    _tPrev = timestamp;

    return xFiltered;
  }

  /// 지수 평활 (Exponential Smoothing)
  ///
  /// [x] 현재 값
  /// [xPrev] 이전 값
  /// [alpha] 스무딩 계수 (0~1)
  ///
  /// alpha = 0: 완전 스무딩 (이전값 유지)
  /// alpha = 1: 스무딩 없음 (현재값 그대로)
  double _exponentialSmoothing(double x, double xPrev, double alpha) {
    return alpha * x + (1 - alpha) * xPrev;
  }

  /// 스무딩 계수 알파 계산
  ///
  /// [dt] 시간 간격 (초)
  /// [cutoff] 컷오프 주파수 (Hz)
  ///
  /// 높은 cutoff → 높은 alpha → 약한 스무딩
  double _alpha(double dt, double cutoff) {
    final tau = 1.0 / (2 * pi * cutoff);
    final te = dt;
    return 1.0 / (1.0 + tau / te);
  }
}

/// 2D Point용 One Euro Filter
class OneEuroFilter2D {
  late final OneEuroFilter _filterX;
  late final OneEuroFilter _filterY;

  OneEuroFilter2D({
    double minCutoff = 1.0,
    double beta = 0.007,
    double dCutoff = 1.0,
  }) {
    _filterX = OneEuroFilter(
      minCutoff: minCutoff,
      beta: beta,
      dCutoff: dCutoff,
    );
    _filterY = OneEuroFilter(
      minCutoff: minCutoff,
      beta: beta,
      dCutoff: dCutoff,
    );
  }

  /// 필터 리셋
  void reset() {
    _filterX.reset();
    _filterY.reset();
  }

  /// 2D 좌표 필터링
  ///
  /// Returns: (filteredX, filteredY)
  ({double x, double y}) filter(double x, double y, double timestamp) {
    return (
      x: _filterX.filter(x, timestamp),
      y: _filterY.filter(y, timestamp),
    );
  }
}
