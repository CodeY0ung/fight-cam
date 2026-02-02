import 'detected_person.dart';

/// V5.0: 10초 단위 추적 세그먼트 (구간별 독립성)
class TrackingSegment {
  final int segmentIndex; // 0, 1, 2, ... (10초 단위)
  final Duration startTime; // 세그먼트 시작 시간
  final Duration endTime; // 세그먼트 종료 시간

  DetectedPerson? initialTarget; // 사용자 지정 타겟 (null = Gap)
  SegmentState state; // 세그먼트 상태

  // 추적 결과 (확정 후 저장)
  List<Point>? trajectory;
  List<BoundingBox>? trajectoryBoxes;
  List<bool>? freezeFlags;

  // 렌더링 결과
  String? renderedVideoPath; // 백그라운드 렌더링 완료 시 경로
  bool isRendering; // 렌더링 진행 중

  TrackingSegment({
    required this.segmentIndex,
    required this.startTime,
    required this.endTime,
    this.initialTarget,
    this.state = SegmentState.empty,
    this.trajectory,
    this.trajectoryBoxes,
    this.freezeFlags,
    this.renderedVideoPath,
    this.isRendering = false,
  });

  /// 세그먼트 길이 (초)
  double get durationSeconds => (endTime - startTime).inMilliseconds / 1000.0;

  /// 타겟이 지정되었는지 여부
  bool get hasTarget => initialTarget != null;

  /// 렌더링 완료 여부
  bool get isRendered => renderedVideoPath != null;

  /// 확정 가능 여부 (타겟 지정 완료 or Gap으로 명시적 설정)
  bool get canConfirm => state == SegmentState.targetSet || state == SegmentState.gap;

  /// 확정 여부
  bool get isConfirmed => state == SegmentState.confirmed;

  @override
  String toString() {
    return 'Segment[$segmentIndex] ${startTime.inSeconds}s-${endTime.inSeconds}s: $state';
  }
}

/// 세그먼트 상태
enum SegmentState {
  empty,          // 비어있음 (사용자 아직 설정 안함)
  targetSet,      // 타겟 지정됨 (확정 대기)
  gap,            // Gap 구간 (타겟 없음, 전체 화면)
  confirmed,      // 확정됨 (추적 완료)
  rendering,      // 렌더링 중
  completed,      // 렌더링 완료
}

/// V5.0: 세그먼트 기반 비디오 프로젝트
class VideoProject {
  final String videoPath;
  final Duration totalDuration;
  final double fps;
  final List<TrackingSegment> segments;

  VideoProject({
    required this.videoPath,
    required this.totalDuration,
    required this.fps,
    required this.segments,
  });

  /// 10초 단위로 세그먼트 생성
  factory VideoProject.create({
    required String videoPath,
    required Duration totalDuration,
    required double fps,
    int segmentDurationSeconds = 10,
  }) {
    final segments = <TrackingSegment>[];
    final totalSeconds = totalDuration.inSeconds;

    for (int i = 0; i < (totalSeconds / segmentDurationSeconds).ceil(); i++) {
      final startSec = i * segmentDurationSeconds;
      final endSec = (startSec + segmentDurationSeconds).clamp(0, totalSeconds);

      segments.add(TrackingSegment(
        segmentIndex: i,
        startTime: Duration(seconds: startSec),
        endTime: Duration(seconds: endSec),
      ));
    }

    return VideoProject(
      videoPath: videoPath,
      totalDuration: totalDuration,
      fps: fps,
      segments: segments,
    );
  }

  /// 진행률 (%)
  double get progressPercentage {
    final completed = segments.where((s) => s.isConfirmed).length;
    return (completed / segments.length) * 100;
  }

  /// 모든 세그먼트 확정 완료 여부
  bool get isAllConfirmed => segments.every((s) => s.isConfirmed);

  /// 다음 작업할 세그먼트
  TrackingSegment? get nextSegment {
    return segments.firstWhere(
      (s) => s.state == SegmentState.empty,
      orElse: () => segments.first,
    );
  }
}
