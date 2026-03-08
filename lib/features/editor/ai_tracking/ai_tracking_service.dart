import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../../../core/models/detected_person.dart';
import '../../../core/models/trajectory_point.dart';
import '../../../core/utils/coordinate_utils.dart';
import '../../../core/utils/kalman_filter.dart';

/// 검증 모드용 감지 박스 (정규화 display 좌표 0~1)
class AnchorDetection {
  /// 정규화된 display 좌표 (0~1). 왼쪽 위 기준 Rect.
  final Rect normBox;
  /// ML Kit 레이블 신뢰도 (레이블 없으면 1.0)
  final double confidence;

  const AnchorDetection({required this.normBox, required this.confidence});
}

/// AI 트래킹 서비스
/// 사용자가 앵커 시점에 설정한 박스를 기준으로
/// ML Kit Object Detection을 이용해 전/후방 궤적을 계산
class AiTrackingService {
  /// 가장 최근 분석의 앵커 프레임 감지 결과 (검증 모드 표시용)
  List<AnchorDetection> _lastAnchorDetections = [];
  double _lastFrameW = 320.0;
  double _lastFrameH = 180.0;

  List<AnchorDetection> get lastAnchorDetections =>
      List.unmodifiable(_lastAnchorDetections);
  double get lastFrameW => _lastFrameW;
  double get lastFrameH => _lastFrameH;
  static const int _extractFps = 15;       // 분석 fps (격투기 빠른 동작 대응)
  static const int _extractWidth = 320;    // 분석용 다운스케일 너비

  bool _isCancelled = false;
  void cancel() => _isCancelled = true;
  void reset() => _isCancelled = false;

