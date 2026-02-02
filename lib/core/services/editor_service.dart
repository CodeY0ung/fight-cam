import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:path_provider/path_provider.dart';
import '../models/detected_person.dart';
import '../constants/enums.dart';

class CropRect {
  final int x; final int y; final int width; final int height;
  CropRect({required this.x, required this.y, required this.width, required this.height});
}

class EditorService {
  Function(double progress, String status)? onProgress;
  bool _isCancelled = false;

  void cancel() {
    _isCancelled = true;
    FFmpegKit.cancel();
  }

  Future<File> generatePreviewFrame({
    required String videoPath,
    required double timestamp,
    required Point centerPoint,
    required TargetAspectRatio ratio,
    required double cropSizeRatio,
  }) async {
    final crop = calculateCropRect(videoWidth: 1920, videoHeight: 1080, centerPoint: centerPoint, ratio: ratio, cropSizeRatio: cropSizeRatio);
    final tempDir = await getTemporaryDirectory();
    final outputPath = '${tempDir.path}/prev_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await FFmpegKit.execute('-ss $timestamp -i "$videoPath" -vf "crop=${crop.width}:${crop.height}:${crop.x}:${crop.y}" -frames:v 1 -y "$outputPath"');
    return File(outputPath);
  }

  /// [튜닝] 줌 배율 일관성 확보를 위한 로직 수정
  CropRect calculateGuaranteedCropRect({
    required int videoWidth,
    required int videoHeight,
    required Point centerPoint,
    required BoundingBox targetBox,
    required TargetAspectRatio ratio,
    double padding = 0.4, // 패딩을 늘려 인물이 화면에 너무 꽉 차지 않게 조절
  }) {
    double r = ratio == TargetAspectRatio.vertical_9_16 ? 9/16 : (ratio == TargetAspectRatio.landscape_16_9 ? 16/9 : 1.0);

    // [개선] Gap 구간 예외 처리
    if (targetBox.height >= 0.98) {
      int cw = (videoHeight * r).toInt();
      if (cw > videoWidth) cw = videoWidth;
      int ch = (cw / r).toInt();
      int cx = (videoWidth - cw) ~/ 2;
      int cy = (videoHeight - ch) ~/ 2;
      return CropRect(x: (cx~/2)*2, y: (cy~/2)*2, width: (cw~/2)*2, height: (ch~/2)*2);
    }

    // [줌 안정화 핵심] AI가 주는 가변적인 높이 대신, 표준 전신 비율(0.45)에 가깝게 강제 수렴
    // 이렇게 하면 상반신만 인식되어도 카메라 줌이 확 당겨지지 않습니다.
    double stabilizedH = targetBox.height.clamp(0.4, 0.5); 
    
    double boxW = targetBox.width * videoWidth;
    double boxH = stabilizedH * videoHeight;

    double requiredH = boxH * (1 + padding);
    double requiredW = requiredH * r;

    if (requiredW < boxW * (1 + padding)) {
      requiredW = boxW * (1 + padding);
      requiredH = requiredW / r;
    }

    // 줌 제한: 너무 타이트한 줌 방지 (최소 화면의 45% 높이 확보)
    int ch = requiredH.toInt().clamp((videoHeight * 0.45).toInt(), videoHeight);
    int cw = (ch * r).toInt();

    if (cw > videoWidth) {
      cw = videoWidth;
      ch = (cw / r).toInt();
    }

    int cx = (centerPoint.x * videoWidth - cw / 2).toInt().clamp(0, videoWidth - cw);
    int cy = (centerPoint.y * videoHeight - ch / 2).toInt().clamp(0, videoHeight - ch);

    return CropRect(x: (cx~/2)*2, y: (cy~/2)*2, width: (cw~/2)*2, height: (ch~/2)*2);
  }

  double _smoothStep(double t) {
    t = t.clamp(0.0, 1.0);
    return t * t * t * (t * (t * 6 - 15) + 10);
  }

