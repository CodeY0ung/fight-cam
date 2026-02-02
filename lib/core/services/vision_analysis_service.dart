import 'dart:io';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../models/detected_person.dart';

class VisionAnalysisService {
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(mode: PoseDetectionMode.stream, model: PoseDetectionModel.accurate),
  );

  bool _isCancelled = false;
  void cancel() => _isCancelled = true;

  Future<TrackingData> trackTarget({
    required File videoFile,
    required DetectedPerson initialTarget,
    required Duration startTime,
    required Duration endTime,
    int samplingInterval = 200, 
    bool isSegmentMode = false,
  }) async {
    if (_isCancelled) throw Exception("취소됨");

    final timestamps = <int>[];
    // [해결] ms < endTime을 ms <= endTime으로 수정하여 마지막 1프레임(0.2초) 유실 방지
    for (int ms = startTime.inMilliseconds; ms <= endTime.inMilliseconds; ms += samplingInterval) {
      timestamps.add(ms);
    }
    if (timestamps.isEmpty) timestamps.add(startTime.inMilliseconds);

    final result = await _trackFrames(videoFile, timestamps, initialTarget, samplingInterval);
    
    return TrackingData(
      trajectoryA: result.trajectory,
      trajectoryBoxA: result.boxes,
      freezeFlags: result.freezes,
      totalFrames: result.trajectory.length,
      fps: 30.0,
      startTime: startTime,
    );
  }

  Pose? _findBestMatch(List<Pose> poses, Point currentPos) {
    if (poses.isEmpty) return null;
    Pose? bestPose;
    double minDistance = double.infinity;
    const double searchRadius = 0.25;

    for (final pose in poses) {
      final nose = pose.landmarks[PoseLandmarkType.nose];
      if (nose == null) continue;
      final posePos = Point(nose.x / 1280, nose.y / 720);
      
      final dist = (posePos.x - currentPos.x).abs() + (posePos.y - currentPos.y).abs();
      if (dist < minDistance && dist < searchRadius) {
        minDistance = dist;
        bestPose = pose;
      }
    }
    return bestPose;
  }

  Future<({List<Point> trajectory, List<BoundingBox> boxes, List<bool> freezes})> _trackFrames(
    File videoFile, List<int> timestamps, DetectedPerson target, int samplingInterval
  ) async {
    final trajectory = <Point>[];
    final boxes = <BoundingBox>[];
    final freezes = <bool>[];

    Point currentPos = target.center;
    BoundingBox currentBox = target.boundingBox;

    for (int i = 0; i < timestamps.length; i++) {
      if (_isCancelled) throw Exception("취소됨");
      if (i == 0) {
        trajectory.add(target.center);
        boxes.add(target.boundingBox);
        freezes.add(false);
        continue;
      }

      final path = await VideoThumbnail.thumbnailFile(
        video: videoFile.path, 
        timeMs: timestamps[i], 
        quality: 75,
        maxHeight: 720
      );

      if (path == null) {
        trajectory.add(currentPos);
        boxes.add(currentBox);
        freezes.add(true);
        continue;
      }

      final inputImage = InputImage.fromFilePath(path);
      final poses = await _poseDetector.processImage(inputImage);
      
      final bestPose = _findBestMatch(poses, currentPos);

      if (bestPose == null) {
        // [융합] 타겟 유실 시 위치 고정 및 프리즈 플래그 기록
        trajectory.add(currentPos);
        boxes.add(currentBox);
        freezes.add(true);
      } else {
        final nose = bestPose.landmarks[PoseLandmarkType.nose]!;
        currentPos = Point(nose.x / 1280, nose.y / 720);
        // 포즈 랜드마크를 기반으로 박스 크기를 추정할 수도 있으나, 
        // 안정성을 위해 일단 타겟의 초기 비율을 유지하거나 AI 업데이트를 따름
        trajectory.add(currentPos);
        boxes.add(target.boundingBox); 
        freezes.add(false);
      }
      if (await File(path).exists()) await File(path).delete();
    }
    return (trajectory: trajectory, boxes: boxes, freezes: freezes);
  }

  void dispose() => _poseDetector.close();
}