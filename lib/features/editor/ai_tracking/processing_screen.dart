import 'package:flutter/material.dart';
import 'dart:io';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';

// 서비스 및 모델 임포트
import '../../../core/services/notification_service.dart';
import '../../../core/services/cleanup_service.dart';
import '../../../core/services/segment_processor_service.dart'; 
import '../../../core/models/tracking_segment.dart';
import '../../../core/constants/enums.dart';
import '../shared/result_screen.dart';

class ProcessingScreen extends StatefulWidget {
  final File videoFile;
  final VideoProject project;
  final TargetAspectRatio aspectRatio;
  final VideoQuality quality;
  final int? overrideRotation;
  final bool showTrackingMarker;

  const ProcessingScreen({
    super.key,
    required this.videoFile,
    required this.project,
    required this.aspectRatio,
    required this.quality,
    this.overrideRotation,
    this.showTrackingMarker = false,
  });

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  // [해결] 이제 정상적으로 SegmentProcessorService 클래스를 인식합니다.
  final SegmentProcessorService _processorService = SegmentProcessorService();
  final NotificationService _notificationService = NotificationService();
  final CleanupService _cleanupService = CleanupService();

  double _progress = 0.0;
  String _statusMessage = '비디오 분석 준비 중...';
  String? _errorMessage;
  bool _isCancelling = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // 화면 꺼짐 방지
    _notificationService.init();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startFullProcessing();
    });
  }

  Future<Map<String, int>> _getVideoDimensions(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final stream = session.getMediaInformation()?.getStreams().first;
    int w = stream?.getWidth() ?? 1920;
    int h = stream?.getHeight() ?? 1080;
    return {'width': w, 'height': h};
  }

  Future<void> _startFullProcessing() async {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _progress = 0.0;
      _statusMessage = '비디오 정보 분석 중...';
    });

    try {
      final dimensions = await _getVideoDimensions(widget.videoFile.path);

      final finalVideoPath = await _processorService.processAllSegments(
        project: widget.project,
        aspectRatio: widget.aspectRatio,
        quality: widget.quality,
        videoWidth: dimensions['width']!,
        videoHeight: dimensions['height']!,
        onProgress: (double progress, String status) {
          if (mounted) {
            setState(() {
              _progress = progress;
              _statusMessage = status;
            });
          }
        },
      );

      if (!mounted) return;
      _handleComplete(finalVideoPath);
    } catch (e) {
      debugPrint('프로세싱 에러: $e');
      await _notificationService.cancelAll();
      if (mounted) {
        setState(() {
          if (e.toString().contains('취소')) {
            Navigator.pop(context);
          } else {
            _errorMessage = e.toString();
          }
        });
      }
    }
  }

  void _handleComplete(String outputPath) async {
    await _notificationService.showCompleteNotification(outputPath);
    WakelockPlus.disable();
    await _cleanupService.cleanupFightCamFiles(excludePath: outputPath);
    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ResultScreen(
          videoPath: outputPath,
          strikeCount: 0,
          canGoBack: false,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _processorService.cancel(); 
    _notificationService.cancelAll();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    if (_isCancelling || _errorMessage != null || _progress >= 1.0) return true;
    
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('작업 취소', style: TextStyle(color: Colors.white)),
        content: const Text('직캠 생성을 중단하시겠습니까?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('계속하기')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF3B3B)),
            child: const Text('취소'),
          ),
        ],
      ),
    );

    if (shouldCancel == true) {
      _processorService.cancel();
      setState(() { 
        _isCancelling = true; 
        _statusMessage = '작업 취소 중...'; 
      });
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                _buildHeader(),
                const SizedBox(height: 40),
                Expanded(child: Center(child: _buildContent())),
                if (_errorMessage != null) _buildActionButtons(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        IconButton(
          onPressed: () async {
            if (await _onWillPop() && mounted) Navigator.pop(context);
          },
          icon: const Icon(Icons.arrow_back, color: Colors.white),
        ),
        const SizedBox(width: 8),
        Text(
          _isCancelling ? '작업 취소 중' : '직캠 생성 중',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)
        ),
      ],
    );
  }

  Widget _buildContent() => _errorMessage != null ? _buildErrorView() : _buildProcessingView();

  Widget _buildProcessingView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 160, height: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: _progress,
                strokeWidth: 10,
                color: const Color(0xFFFF3B3B),
                // [해결] 최신 Flutter 문법 권장 사항
                backgroundColor: Colors.white.withValues(alpha: 0.1),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${(_progress * 100).toInt()}%',
                    style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white)
                  ),
                  const Text('완료', style: TextStyle(fontSize: 14, color: Colors.white70)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 48),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _statusMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '관성 스무딩 필터 및 풀바디 보정 알고리즘 적용 중...\n전문적인 카메라 워킹을 위해 정밀 분석을 수행합니다.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.white54, height: 1.5),
        ),
      ],
    );
  }

  Widget _buildErrorView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, size: 100, color: Colors.red),
        const SizedBox(height: 24),
        const Text('생성 중 오류 발생', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 16),
        Text(_errorMessage ?? '알 수 없는 오류', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.white70)),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _startFullProcessing,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF3B3B), padding: const EdgeInsets.symmetric(vertical: 16)),
            child: const Text('다시 시도', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => Navigator.popUntil(context, (route) => route.isFirst),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), side: const BorderSide(color: Color(0xFFFF3B3B), width: 2)),
            child: const Text('처음으로 돌아가기', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFFF3B3B))),
          ),
        ),
      ],
    );
  }
}