  List<Point> calculateSmoothTrajectory({
    required List<Point> rawTrajectory,
    required List<int> anchorIndices,
  }) {
    if (rawTrajectory.isEmpty) return [];
    List<Point> smoothPath = List.from(rawTrajectory);
    const int bridgeWindow = 45; // 보간 윈도우를 늘려 세그먼트 간 이동을 더 느릿하게 수정

    for (int i = 0; i < anchorIndices.length; i++) {
      int anchorIdx = anchorIndices[i];
      if (anchorIdx == 0) continue;
      for (int j = 1; j <= bridgeWindow; j++) {
        int targetIdx = anchorIdx - j;
        if (targetIdx < 0) continue;
        double rawT = 1.0 - (j / bridgeWindow);
        double t = _smoothStep(rawT);
        smoothPath[targetIdx] = Point(
          rawTrajectory[targetIdx].x * (1 - t) + rawTrajectory[anchorIdx].x * t,
          rawTrajectory[targetIdx].y * (1 - t) + rawTrajectory[anchorIdx].y * t,
        );
      }
    }
    return smoothPath;
  }

  Future<String> generateIntegratedVideo({
    required String videoPath,
    required TrackingData trackingData,
    required List<BoundingBox> allBoxes,
    required int samplingInterval,
    TargetAspectRatio aspectRatio = TargetAspectRatio.vertical_9_16,
    VideoQuality quality = VideoQuality.hd,
  }) async {
    if (_isCancelled) throw Exception("작업이 취소되었습니다.");
    final tempDir = await getTemporaryDirectory();
    final outputPath = '${tempDir.path}/final_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final commandFilePath = await _generateCropCommandFile(
      trajectory: trackingData.trajectoryA,
      allBoxes: allBoxes,
      aspectRatio: aspectRatio,
      samplingInterval: samplingInterval,
    );

    final baseSize = quality.baseSize;
    int outW = (aspectRatio == TargetAspectRatio.vertical_9_16) ? (baseSize * 9 / 16).round() : baseSize;
    int outH = baseSize;

    final totalDuration = (trackingData.totalFrames * samplingInterval) / 1000.0;

    final cmd = '-ss 0 -t ${totalDuration.toStringAsFixed(3)} -i "$videoPath" '
        '-vf "sendcmd=f=$commandFilePath,crop=w=iw:h=ih,scale=${(outW~/2)*2}:${(outH~/2)*2},format=yuv420p" '
        '-c:v libx264 -preset superfast -crf 18 -c:a copy -y "$outputPath"';

    await FFmpegKit.execute(cmd);
    return outputPath;
  }

  Future<String> _generateCropCommandFile({
    required List<Point> trajectory,
    required List<BoundingBox> allBoxes,
    required TargetAspectRatio aspectRatio,
    required int samplingInterval,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/cmd_${DateTime.now().millisecondsSinceEpoch}.txt';
    final sink = File(path).openWrite();
    final frameDuration = samplingInterval / 1000.0;

    for (int i = 0; i < trajectory.length; i++) {
      final rect = calculateGuaranteedCropRect(
        videoWidth: 1920,
        videoHeight: 1080,
        centerPoint: trajectory[i],
        targetBox: allBoxes[i],
        ratio: aspectRatio,
      );
      sink.writeln('${(i * frameDuration).toStringAsFixed(4)} [enter] crop x ${rect.x}, crop y ${rect.y}, crop w ${rect.width}, crop h ${rect.height};');
    }
    await sink.close();
    return path;
  }

  CropRect calculateCropRect({required int videoWidth, required int videoHeight, required Point centerPoint, required TargetAspectRatio ratio, required double cropSizeRatio}) {
    double r = ratio == TargetAspectRatio.vertical_9_16 ? 9 / 16 : 1.0;
    int ch = (videoHeight * cropSizeRatio).toInt();
    int cw = (ch * r).toInt();
    if (cw > videoWidth) { cw = videoWidth; ch = (cw / r).toInt(); }
    int cx = (centerPoint.x * videoWidth - cw / 2).toInt().clamp(0, videoWidth - cw);
    int cy = (centerPoint.y * videoHeight - ch / 2).toInt().clamp(0, videoHeight - ch);
    return CropRect(x: (cx ~/ 2) * 2, y: (cy ~/ 2) * 2, width: (cw ~/ 2) * 2, height: (ch ~/ 2) * 2);
  }
}