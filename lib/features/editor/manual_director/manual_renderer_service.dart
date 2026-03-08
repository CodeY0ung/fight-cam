import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/models/detected_person.dart';
import '../../../core/constants/enums.dart';
import 'manual_recorder_service.dart';

/// 수동 디렉터 모드의 렌더링 서비스
/// 고화질 업스케일링, 디노이즈, 샤프닝 마스터링 공정 포함
class ManualRendererService {
  Function(double progress, String status)? onProgress;
  bool _isCancelled = false;

  /// 워터마크 활성화 여부 (향후 유료 결제 시 false로 전환 가능)
  /// 현재는 항상 true로 고정
  bool _isWatermarkEnabled = true;

  /// 워터마크 활성화 상태 확인
  bool get isWatermarkEnabled => _isWatermarkEnabled;

  /// 워터마크 활성화/비활성화 (향후 결제 연동용)
  /// 현재 버전에서는 내부적으로 항상 true로 강제됨
  void setWatermarkEnabled(bool enabled) {
    // TODO: 유료 결제 검증 로직 추가 후 아래 라인 활성화
    // _isWatermarkEnabled = enabled;
    _isWatermarkEnabled = true; // 현재 버전: 항상 강제 적용
  }

  void cancel() { _isCancelled = true; FFmpegKit.cancel(); }
  void reset() => _isCancelled = false;

  Future<String> render({
    required String videoPath,
    required ManualRecorderService recorderService,
    required TargetAspectRatio aspectRatio,
    required VideoQuality quality,
    required double videoAspectRatio,
    required int totalDurationMs,
  }) async {
    if (_isCancelled) throw Exception('인코딩 취소됨');

    onProgress?.call(0.1, '데이터 분석 및 보간 중...');
    final (rawTrajectory, rawZoomLevels) = recorderService.getContinuousTrajectory();
    
    // 1단계: 궤적 스무딩 (부드러운 카메라 워킹)
    final smoothedTrajectory = recorderService.applyMovingAverageToTrajectory(rawTrajectory, windowFrames: 36);
    final smoothedZoom = recorderService.applyTrailingAverageToZoom(rawZoomLevels, windowFrames: 60);

    onProgress?.call(0.3, '모서리 떨림 방지 및 좌표 정밀 계산 중...');
    // 2단계: 박스 생성 시 'Safe Zone' 적용 (모서리 떨림 원천 차단)
    final boxes = _generateBoundingBoxes(
      trajectory: smoothedTrajectory,
      zoomLevels: smoothedZoom,
      aspectRatio: aspectRatio,
      videoAspectRatio: videoAspectRatio,
    );

    final commandFilePath = await _generateCropCommandFile(boxes);

    onProgress?.call(0.5, '고화질 마스터링 및 인코딩 시작...');
    // 3단계: 디노이즈 -> 크롭 -> 업스케일 -> 샤프닝 -> 워터마크 연쇄 필터 적용
    final outputPath = await _executeFFmpeg(
      videoPath: videoPath,
      commandFilePath: commandFilePath,
      totalDurationMs: totalDurationMs,
      aspectRatio: aspectRatio,
      quality: quality,
    );

    onProgress?.call(1.0, '완료!');
    return outputPath;
  }

  List<BoundingBox> _generateBoundingBoxes({
    required List<Point> trajectory,
    required List<double> zoomLevels,
    required TargetAspectRatio aspectRatio,
    required double videoAspectRatio,
  }) {
    final boxes = <BoundingBox>[];
    
    double targetAspect;
    switch (aspectRatio) {
      case TargetAspectRatio.vertical_9_16: targetAspect = 9/16; break;
      case TargetAspectRatio.square_1_1: targetAspect = 1.0; break;
      case TargetAspectRatio.portrait_4_5: targetAspect = 4/5; break;
      case TargetAspectRatio.landscape_16_9: targetAspect = 16/9; break;
    }

    for (int i = 0; i < trajectory.length; i++) {
      final pos = trajectory[i];
      final zoom = i < zoomLevels.length ? zoomLevels[i] : 1.0;

      double h = (ManualRecorderService.kDefaultBoxScale / zoom).clamp(0.05, 1.0);
      double w = (h * targetAspect) / videoAspectRatio;

      if (w > 1.0) {
        w = 1.0;
        h = (w * videoAspectRatio) / targetAspect;
      }

      // Safe Zone Clamping: 모서리 떨림 방지
      final double halfW = w / 2;
      final double halfH = h / 2;
      final double safeCenterX = pos.x.clamp(halfW, 1.0 - halfW);
      final double safeCenterY = pos.y.clamp(halfH, 1.0 - halfH);

      boxes.add(BoundingBox(
        left: safeCenterX - halfW,
        top: safeCenterY - halfH,
        width: w,
        height: h,
      ));
    }
    return boxes;
  }