  /// 전체 분석 진입점
  /// [userBox]   : 사용자가 앵커 프레임에 그린 박스 (정규화 0~1 Rect)
  /// [anchorMs]  : 앵커 타임스탬프 (ms)
  /// [videoAspectRatio] : 원본 영상 aspect ratio (width/height)
  Future<List<TrajectoryPoint>> analyzeTrajectory({
    required String videoPath,
    required Rect userBox,
    required int anchorMs,
    required int totalDurationMs,
    required double videoAspectRatio,
    /// 화면에 적용된 scale (1.20). 스크린 좌표 → 디스플레이 프레임 좌표 변환에 사용
    double displayScale = 1.0,
    Function(double progress, String status)? onProgress,
  }) async {
    reset();
    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory(
        '${tempDir.path}/ai_frames_${DateTime.now().millisecondsSinceEpoch}');
    await framesDir.create(recursive: true);

    try {
      // ── 1단계: FFmpeg 프레임 추출 ──────────────────────────────────────
      onProgress?.call(0.05, '프레임 추출 중...');
      await _extractFrames(videoPath, framesDir.path);
      if (_isCancelled) throw Exception('분석 취소됨');

      final frames = framesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      if (frames.isEmpty) throw Exception('프레임 추출 실패');

      // ── 실제 JPEG 해상도 측정 (추정값 대신 실제값으로 좌표 오차 제거) ──
      final firstBytes = await frames.first.readAsBytes();
      final img.Image? firstImg = img.decodeImage(firstBytes);
      final double frameW = firstImg?.width.toDouble() ?? _extractWidth.toDouble();
      final double frameH = firstImg?.height.toDouble() ?? (_extractWidth / videoAspectRatio);
      debugPrint('[AI_FRAME] 실제 프레임: ${frameW.toInt()}x${frameH.toInt()} '
          '(추정 H: ${(_extractWidth / videoAspectRatio).toStringAsFixed(1)})');

      // 앵커 프레임 인덱스 계산
      final anchorFrameIdx =
          (anchorMs / 1000 * _extractFps).round().clamp(0, frames.length - 1);

      // ── 2단계: 앵커 프레임에서 타겟 감지 ─────────────────────────────
      onProgress?.call(0.20, 'AI 타겟 인식 중...');
      final anchorObjects = await _detectSingle(frames[anchorFrameIdx]);

      // 검증 모드용: 앵커 감지 결과를 정규화 좌표로 변환해 저장
      _lastFrameW = frameW;
      _lastFrameH = frameH;
      _lastAnchorDetections = anchorObjects.map((o) {
        final conf = o.labels.isEmpty
            ? 1.0
            : o.labels.map((l) => l.confidence).reduce(math.max);
        return AnchorDetection(
          normBox: Rect.fromLTWH(
            o.boundingBox.left / frameW,
            o.boundingBox.top / frameH,
            o.boundingBox.width / frameW,
            o.boundingBox.height / frameH,
          ),
          confidence: conf,
        );
      }).toList();

      // FFmpegKit은 기본적으로 rotation 메타데이터를 적용해 추출(auto-rotate).
      // 따라서 추출된 프레임은 디스플레이 방향(화면에 보이는 그대로).
      //
      // screenToRaw(): 스크린 좌표 → raw 프레임 좌표 (coordinate_utils.dart 공용 함수)
      // raw → display 역변환(180° flip): display = 1 - raw
      // 픽셀 좌표: anchorCenter = display_norm * frameSize
      final Offset rawAnchor = screenToRaw(userBox.center, displayScale);
      final Offset anchorCenter = Offset(
        (1.0 - rawAnchor.dx) * frameW,
        (1.0 - rawAnchor.dy) * frameH,
      );
      // 좌표 변환 검증 로그: 스크린 탭 위치 → displayPx 일치 여부 확인
      // screen → raw(screenToRaw) → display(1-raw) → pixel(*frameSize)
      debugPrint('[AI_ANCHOR] screen=(${userBox.center.dx.toStringAsFixed(4)}, '
          '${userBox.center.dy.toStringAsFixed(4)}) '
          '→ raw=(${rawAnchor.dx.toStringAsFixed(4)}, ${rawAnchor.dy.toStringAsFixed(4)}) '
          '→ displayPx=(${anchorCenter.dx.toStringAsFixed(1)}, ${anchorCenter.dy.toStringAsFixed(1)}) '
          'frame=${frameW.toInt()}x${frameH.toInt()} displayScale=$displayScale');

      // ── 3단계: 정방향 추적 (앵커 → 끝) ──────────────────────────────
      onProgress?.call(0.30, '정방향 추적 중...');
      final forwardFrames = frames.sublist(anchorFrameIdx);
      final forwardPositions = await _trackDirection(
        frames: forwardFrames,
        anchorObjects: anchorObjects,
        anchorCenter: anchorCenter,
        frameW: frameW,
        frameH: frameH,
        onProgress: (p, s) => onProgress?.call(0.30 + p * 0.30, s),
      );
      if (_isCancelled) throw Exception('분석 취소됨');

      // ── 역방향 추적 전 ID 워밍업 ─────────────────────────────────────
      // ML Kit stream 모드는 첫 프레임에서 trackingId를 부여하지 않음.
      // 앵커 기준 정방향 최대 6프레임을 미리 처리해 ID를 안정화한 뒤,
      // 같은 detector 인스턴스로 역방향 추적을 이어가면 ID 연속성이 보장됨.
      onProgress?.call(0.57, 'ID 워밍업 중...');
      final warmupEnd = (anchorFrameIdx + 6).clamp(0, frames.length);
      final (backwardDetector, backwardSeedId) = await _createWarmedUpDetector(
        warmupFrames: frames.sublist(anchorFrameIdx, warmupEnd),
        anchorCenter: anchorCenter,
      );

      // ── 4단계: 역방향 추적 (앵커 → 처음) ───────────────────────────
      onProgress?.call(0.60, '역방향 추적 중...');
      final backwardFrames =
          frames.sublist(0, anchorFrameIdx + 1).reversed.toList();
      final backwardPositions = await _trackDirection(
        frames: backwardFrames,
        anchorObjects: anchorObjects,
        anchorCenter: anchorCenter,
        frameW: frameW,
        frameH: frameH,
        seededDetector: backwardDetector,       // warmup된 detector 재사용
        seedTrackingId: backwardSeedId,         // warmup에서 획득한 안정된 ID
        distThresholdOverride: frameW * 0.15,   // 역방향: 타이트한 임계값
        holdOnLostTail: true,                   // 꼬리 패딩 활성화
        onProgress: (p, s) => onProgress?.call(0.60 + p * 0.25, s),
      );
      if (_isCancelled) throw Exception('분석 취소됨');

      // ── 5단계: 15fps 결과 → 30fps 궤적 변환 (Catmull-Rom 스플라인) ──
      onProgress?.call(0.85, '궤적 보간 중...');
      return _buildFinalTrajectory(
        forwardPositions: forwardPositions,
        backwardPositions: backwardPositions,
        anchorFrameIdx: anchorFrameIdx,
        totalDurationMs: totalDurationMs,
        frameW: frameW,
        frameH: frameH,
      );
    } finally {
      try { await framesDir.delete(recursive: true); } catch (_) {}
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 내부 메서드
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _extractFrames(String videoPath, String outDir) async {
    final cmd = '-i "$videoPath" '
        '-vf "fps=$_extractFps,scale=$_extractWidth:-2" '
        '-q:v 5 '
        '"$outDir/frame_%05d.jpg"';
    final session = await FFmpegKit.execute(cmd);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw Exception('프레임 추출 실패');
    }
  }

  /// 단일 프레임 감지 (앵커 프레임용)
  Future<List<DetectedObject>> _detectSingle(File frame) async {
    final options = ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true,   // 신뢰도 로깅 활성화
      multipleObjects: true,
    );
    final detector = ObjectDetector(options: options);
    try {
      return await detector.processImage(InputImage.fromFile(frame));
    } finally {
      detector.close();
    }
  }

