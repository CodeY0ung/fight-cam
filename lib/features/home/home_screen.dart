import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import '../editor/ai_tracking/ai_target_selection_screen.dart';
import '../editor/manual_director/manual_director_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();
  bool _isLoading = false;

  /// 임시 구글 폼 제보 링크 (추후 실제 링크로 교체)
  static const String _submissionFormUrl = 'https://forms.gle/PLACEHOLDER_FIGHT_CAM';

  Future<void> _openSubmissionForm() async {
    final uri = Uri.parse(_submissionFormUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('링크를 열 수 없습니다.'),
            backgroundColor: Color(0xFFFF3B3B),
          ),
        );
      }
    }
  }

  Future<void> _pickVideoForAiMode() async {
    setState(() => _isLoading = true);
    try {
      final status = await _checkPermissions();
      if (!status) {
        if (mounted) _showPermissionDialog();
        setState(() => _isLoading = false);
        return;
      }
      final XFile? video = await _picker.pickVideo(source: ImageSource.gallery);
      if (video != null && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AiTargetSelectionScreen(videoPath: video.path),
          ),
        );
      }
    } catch (e) {
      if (mounted) _showErrorDialog('비디오를 불러오는 중 오류가 발생했습니다.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickVideoForManualMode() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final status = await _checkPermissions();
      if (!status) {
        if (mounted) {
          _showPermissionDialog();
        }
        setState(() {
          _isLoading = false;
        });
        return;
      }

      final XFile? video = await _picker.pickVideo(
        source: ImageSource.gallery,
      );

      if (video != null && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ManualDirectorScreen(videoPath: video.path),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error picking video: $e');
      if (mounted) {
        _showErrorDialog('비디오를 불러오는 중 오류가 발생했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<bool> _checkPermissions() async {
    if (Platform.isAndroid) {
      // Android 13 이상에서는 photos/videos 권한 필요
      final androidInfo = await _getAndroidVersion();
      if (androidInfo >= 33) {
        final status = await Permission.videos.status;
        if (!status.isGranted) {
          final result = await Permission.videos.request();
          return result.isGranted;
        }
        return true;
      } else {
        // Android 12 이하에서는 storage 권한
        final status = await Permission.storage.status;
        if (!status.isGranted) {
          final result = await Permission.storage.request();
          return result.isGranted;
        }
        return true;
      }
    } else if (Platform.isIOS) {
      final status = await Permission.photos.status;
      if (!status.isGranted) {
        final result = await Permission.photos.request();
        return result.isGranted;
      }
      return true;
    }
    return true;
  }

  Future<int> _getAndroidVersion() async {
    // Android SDK version을 가져오는 간단한 방법
    // device_info_plus 패키지 없이 기본값 반환
    return 29; // 기본적으로 Android 10 가정
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          '권한 필요',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '갤러리에서 비디오를 불러오려면 저장소 접근 권한이 필요합니다.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('설정 열기', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          '오류',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 24),
                // 앱 로고/타이틀
                const Icon(
                  Icons.sports_mma,
                  size: 100,
                  color: Color(0xFFFF3B3B),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Fight-Cam',
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '스파링 영상을 프로처럼 편집하세요',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white54,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 48),

                // 감독 트래킹 모드 버튼 (메인)
                GestureDetector(
                  onTap: _isLoading ? null : _pickVideoForManualMode,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFF3B3B), Color(0xFFCC0000)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF3B3B).withValues(alpha: 0.3),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: _isLoading
                        ? const Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 3,
                              ),
                            ),
                          )
                        : const Column(
                            children: [
                              Icon(
                                Icons.videocam,
                                size: 40,
                                color: Colors.white,
                              ),
                              SizedBox(height: 12),
                              Text(
                                '감독 트래킹 모드',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '조이스틱으로 직접 카메라를 조작하세요',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 16),

                // AI 자동 트래킹 모드 버튼
                GestureDetector(
                  onTap: _isLoading ? null : _pickVideoForAiMode,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFFF3B3B).withValues(alpha: 0.5),
                        width: 1.5,
                      ),
                    ),
                    child: const Column(
                      children: [
                        Icon(
                          Icons.smart_toy_outlined,
                          size: 32,
                          color: Color(0xFFFF3B3B),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'AI 자동 트래킹 모드',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFF3B3B),
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '타겟 한 번 설정 → 전체 궤적 자동 계산',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Just Sparring 제보하기 버튼 (소형)
                GestureDetector(
                  onTap: _openSubmissionForm,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orangeAccent.withValues(alpha: 0.4),
                        width: 1,
                      ),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.campaign,
                          size: 18,
                          color: Colors.orangeAccent,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Just Sparring 제보하기',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.orangeAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // 안내 텍스트
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 20,
                            color: Color(0xFFFF3B3B),
                          ),
                          SizedBox(width: 8),
                          Text(
                            '사용 방법',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      Text(
                        '1. 갤러리에서 스파링 영상을 선택하세요\n'
                        '2. 조이스틱과 줌으로 원하는 구도를 잡으세요\n'
                        '3. 고화질 편집 영상이 자동 생성됩니다',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white60,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