  Future<String> _generateCropCommandFile(List<BoundingBox> boxes) async {
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/manual_cmd_${DateTime.now().millisecondsSinceEpoch}.txt';
    final sink = File(path).openWrite();

    const vW = 1920; const vH = 1080;

    for (int i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      int cW = (b.width * vW).round();
      int cH = (b.height * vH).round();
      int cX = (b.left * vW).round();
      int cY = (b.top * vH).round();

      cW = (cW ~/ 2) * 2; cH = (cH ~/ 2) * 2;
      cX = (cX ~/ 2) * 2; cY = (cY ~/ 2) * 2;

      if (cX + cW > vW) cX = vW - cW;
      if (cY + cH > vH) cY = vH - cH;
      if (cX < 0) cX = 0;
      if (cY < 0) cY = 0;

      final ts = (i * 0.03333).toStringAsFixed(4);
      sink.writeln('$ts [enter] crop x $cX, crop y $cY, crop w $cW, crop h $cH;');
    }
    await sink.close();
    return path;
  }

  /// 플랫폼별 시스템 폰트 경로 반환
  String _getSystemFontPath() {
    if (Platform.isIOS) {
      return '/System/Library/Fonts/Helvetica.ttc';
    } else {
      return '/system/fonts/Roboto-Regular.ttf';
    }
  }

  /// drawtext 필터 문자열 생성
  /// 우측 하단에 fight-cam / just sparring 2줄 상시 표시
  String _buildWatermarkFilter({
    required int outH,
  }) {
    if (!_isWatermarkEnabled) return '';

    final fontPath = _getSystemFontPath();
    final int fontSize = (outH * 0.020).round().clamp(14, 32);
    final int lineGap = (fontSize * 1.4).round();

    // 1행: 'fight-cam' (우측 하단, 위쪽 줄)
    final String line1 =
        "drawtext=text='fight-cam'"
        ":fontfile='$fontPath'"
        ':fontsize=$fontSize'
        ':fontcolor=white@0.4'
        ':x=w-tw-20:y=h-$lineGap-20';

    // 2행: 'just sparring' (우측 하단, 아래쪽 줄)
    final String line2 =
        "drawtext=text='just sparring'"
        ":fontfile='$fontPath'"
        ':fontsize=$fontSize'
        ':fontcolor=white@0.4'
        ':x=w-tw-20:y=h-th-20';

    return ',$line1,$line2';
  }

  Future<String> _executeFFmpeg({
    required String videoPath,
    required String commandFilePath,
    required int totalDurationMs,
    required TargetAspectRatio aspectRatio,
    required VideoQuality quality,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final outputPath = '${tempDir.path}/manual_mastered_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // 업스케일링 목표 해상도: FHD(1080p)
    const int targetH = 1080;
    int outW, outH;
    switch (aspectRatio) {
      case TargetAspectRatio.vertical_9_16: outW = (targetH * 9/16).round(); outH = targetH; break;
      case TargetAspectRatio.square_1_1: outW = targetH; outH = targetH; break;
      case TargetAspectRatio.portrait_4_5: outW = (targetH * 4/5).round(); outH = targetH; break;
      case TargetAspectRatio.landscape_16_9: outW = targetH; outH = (targetH * 9/16).round(); break;
    }
    outW = (outW ~/ 2) * 2; outH = (outH ~/ 2) * 2;

    // 워터마크 필터 (처리 완료된 고화질 화면 위에 최종 적용)
    final String watermarkFilter = _buildWatermarkFilter(
      outH: outH,
    );

    // [마스터링 필터 체인 설명]
    // 1. hqdn3d: 업스케일 전 노이즈 제거 (화면 자글거림 방지)
    // 2. sendcmd+crop: 사용자 지정 궤적대로 크롭
    // 3. scale+lanczos: 고성능 알고리즘으로 화질 보존하며 확대
    // 4. unsharp: 확대 시 흐려진 윤곽선을 다시 뚜렷하게 보정
    // 5. drawtext: 워터마크 (영상 처리 완료 후 최종 단계에서 삽입)
    final String filterChain =
        'hqdn3d=4:3:6:4.5,'
        'sendcmd=f=$commandFilePath,crop=w=iw:h=ih,'
        'scale=$outW:$outH:flags=lanczos,'
        'unsharp=3:3:0.8:3:3:0.0'
        '$watermarkFilter,'
        'format=yuv420p';

    final cmd = '-ss 0 -t ${(totalDurationMs / 1000).toStringAsFixed(3)} -i "$videoPath" '
        '-vf "$filterChain" '
        '-c:v libx264 -preset veryfast -crf 16 -tune film -r 30 -c:a copy -y "$outputPath"';

    debugPrint('FFmpeg 명령어: $cmd');

    final session = await FFmpegKit.execute(cmd);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) throw Exception('마스터링 인코딩 실패');

    // 렌더링 speed 값 확인 (성능 모니터링)
    final logs = await session.getLogs();
    for (final log in logs.reversed) {
      final msg = log.getMessage();
      final match = RegExp(r'speed=\s*([\d.]+)x').firstMatch(msg);
      if (match != null) {
        debugPrint('[ManualRenderer] 렌더링 속도: ${match.group(1)}x realtime');
        break;
      }
    }

    return outputPath;
  }
}