import 'dart:io';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../models/tracking_segment.dart';

/// V5.1: 통합 렌더링 결과 관리 및 결합 서비스
class RenderingQueueService {
  final Queue<TrackingSegment> _queue = Queue<TrackingSegment>();
  TrackingSegment? _currentSegment;
  final List<String> _completedVideos = [];
  Function(double progress, String status)? onProgress;
  bool _isCancelled = false;

  void cancel() {
    _isCancelled = true;
    debugPrint('RenderingQueueService: 작업 취소 요청됨');
  }

  void enqueue(TrackingSegment segment) {
    _queue.add(segment);
  }

  TrackingSegment? dequeue() {
    if (_queue.isEmpty) return null;
    return _queue.removeFirst();
  }

  bool get isEmpty => _queue.isEmpty && _currentSegment == null;

  /// 모든 세그먼트 렌더링 및 결합
  /// V5.1 업데이트: 통합 렌더링 방식에서는 개별 세그먼트가 이미 renderedVideoPath를 가질 수 있음
  Future<String> renderAndConcatenate({
    required List<TrackingSegment> segments,
    String? outputFileName,
  }) async {
    try {
      _completedVideos.clear();

      // 완료된 세그먼트 경로 수집
      for (final segment in segments) {
        if (segment.renderedVideoPath != null) {
          _completedVideos.add(segment.renderedVideoPath!);
        }
      }

      if (_completedVideos.isEmpty) {
        throw Exception('렌더링된 비디오 세그먼트가 없습니다.');
      }

      // 비디오가 1개뿐이라면 (통합 렌더링 성공 시) 결합 과정 없이 즉시 반환
      if (_completedVideos.length == 1) {
        _updateProgress(1.0, '최종 영상 준비 완료');
        return _completedVideos.first;
      }

      _updateProgress(0.95, '세그먼트 결합 중...');

      final finalVideoPath = await _concatenateVideos(
        videoPaths: _completedVideos,
        outputFileName: outputFileName,
      );

      _updateProgress(1.0, '완료!');
      return finalVideoPath;
    } catch (e) {
      debugPrint('렌더링 큐 오류: $e');
      rethrow;
    }
  }

  /// FFmpeg concat을 사용하여 비디오 결합
  Future<String> _concatenateVideos({
    required List<String> videoPaths,
    String? outputFileName,
  }) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final concatFilePath = '${tempDir.path}/concat_list_$timestamp.txt';
      final concatFile = File(concatFilePath);

      final sink = concatFile.openWrite();
      for (final videoPath in videoPaths) {
        final escapedPath = videoPath.replaceAll("'", "'\\''");
        sink.writeln("file '$escapedPath'");
      }
      await sink.flush();
      await sink.close();

      final outputPath = outputFileName != null
          ? '${tempDir.path}/$outputFileName'
          : '${tempDir.path}/final_$timestamp.mp4';

      // [해결] unnecessary_brace_in_string_interps 수정 완료
      // 기존: $concatFilePath -> 중괄호 제거하여 깔끔하게 변경
      final command = '-f concat -safe 0 -i "$concatFilePath" -c copy -y "$outputPath"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        if (await concatFile.exists()) await concatFile.delete();
        return outputPath;
      } else {
        final log = await session.getAllLogsAsString();
        throw Exception('결합 실패: $log');
      }
    } catch (e) {
      rethrow;
    }
  }

  void _updateProgress(double progress, String status) {
    onProgress?.call(progress, status);
    // [해결] 로그 출력 시 불필요한 중괄호 제거
    debugPrint('[${(progress * 100).toStringAsFixed(0)}%] $status');
  }

  void clear() {
    _queue.clear();
    _currentSegment = null;
    _completedVideos.clear();
  }
}