import 'package:flutter/material.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/services/cleanup_service.dart';

class ResultScreen extends StatefulWidget {
  final String videoPath;
  final int strikeCount;
  final bool canGoBack; // 스타일 선택 화면으로 돌아갈 수 있는지 여부

  const ResultScreen({
    super.key,
    required this.videoPath,
    required this.strikeCount,
    this.canGoBack = true, // 기본값: 뒤로가기 가능
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  late VideoPlayerController _controller;
  final CleanupService _cleanupService = CleanupService();
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;
  int _rotation = 0; // 현재 회전 각도 (0, 90, 180, 270)
  bool _isRotating = false; // 회전 처리 중

  @override
  void initState() {
    super.initState();
    _initializeVideo();
    _cleanupTempFiles();
  }

  Future<void> _cleanupTempFiles() async {
    // 비디오 플레이어 초기화를 위한 안전 지연 (1초)
    await Future.delayed(const Duration(seconds: 1));

    // 임시 파일 정리 (현재 비디오는 제외)
    await _cleanupService.cleanupFightCamFiles(
      excludePath: widget.videoPath,
    );
  }

  Future<void> _initializeVideo() async {
    try {
      debugPrint('비디오 초기화 시작: ${widget.videoPath}');

      _controller = VideoPlayerController.file(File(widget.videoPath));

      await _controller.initialize();

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });

        // 자동 재생 및 반복
        _controller.setLooping(true);
        _controller.play();

        debugPrint('비디오 초기화 완료');
      }
    } catch (e) {
      debugPrint('비디오 초기화 실패: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 비디오를 90도 회전
  Future<void> _rotateVideo() async {
    setState(() {
      _isRotating = true;
    });

    try {
      // 현재 회전 각도에 90도 추가
      final newRotation = (_rotation + 90) % 360;

      debugPrint('비디오 회전: $_rotation도 -> $newRotation도');

      // FFmpeg로 회전된 새 비디오 생성
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final rotatedPath = '${tempDir.path}/fight_cam_rotated_$timestamp.mp4';

      // transpose 필터 값 계산
      String transposeFilter;
      switch (newRotation) {
        case 90:
          transposeFilter = 'transpose=1'; // 90도 시계방향
          break;
        case 180:
          transposeFilter = 'transpose=1,transpose=1'; // 180도
          break;
        case 270:
          transposeFilter = 'transpose=2'; // 90도 반시계방향
          break;
        default:
          transposeFilter = 'transpose=1'; // 기본값
      }

      // FFmpeg 명령어 실행
      final command = '-i "${widget.videoPath}" '
          '-vf "$transposeFilter" '
          '-c:v libx264 -preset ultrafast -crf 23 '
          '-c:a copy '
          '-metadata:s:v:0 rotate=0 '
          '-y "$rotatedPath"';

      debugPrint('FFmpeg 회전 명령어: $command');

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        debugPrint('비디오 회전 성공: $rotatedPath');

        // 기존 비디오 플레이어 정지 및 해제
        await _controller.pause();
        await _controller.dispose();

        // 새 비디오로 교체
        _controller = VideoPlayerController.file(File(rotatedPath));
        await _controller.initialize();
        _controller.setLooping(true);
        await _controller.play();

        if (mounted) {
          setState(() {
            _rotation = newRotation;
            _isRotating = false;
          });
        }

        // 성공 메시지
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('90도 회전되었습니다'),
              backgroundColor: Color(0xFFFF3B3B),
              duration: Duration(seconds: 1),
            ),
          );
        }
      } else {
        throw Exception('FFmpeg 회전 실패');
      }
    } catch (e) {
      debugPrint('비디오 회전 오류: $e');
      if (mounted) {
        setState(() {
          _isRotating = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('회전 실패: $e'),
            backgroundColor: const Color(0xFFFF3B3B),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // 상단 헤더
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  // 뒤로가기 또는 닫기 버튼
                  IconButton(
                    onPressed: () {
                      if (widget.canGoBack) {
                        // 스타일 선택 화면으로 돌아가기
                        Navigator.pop(context);
                      } else {
                        // 홈으로 돌아가기 (전체 스택 제거)
                        Navigator.popUntil(context, (route) => route.isFirst);
                      }
                    },
                    icon: Icon(
                      widget.canGoBack ? Icons.arrow_back : Icons.close,
                      color: Colors.white,
                    ),
                    tooltip: widget.canGoBack ? '다른 스타일 선택' : '홈으로',
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '하이라이트 완성!',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  // 회전 버튼
                  IconButton(
                    onPressed: _isRotating ? null : _rotateVideo,
                    icon: const Icon(Icons.rotate_right),
                    color: const Color(0xFFFF3B3B),
                    tooltip: '90도 회전',
                    iconSize: 28,
                  ),
                  // 재생/일시정지 버튼
                  if (_isInitialized)
                    IconButton(
                      onPressed: () {
                        setState(() {
                          if (_controller.value.isPlaying) {
                            _controller.pause();
                          } else {
                            _controller.play();
                          }
                        });
                      },
                      icon: Icon(
                        _controller.value.isPlaying
                            ? Icons.pause_circle
                            : Icons.play_circle,
                        color: const Color(0xFFFF3B3B),
                        size: 36,
                      ),
                    ),
                ],
              ),
            ),

            // 비디오 플레이어
            Expanded(
              child: Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    _buildVideoPlayer(),
                    // 회전 중 표시
                    if (_isRotating)
                      Container(
                        color: Colors.black.withValues(alpha: 0.7),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(
                              color: Color(0xFFFF3B3B),
                            ),
                            SizedBox(height: 16),
                            Text(
                              '비디오 회전 중...',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // 하단 정보 및 버튼
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  // 통계 정보
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFFFF3B3B).withValues(alpha: 0.2),
                          const Color(0xFFFF3B3B).withValues(alpha: 0.05),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFFF3B3B).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildStatItem(
                          Icons.videocam,
                          '하이라이트',
                          '${widget.strikeCount}개',
                        ),
                        Container(
                          width: 1,
                          height: 40,
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                        _buildStatItem(
                          Icons.speed,
                          '스피드 램핑',
                          '적용됨',
                        ),
                        Container(
                          width: 1,
                          height: 40,
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                        _buildStatItem(
                          Icons.check_circle,
                          '편집',
                          '완료',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 액션 버튼들
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isInitialized ? _saveToGallery : null,
                          icon: const Icon(Icons.save),
                          label: const Text('갤러리 저장'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            side: const BorderSide(
                              color: Color(0xFFFF3B3B),
                              width: 2,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isInitialized ? _shareVideo : null,
                          icon: const Icon(Icons.share),
                          label: const Text('공유하기'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF3B3B),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 하단 버튼: 스타일 변경 또는 처음으로
                  if (widget.canGoBack)
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.style, size: 20),
                        label: const Text('다른 스타일로 편집하기'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFFF3B3B).withValues(alpha: 0.8),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.popUntil(context, (route) => route.isFirst);
                        },
                        icon: const Icon(Icons.home, size: 20),
                        label: const Text('처음으로 돌아가기'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white.withValues(alpha: 0.6),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPlayer() {
    if (_hasError) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            size: 80,
            color: Colors.red,
          ),
          const SizedBox(height: 16),
          const Text(
            '비디오를 재생할 수 없습니다',
            style: TextStyle(
              fontSize: 18,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white54,
            ),
          ),
        ],
      );
    }

    if (!_isInitialized) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(
            color: Color(0xFFFF3B3B),
          ),
          SizedBox(height: 16),
          Text(
            '비디오 로딩 중...',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white70,
            ),
          ),
        ],
      );
    }

    return AspectRatio(
      aspectRatio: _controller.value.aspectRatio,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF3B3B).withValues(alpha: 0.3),
              blurRadius: 30,
              spreadRadius: 5,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: VideoPlayer(_controller),
        ),
      ),
    );
  }

  Widget _buildStatItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(
          icon,
          color: const Color(0xFFFF3B3B),
          size: 28,
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Future<void> _saveToGallery() async {
    try {
      // 갤러리에 저장
      await Gal.putVideo(widget.videoPath);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('갤러리에 저장되었습니다'),
              ],
            ),
            backgroundColor: Color(0xFF00C853),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('갤러리 저장 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(child: Text('저장 실패: $e')),
              ],
            ),
            backgroundColor: const Color(0xFFFF3B3B),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _shareVideo() async {
    try {
      final file = XFile(widget.videoPath);
      await Share.shareXFiles(
        [file],
        text: 'Fight-Cam으로 만든 하이라이트 영상! 🥊',
      );
    } catch (e) {
      debugPrint('공유 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('공유 실패: $e'),
            backgroundColor: const Color(0xFFFF3B3B),
          ),
        );
      }
    }
  }
}