  /// 역방향 추적 전 trackingId 안정화 워밍업
  ///
  /// 앵커 프레임부터 정방향으로 최대 [warmupCount]개 프레임을 스트림 처리.
  /// ML Kit은 stream 모드에서 2번째 프레임부터 trackingId를 부여하므로
  /// 초기 몇 프레임을 미리 처리해 타겟 ID를 안정적으로 확보한다.
  ///
  /// 반환: (워밍업된 detector, 획득된 trackingId)
  /// ⚠️ 반환된 detector는 역방향 추적 완료 후 반드시 close()됨 (_trackDirection 내부)
  Future<(ObjectDetector, int?)> _createWarmedUpDetector({
    required List<File> warmupFrames,
    required Offset anchorCenter,
    int warmupCount = 6,
  }) async {
    final detector = ObjectDetector(options: ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    ));
    int? foundId;

    final limit = warmupCount.clamp(1, warmupFrames.length);
    for (int i = 0; i < limit; i++) {
      if (_isCancelled) break;
      final objects = await detector.processImage(
          InputImage.fromFile(warmupFrames[i]));
      if (foundId == null) {
        final best = _findBestMatch(objects, anchorCenter);
        if (best?.trackingId != null) {
          foundId = best!.trackingId;
          debugPrint('[AI_WARMUP] Frame $i: trackingId=$foundId 획득');
        }
      }
    }

