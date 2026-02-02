import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart'; 
import '../models/tracking_segment.dart';
import '../models/detected_person.dart';
import '../constants/enums.dart';
import 'editor_service.dart';
import 'vision_analysis_service.dart';
import '../utils/kalman_filter.dart';

class SegmentProcessorService {
  final EditorService _editorService = EditorService();
  final VisionAnalysisService _visionService = VisionAnalysisService();
  static const double targetFps = 30.0;
  static const double dt = 1.0 / targetFps;

  void cancel() { _visionService.cancel(); _editorService.cancel(); }

  Future<String> processAllSegments({
    required VideoProject project,
    required TargetAspectRatio aspectRatio,
    required VideoQuality quality,
    required int videoWidth,
    required int videoHeight,
    Function(double progress, String status)? onProgress,
  }) async {
    try {
      List<Point> upsampledTrajectory = [];
      List<BoundingBox> upsampledBoxes = [];
      List<int> anchorIndices = [];

      final abgFilter = AlphaBetaGammaFilter2D();
      final sizeFilter = KalmanFilter1D();

      for (int i = 0; i < project.segments.length; i++) {
        final segment = project.segments[i];
        
        // 필터 초기화 (첫 시작 시)
        if (i == 0 && segment.initialTarget != null) {
          abgFilter.init(segment.initialTarget!.center);
          sizeFilter.init(segment.initialTarget!.boundingBox.height);
        }

        // --- [Gap 구간 처리: 예측 기반 줌 아웃 & 줌 인] ---
        if (segment.initialTarget == null || segment.state == SegmentState.gap) {
          onProgress?.call(i / project.segments.length, '구간 #${i + 1} 시네마틱 전환 중...');
          
          double duration = (segment.endTime.inMilliseconds - segment.startTime.inMilliseconds) / 1000.0;
          int frames = (duration * targetFps).round();
          anchorIndices.add(upsampledTrajectory.length);

          // 이전 세그먼트의 마지막 위치/줌
          Point startPos = upsampledTrajectory.isNotEmpty ? upsampledTrajectory.last : Point(0.5, 0.5);
          double startH = upsampledBoxes.isNotEmpty ? upsampledBoxes.last.height : 0.45;

          // [Look-ahead] 다음 세그먼트의 목표 위치/줌 미리 파악
          Point nextTargetPos = Point(0.5, 0.5);
          double nextTargetH = 0.45;
          if (i + 1 < project.segments.length && project.segments[i+1].initialTarget != null) {
            nextTargetPos = project.segments[i+1].initialTarget!.center;
            nextTargetH = project.segments[i+1].initialTarget!.boundingBox.height;
          }

          for (int f = 0; f < frames; f++) {
            double t = f / frames;
            double curX, curY, curH;

            // 곡선형 보간 (S-Curve)
            double smoothT = t * t * (3 - 2 * t);

            if (t < 0.5) {
              // 1. 전반부: 이전 타겟에서 전체 화면으로 서서히 풀림 (Zoom Out)
              double localT = t * 2;
              double s = localT * localT * (3 - 2 * localT);
              curX = lerpDouble(startPos.x, 0.5, s)!;
              curY = lerpDouble(startPos.y, 0.5, s)!;
              curH = lerpDouble(startH, 1.0, s)!;
            } else {
              // 2. 후반부: 전체 화면에서 다음 타겟으로 서서히 조여짐 (Zoom In)
              double localT = (t - 0.5) * 2;
              double s = localT * localT * (3 - 2 * localT);
              curX = lerpDouble(0.5, nextTargetPos.x, s)!;
              curY = lerpDouble(0.5, nextTargetPos.y, s)!;
              curH = lerpDouble(1.0, nextTargetH, s)!;
            }

            upsampledTrajectory.add(Point(curX, curY));
            upsampledBoxes.add(BoundingBox(left: curX, top: curY, width: 0.5, height: curH));
            
            // 필터 상태 유지 (다음 세그먼트 연결용)
            abgFilter.x = curX; abgFilter.y = curY;
            sizeFilter.v = curH;
          }
          continue;
        }

        // --- [트래킹 구간 처리] ---
        onProgress?.call(i / project.segments.length, '구간 #${i + 1} 정밀 분석 중...');
        final result = await _visionService.trackTarget(
          videoFile: File(project.videoPath),
          initialTarget: segment.initialTarget!,
          startTime: segment.startTime,
          endTime: segment.endTime, 
          samplingInterval: 200,
          isSegmentMode: true,
        );

        anchorIndices.add(upsampledTrajectory.length);
        double segmentDurationSec = (segment.endTime.inMilliseconds - segment.startTime.inMilliseconds) / 1000.0;
        int totalFramesInSegment = (segmentDurationSec * targetFps).round();

        for (int f = 0; f < totalFramesInSegment; f++) {
          double frameTime = f * dt;
          int aiIdx = (frameTime / 0.2).floor().clamp(0, result.trajectoryA.length - 1);
          
          if (result.freezeFlags[aiIdx] == false) {
            abgFilter.update(result.trajectoryA[aiIdx], dt);
          } else {
            abgFilter.predict(dt); // 유실 시 관성 유지
          }

          upsampledTrajectory.add(Point(abgFilter.x, abgFilter.y));
          
          double targetH = result.trajectoryBoxA[aiIdx].height.clamp(0.3, 0.8);
          double sH = sizeFilter.filter(targetH);
          
          upsampledBoxes.add(BoundingBox(
            left: result.trajectoryBoxA[aiIdx].left, 
            top: result.trajectoryBoxA[aiIdx].top, 
            width: result.trajectoryBoxA[aiIdx].width, 
            height: sH,
          ));
        }
      }

      // [V4.1 후처리 스무딩] 전체 경로를 다시 한 번 부드럽게 깎음
      final smoothedPath = _applyMovingAverage(upsampledTrajectory, 30);
      final smoothedBoxes = _applyTrailingAverage(upsampledBoxes, 60);

      final trackingData = TrackingData(
        trajectoryA: smoothedPath,
        trajectoryBoxA: smoothedBoxes,
        freezeFlags: List.filled(smoothedPath.length, false), 
        totalFrames: smoothedPath.length,
        fps: targetFps,
        startTime: Duration.zero,
      );

      return await _editorService.generateIntegratedVideo(
        videoPath: project.videoPath,
        trackingData: trackingData,
        allBoxes: smoothedBoxes,
        samplingInterval: 33, 
        aspectRatio: aspectRatio,
        quality: quality,
      );
    } catch (e) { 
      debugPrint('오류 발생: $e');
      rethrow; 
    }
  }

  // 위치 스무딩 (전후 1초)
  List<Point> _applyMovingAverage(List<Point> path, int window) {
    List<Point> res = [];
    for (int i = 0; i < path.length; i++) {
      int s = (i - window ~/ 2).clamp(0, path.length - 1);
      int e = (i + window ~/ 2).clamp(0, path.length - 1);
      double sx = 0, sy = 0;
      for (int j = s; j <= e; j++) { sx += path[j].x; sy += path[j].y; }
      res.add(Point(sx / (e - s + 1), sy / (e - s + 1)));
    }
    return res;
  }

  // 줌 스무딩 (과거 2초)
  List<BoundingBox> _applyTrailingAverage(List<BoundingBox> boxes, int window) {
    List<BoundingBox> res = [];
    for (int i = 0; i < boxes.length; i++) {
      int s = (i - window).clamp(0, i);
      double sh = 0;
      for (int j = s; j <= i; j++) { sh += boxes[j].height; }
      res.add(BoundingBox(
        left: boxes[i].left, top: boxes[i].top, width: boxes[i].width, 
        height: sh / (i - s + 1),
      ));
    }
    return res;
  }
}