    if (foundId == null) {
      debugPrint('[AI_WARMUP] trackingId 획득 실패 (거리 기반 fallback 사용)');
    }
    return (detector, foundId);
  }

  /// 한 방향 (정방향/역방향) 추적
  ///
  /// 개선사항:
  /// - DetectionMode.stream: 프레임 간 trackingId 연속성 보장
  /// - trackingId 탐색은 rawObjects(미필터)에서 → ID 연속성 최우선
  /// - trackingId 고정: 앵커 ID는 변경하지 않음 (타겟 교체 방지)
  /// - 거리 임계값: 기본 25%, 역방향은 15% (타이트한 고정)
  /// - fallback 탐색에만 신뢰도 필터 적용 (0.5 미만 제외)
  /// - 칼만 필터 alpha 0.25: 노이즈 댐핑으로 떨림 감소
  /// - 객체 미발견 시 [AI_LOST] 로그 + 칼만 예측 or 위치 고정 (holdOnLostTail)
  ///
  /// [seededDetector]     : 역방향용 warmup된 detector (null이면 새로 생성)
  /// [seedTrackingId]     : 역방향용 warmup에서 획득한 trackingId 초기값
  /// [distThresholdOverride] : 역방향용 타이트한 임계값 (기본 frameW * 0.25)
  /// [holdOnLostTail]     : 연속 미발견 시 칼만 예측 대신 마지막 위치 고정
  Future<List<Offset?>> _trackDirection({
    required List<File> frames,
    required List<DetectedObject> anchorObjects,
    required Offset anchorCenter,
    required double frameW,
    required double frameH,
    ObjectDetector? seededDetector,
    int? seedTrackingId,
    double? distThresholdOverride,
    bool holdOnLostTail = false,
    Function(double, String)? onProgress,
  }) async {
    final detector = seededDetector ?? ObjectDetector(options: ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    ));
    final List<Offset?> results = [];

    // trackingId: 앵커 프레임에서 1회 설정 후 절대 갱신하지 않음 (타겟 고정)
    // seedTrackingId가 있으면 warmup에서 획득한 안정된 ID를 우선 사용
    int? trackingId = seedTrackingId;
    Offset? lastKnown;

    // 칼만 필터: alpha 0.25 (댐핑 강화) → 노이즈에 의한 급격한 떨림 방지
    final filter = AlphaBetaGammaFilter2D(alpha: 0.25, beta: 0.05, gamma: 0.005);
    filter.init(Point(anchorCenter.dx / frameW, anchorCenter.dy / frameH));
    final double dt = 1.0 / _extractFps;

    // 거리 임계값: 정방향 25%, 역방향 15% (타이트하게 고정)
    final double distThreshold = distThresholdOverride ?? frameW * 0.25;

    // 꼬리 패딩: 연속 미발견 카운터
    int consecutiveLost = 0;
    const int holdAfterLost = 4;  // 4프레임 연속 미발견 시 위치 고정

    try {
      for (int i = 0; i < frames.length; i++) {
        if (_isCancelled) break;
        final rawObjects = await detector.processImage(
            InputImage.fromFile(frames[i]));

        DetectedObject? target;
        if (i == 0) {
          // 앵커 프레임: 신뢰도 필터 적용 후 anchorCenter에 가장 가까운 객체 선택
          final filteredCurrent = _filterByConfidence(rawObjects);
          final filteredAnchor = _filterByConfidence(anchorObjects);
          final candidates = filteredCurrent.isNotEmpty ? filteredCurrent
              : (filteredAnchor.isNotEmpty ? filteredAnchor : anchorObjects);
          target = _findBestMatch(candidates, anchorCenter);
          // seedTrackingId 우선, 없으면 현재 프레임에서 획득 (null 가능)
          trackingId ??= target?.trackingId;
          if (target != null) {
            debugPrint('[AI_LOCK] 앵커 고정: id=$trackingId '
                '(seed=$seedTrackingId), '
                'conf=${_maxConf(target).toStringAsFixed(2)}, '
                'pos=(${(target.boundingBox.center.dx/frameW).toStringAsFixed(3)}, '
                '${(target.boundingBox.center.dy/frameH).toStringAsFixed(3)})');
          } else {
            debugPrint('[AI_LOCK] 앵커 프레임에서 타겟 없음');
          }
        } else {
          // ① trackingId 탐색: rawObjects(미필터)에서 수행 → 연속성 최우선
          //    신뢰도 필터를 거치면 ID가 있어도 놓칠 수 있으므로 원본에서 직접 탐색
          if (trackingId != null) {
            target = rawObjects.where((o) => o.trackingId == trackingId).firstOrNull;
          }

          // ② Fallback: 신뢰도 필터 적용 후 거리 임계값 내 탐색
          //    trackingId는 갱신하지 않음 → 앵커 ID 보존
          if (target == null && lastKnown != null) {
            final filteredForFallback = _filterByConfidence(rawObjects);
            final fallback = _findClosestWithinDist(filteredForFallback, lastKnown, distThreshold);
            if (fallback != null) {
              target = fallback;
              debugPrint('[AI_FALLBACK] Frame $i: '
                  'dist-fallback conf=${_maxConf(target).toStringAsFixed(2)}');
            }
          }
        }

        if (target != null) {
          consecutiveLost = 0;
          final c = target.boundingBox.center;
          filter.update(Point(c.dx / frameW, c.dy / frameH), dt);
          lastKnown = Offset(c.dx, c.dy);
          results.add(lastKnown);
          if (i > 0) {
            debugPrint('[AI_CONF] Frame $i: conf=${_maxConf(target).toStringAsFixed(2)}');
          }
        } else {
          consecutiveLost++;
          // 꼬리 패딩: 연속 미발견 구간에서 칼만 발산 방지 → 마지막 위치 고정
          if (holdOnLostTail && consecutiveLost >= holdAfterLost && lastKnown != null) {
            results.add(lastKnown);
            debugPrint('[AI_HOLD] Frame $i: 위치 고정 (연속 미발견 $consecutiveLost프레임)');
          } else {
            // 칼만 예측 (정방향 또는 초기 미발견 구간)
            final predicted = filter.predict(dt);
            final predictedPixel = Offset(predicted.x * frameW, predicted.y * frameH);
            lastKnown = predictedPixel;
            results.add(predictedPixel);
            debugPrint('[AI_LOST] Frame $i: Predicting... '
                '(${predicted.x.toStringAsFixed(3)}, ${predicted.y.toStringAsFixed(3)})');
          }
        }

        onProgress?.call(i / frames.length, '추적 중... ${i + 1}/${frames.length}');
      }
    } finally {
      detector.close();
    }
    return results;
  }

  // ── 헬퍼 ────────────────────────────────────────────────────────────────

  /// 신뢰도 필터: labels가 있는 경우에만 적용, 없으면 통과
  List<DetectedObject> _filterByConfidence(
      List<DetectedObject> objects, {double minConf = 0.5}) {
    return objects.where((obj) {
      if (obj.labels.isEmpty) return true;  // 미분류 객체는 통과
      return _maxConf(obj) >= minConf;
    }).toList();
  }

  /// 객체의 최대 label 신뢰도 (labels 없으면 1.0 반환)
  double _maxConf(DetectedObject obj) {
    if (obj.labels.isEmpty) return 1.0;
    return obj.labels.map((l) => l.confidence).reduce(math.max);
  }

  DetectedObject? _findBestMatch(
      List<DetectedObject> objects, Offset targetCenter) {
    if (objects.isEmpty) return null;
    DetectedObject? best;
    double bestDist = double.infinity;
    for (final obj in objects) {
      final c = obj.boundingBox.center;
      final dist = math.sqrt(
          math.pow(c.dx - targetCenter.dx, 2) +
          math.pow(c.dy - targetCenter.dy, 2));
      if (dist < bestDist) {
        bestDist = dist;
        best = obj;
      }
    }
    return best;
  }

  /// 거리 임계값 내에서 가장 가까운 객체 반환
  /// [maxDist] 초과 시 null 반환 (타겟 교체 방지)
  DetectedObject? _findClosestWithinDist(
      List<DetectedObject> objects, Offset lastKnown, double maxDist) {
    if (objects.isEmpty) return null;
    DetectedObject? best;
    double bestDist = maxDist; // 임계값을 초기값으로 → 초과 시 null 반환
    for (final obj in objects) {
      final c = obj.boundingBox.center;
      final dist = math.sqrt(
          math.pow(c.dx - lastKnown.dx, 2) +
          math.pow(c.dy - lastKnown.dy, 2));
      if (dist < bestDist) {
        bestDist = dist;
        best = obj;
      }
    }
    return best;
  }

  /// 15fps 결과를 30fps TrajectoryPoint 리스트로 변환 (Catmull-Rom 스플라인 보간)
  List<TrajectoryPoint> _buildFinalTrajectory({
    required List<Offset?> forwardPositions,   // [anchor, anchor+1, ...]
    required List<Offset?> backwardPositions,  // [anchor, anchor-1, ...]
    required int anchorFrameIdx,               // 15fps 기준 앵커 인덱스
    required int totalDurationMs,
    required double frameW,
    required double frameH,
  }) {
    // 15fps 결과를 시간 순서 리스트로 합치기
    // backward: [anchor-N, ..., anchor-1, anchor]
    // forward:  [anchor, anchor+1, ..., anchor+M]
    final List<Offset?> chronological = [
      ...backwardPositions.reversed.toList()..removeLast(), // anchor 중복 제거
      ...forwardPositions,
    ];

    final int backLen = backwardPositions.length - 1;

    // null 선형 보간 (Kalman 예측 후 남은 null 안전망)
    final filled = _interpolateOffsets(chronological);

    // 15fps 시작 시각 (ms)
    final int trackFpsStartMs = ((anchorFrameIdx - backLen) * 1000 / _extractFps).round();

    // 30fps 총 프레임 수
    final int total30FpsFrames = (totalDurationMs / 33.33).ceil();

    final List<TrajectoryPoint> result = [];
    for (int frame30 = 0; frame30 < total30FpsFrames; frame30++) {
      final int timeMs = (frame30 * 33.33).round();

      // 15fps 기준 실수 인덱스
      final double trackIdx =
          (timeMs - trackFpsStartMs) / (1000.0 / _extractFps);

      Offset pos;
      if (trackIdx <= 0) {
        pos = filled.first ?? const Offset(0.5, 0.5);
      } else if (trackIdx >= filled.length - 1) {
        pos = filled.last ?? const Offset(0.5, 0.5);
      } else {
        final int lo = trackIdx.floor();
        final double frac = trackIdx - lo;

        // Catmull-Rom 스플라인: 4개 제어점으로 부드러운 곡선 보간
        // 경계에서 클램프로 phantom 포인트 생성 (꺾임 방지)
        final Offset p0 = filled[(lo - 1).clamp(0, filled.length - 1)] ?? const Offset(0.5, 0.5);
        final Offset p1 = filled[lo] ?? const Offset(0.5, 0.5);
        final Offset p2 = filled[(lo + 1).clamp(0, filled.length - 1)] ?? const Offset(0.5, 0.5);
        final Offset p3 = filled[(lo + 2).clamp(0, filled.length - 1)] ?? const Offset(0.5, 0.5);
        final Offset raw = _catmullRom(p0, p1, p2, p3, frac);
        // Catmull-Rom은 제어점 범위를 overshoot할 수 있음 → 픽셀 경계 엄격 클램핑
        pos = Offset(raw.dx.clamp(0.0, frameW), raw.dy.clamp(0.0, frameH));
      }

      // 추출된 프레임이 display 방향이므로 raw 프레임 좌표로 역변환 (rotation 180° 되돌리기):
      //   raw_x = 1 - display_x,  raw_y = 1 - display_y
      // ManualRecorderService / GuidePainter / Renderer는 raw 좌표계를 기대함.
      result.add(TrajectoryPoint(
        frameIndex: frame30,
        centerX: (1.0 - pos.dx / frameW).clamp(0.0, 1.0),
        centerY: (1.0 - pos.dy / frameH).clamp(0.0, 1.0),
        zoom: 1.0,
      ));
    }

    debugPrint('[AI_DONE] ${result.length}개 프레임 궤적 생성 완료');
    return result;
  }

  /// Uniform Catmull-Rom 스플라인 보간 (4개 제어점, t ∈ [0, 1])
  ///
  /// 선형 보간과 달리 인접 제어점의 기울기를 반영해 부드러운 곡선 생성.
  /// 아웃라이어 포인트에서의 V자 꺾임을 곡선으로 완화함.
  ///
  /// q(t) = 0.5 * [ (2P1) + (-P0+P2)t + (2P0-5P1+4P2-P3)t² + (-P0+3P1-3P2+P3)t³ ]
  Offset _catmullRom(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final double t2 = t * t;
    final double t3 = t2 * t;
    return Offset(
      0.5 * ((2 * p1.dx) +
          (-p0.dx + p2.dx) * t +
          (2 * p0.dx - 5 * p1.dx + 4 * p2.dx - p3.dx) * t2 +
          (-p0.dx + 3 * p1.dx - 3 * p2.dx + p3.dx) * t3),
      0.5 * ((2 * p1.dy) +
          (-p0.dy + p2.dy) * t +
          (2 * p0.dy - 5 * p1.dy + 4 * p2.dy - p3.dy) * t2 +
          (-p0.dy + 3 * p1.dy - 3 * p2.dy + p3.dy) * t3),
    );
  }

  /// null 포지션을 인접 값으로 선형 보간 (Kalman 예측 후 남은 null 안전망)
  List<Offset?> _interpolateOffsets(List<Offset?> raw) {
    final filled = List<Offset?>.from(raw);

    // 앞/뒤 null 채우기 (경계값 복사)
    Offset? firstKnown = filled.firstWhere((o) => o != null, orElse: () => null);
    Offset? lastKnown = filled.lastWhere((o) => o != null, orElse: () => null);

    if (firstKnown == null) {
      return List.filled(filled.length, const Offset(0.5, 0.5));
    }

    for (int i = 0; i < filled.length; i++) {
      if (filled[i] == null) {
        filled[i] = firstKnown;
      } else {
        firstKnown = filled[i];
        break;
      }
    }
    for (int i = filled.length - 1; i >= 0; i--) {
      if (filled[i] == null) {
        filled[i] = lastKnown;
      } else {
        lastKnown = filled[i];
        break;
      }
    }

    // 중간 null 보간
    int? gapStart;
    for (int i = 0; i < filled.length; i++) {
      if (filled[i] == null && gapStart == null) {
        gapStart = i;
      } else if (filled[i] != null && gapStart != null) {
        final Offset a = filled[gapStart - 1]!;
        final Offset b = filled[i]!;
        final int gapLen = i - gapStart;
        for (int j = 0; j < gapLen; j++) {
          final double t = (j + 1) / (gapLen + 1);
          filled[gapStart + j] =
              Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
        }
        gapStart = null;
      }
    }

    return filled;
  }
}
