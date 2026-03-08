import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/constants/enums.dart';
import '../../../core/models/detected_person.dart';
import '../../../core/models/trajectory_point.dart';
import '../../../core/utils/coordinate_utils.dart';
import '../manual_director/manual_director_screen.dart';
import 'ai_tracking_service.dart';

/// AI 자동 트래킹 모드 - 타겟 선택 화면
/// 사용자가 한 번 박스를 설정하면 전/후방 전체 궤적을 자동 계산
class AiTargetSelectionScreen extends StatefulWidget {
  final String videoPath;
  const AiTargetSelectionScreen({super.key, required this.videoPath});

  @override
  State<AiTargetSelectionScreen> createState() =>
      _AiTargetSelectionScreenState();
}

class _AiTargetSelectionScreenState extends State<AiTargetSelectionScreen> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;

  // 타겟 박스 (정규화 0~1)
  BoundingBox? _targetBox;
  final GlobalKey _videoKey = GlobalKey();

  // 분석 상태
  bool _isTranscoding = false;
  bool _isAnalyzing = false;
  double _analyzeProgress = 0;
  String _analyzeStatus = '';
  final AiTrackingService _trackingService = AiTrackingService();

  // 검증 모드
  bool _isVerifying = false;
  List<AnchorDetection> _verifyDetections = [];
  List<TrajectoryPoint> _pendingTrajectory = [];
  int _anchorMsForVerification = 0;

  TargetAspectRatio _selectedRatio = TargetAspectRatio.vertical_9_16;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    try {
      await _controller!.initialize();
    } catch (e) {
      // 하드웨어 디코더 실패 (4K HDR 등) → 720p H.264 트랜스코딩 후 재시도
      await _controller?.dispose();
      _controller = null;
      if (!mounted) return;
      setState(() => _isTranscoding = true);
      final preview = await _createPreviewVideo();
      if (!mounted) return;
      setState(() => _isTranscoding = false);
      if (preview == null) return;
      _controller = VideoPlayerController.file(File(preview));
      await _controller!.initialize();
    }
    if (mounted) {
      setState(() => _isInitialized = true);
      _controller!.addListener(_checkVideoError); // 지연 디코더 오류 감지
    }
  }

  Future<String?> _createPreviewVideo() async {
    try {
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/preview_${DateTime.now().millisecondsSinceEpoch}.mp4';
      // format=yuv420p: 10-bit HDR(yuv420p10le) → 8-bit 강제 변환 (libx264 호환)
      final cmd = '-i "${widget.videoPath}" -c:v libx264 -preset ultrafast -crf 23 '
          '-vf "scale=-2:720,format=yuv420p" -c:a aac -y "$out"';
      final session = await FFmpegKit.execute(cmd);
      if (ReturnCode.isSuccess(await session.getReturnCode())) return out;
    } catch (_) {}
    return null;
  }

  void _checkVideoError() {
    if (_controller?.value.hasError == true && !_isTranscoding) {
      _controller!.removeListener(_checkVideoError);
      _switchToFallbackPreview();
    }
  }

  Future<void> _switchToFallbackPreview() async {
    if (!mounted) return;
    setState(() { _isInitialized = false; _isTranscoding = true; });
    await _controller?.dispose();
    _controller = null;
    final preview = await _createPreviewVideo();
    if (!mounted) return;
    setState(() => _isTranscoding = false);
    if (preview == null) return;
    _controller = VideoPlayerController.file(File(preview));
    await _controller!.initialize();
    if (mounted) setState(() => _isInitialized = true);
  }

  @override
  void dispose() {
    _trackingService.cancel();
    _controller?.removeListener(_checkVideoError);
    _controller?.dispose();
    super.dispose();
  }

  // ── 탭으로 타겟 박스 설정 ──────────────────────────────────────────────
  void _onTapVideo(TapUpDetails details) {
    final box = _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final local = box.globalToLocal(details.globalPosition);

    final nx = (local.dx / size.width).clamp(0.0, 1.0);
    final ny = (local.dy / size.height).clamp(0.0, 1.0);
    const half = 0.08;

    setState(() {
      _targetBox = BoundingBox(
        left: (nx - half).clamp(0.0, 1.0 - half * 2),
        top: (ny - half).clamp(0.0, 1.0 - half * 2),
        width: half * 2,
        height: half * 2,
      );
    });
  }

  // ── 코너 드래그로 박스 크기 조절 ─────────────────────────────────────
  void _onCornerDrag(String corner, DragUpdateDetails d, Size size) {
    if (_targetBox == null) return;
    final dx = d.delta.dx / size.width;
    final dy = d.delta.dy / size.height;
    double l = _targetBox!.left;
    double t = _targetBox!.top;
    double w = _targetBox!.width;
    double h = _targetBox!.height;

    switch (corner) {
      case 'tl': l += dx; t += dy; w -= dx; h -= dy;
      case 'tr': t += dy; w += dx; h -= dy;
      case 'bl': l += dx; w -= dx; h += dy;
      case 'br': w += dx; h += dy;
    }

    setState(() {
      _targetBox = BoundingBox(
        left: l.clamp(0.0, 1.0),
        top: t.clamp(0.0, 1.0),
        width: w.clamp(0.04, 1.0),
        height: h.clamp(0.04, 1.0),
      );
    });
  }

  // ── 분석 시작 ─────────────────────────────────────────────────────────
  Future<void> _startAnalysis() async {
    if (_targetBox == null || !_isInitialized) return;
    await _controller!.pause();

    final anchorMs = _controller!.value.position.inMilliseconds;
    final totalMs = _controller!.value.duration.inMilliseconds;
    final videoAspect = _controller!.value.aspectRatio;

    setState(() { _isAnalyzing = true; _analyzeProgress = 0; });

    try {
      final trajectory = await _trackingService.analyzeTrajectory(
        videoPath: widget.videoPath,
        userBox: Rect.fromLTWH(
          _targetBox!.left, _targetBox!.top,
          _targetBox!.width, _targetBox!.height,
        ),
        anchorMs: anchorMs,
        totalDurationMs: totalMs,
        videoAspectRatio: videoAspect,
        displayScale: 1.20,
        onProgress: (p, s) {
          if (mounted) setState(() { _analyzeProgress = p; _analyzeStatus = s; });
        },
      );

      if (mounted) {
        // 분석 완료 → 검증 모드 진입 (즉시 이동 대신 결과 확인 단계)
        await _controller!.seekTo(Duration(milliseconds: anchorMs));
        setState(() {
          _isAnalyzing = false;
          _isVerifying = true;
          _pendingTrajectory = trajectory;
          _verifyDetections = _trackingService.lastAnchorDetections;
          _anchorMsForVerification = anchorMs;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAnalyzing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('분석 실패: $e'),
            backgroundColor: const Color(0xFFFF3B3B),
          ),
        );
      }
    }
  }

  // ── 검증 승인 → ManualDirectorScreen 이동 ─────────────────────────────
  void _approveAndNavigate() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ManualDirectorScreen(
          videoPath: widget.videoPath,
          initialAspectRatio: _selectedRatio,
          aiTrajectory: _pendingTrajectory,
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _isTranscoding
            ? _buildTranscoding()
            : _isAnalyzing
                ? _buildAnalyzingOverlay()
                : _isVerifying
                    ? _buildVerificationMode()
                    : _buildMain(),
      ),
    );
  }

  Widget _buildMain() {
    return Column(
      children: [
        _buildHeader(),
        _buildVideoArea(),
        _buildInstruction(),
        _buildRatioChips(),
        _buildBottomBar(),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back, color: Colors.white),
          ),
          const Expanded(
            child: Text(
              'AI 자동 트래킹',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18),
            ),
          ),
          if (_targetBox != null)
            const Icon(Icons.check_circle, color: Color(0xFFFF3B3B), size: 20),
        ],
      ),
    );
  }

  Widget _buildVideoArea() {
    if (!_isInitialized) {
      return const Expanded(
        child: Center(child: CircularProgressIndicator(color: Color(0xFFFF3B3B))),
      );
    }
    return Expanded(
      child: Center(
        child: AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: GestureDetector(
            onTapUp: _onTapVideo,
            child: Stack(
              key: _videoKey,
              fit: StackFit.expand,
              children: [
                ClipRect(
                  child: Transform.scale(
                    scale: 1.20,
                    alignment: Alignment.centerRight,
                    child: VideoPlayer(_controller!),
                  ),
                ),
                if (_targetBox != null) _buildBoxOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBoxOverlay() {
    return LayoutBuilder(builder: (ctx, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      final l = _targetBox!.left * w;
      final t = _targetBox!.top * h;
      final bw = _targetBox!.width * w;
      final bh = _targetBox!.height * h;

      return Stack(children: [
        Positioned(
          left: l, top: t, width: bw, height: bh,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFFF3B3B), width: 2),
              color: const Color(0xFFFF3B3B).withValues(alpha: 0.08),
            ),
          ),
        ),
        for (final corner in ['tl', 'tr', 'bl', 'br'])
          _buildHandle(corner, l, t, bw, bh, Size(w, h)),
      ]);
    });
  }

  Widget _buildHandle(
      String corner, double l, double t, double bw, double bh, Size size) {
    final double hx = (corner == 'tl' || corner == 'bl') ? l : l + bw;
    final double hy = (corner == 'tl' || corner == 'tr') ? t : t + bh;
    return Positioned(
      left: hx - 18, top: hy - 18,
      child: GestureDetector(
        onPanUpdate: (d) => _onCornerDrag(corner, d, size),
        child: Container(
          width: 36, height: 36, color: Colors.transparent,
          child: Center(
            child: Container(
              width: 14, height: 14,
              decoration: BoxDecoration(
                color: const Color(0xFFFF3B3B),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInstruction() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        const Icon(Icons.touch_app, color: Colors.white38, size: 16),
        const SizedBox(width: 6),
        Text(
          _targetBox == null
              ? '영상을 탭해서 타겟 박스를 설정하세요'
              : '코너를 드래그해 크기를 조정하세요',
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ]),
    );
  }

  Widget _buildRatioChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          const Text('출력 비율:', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ...TargetAspectRatio.values.map((r) {
            final parts = r.toString().split('.').last.split('_');
            final label = '${parts[parts.length - 2]}:${parts.last}';
            return ChoiceChip(
              label: Text(label, style: const TextStyle(fontSize: 11)),
              selected: _selectedRatio == r,
              onSelected: (_) => setState(() => _selectedRatio = r),
              selectedColor: const Color(0xFFFF3B3B),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        // 타임라인
        if (_isInitialized)
          Slider(
            value: _controller!.value.position.inMilliseconds
                .toDouble()
                .clamp(0, _controller!.value.duration.inMilliseconds.toDouble()),
            max: _controller!.value.duration.inMilliseconds.toDouble(),
            onChanged: (v) =>
                _controller!.seekTo(Duration(milliseconds: v.toInt())),
            activeColor: const Color(0xFFFF3B3B),
          ),
        const SizedBox(height: 8),
        // 재생 + 분석 버튼
        Row(children: [
          IconButton(
            onPressed: () => setState(() => _controller!.value.isPlaying
                ? _controller!.pause()
                : _controller!.play()),
            icon: Icon(
              _controller?.value.isPlaying == true
                  ? Icons.pause_circle
                  : Icons.play_circle,
              color: Colors.white,
              size: 36,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _targetBox != null ? _startAnalysis : null,
              icon: const Icon(Icons.smart_toy),
              label: const Text('AI 분석 시작'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF3B3B),
                disabledBackgroundColor: Colors.white10,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 검증 모드 UI
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildVerificationMode() {
    return Column(
      children: [
        _buildVerificationHeader(),
        _buildVerificationVideoArea(),
        _buildVerificationLegend(),
        _buildVerificationButtons(),
      ],
    );
  }

  Widget _buildVerificationHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => setState(() {
              _isVerifying = false;
              _pendingTrajectory = [];
              _verifyDetections = [];
            }),
            icon: const Icon(Icons.arrow_back, color: Colors.white),
          ),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI 감지 결과 검증',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                Text('샌드백/타인 오인식 여부를 확인하세요',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          Text('${_verifyDetections.length}개 감지',
              style: const TextStyle(color: Color(0xFFFF3B3B), fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildVerificationVideoArea() {
    if (!_isInitialized) {
      return const Expanded(
        child: Center(child: CircularProgressIndicator(color: Color(0xFFFF3B3B))),
      );
    }
    // 앵커 위치에서 타겟에 해당하는 감지 인덱스 계산
    final targetIdx = _findVerifyTargetIdx();

    return Expanded(
      child: Center(
        child: AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRect(
                child: Transform.scale(
                  scale: 1.20,
                  alignment: Alignment.centerRight,
                  child: VideoPlayer(_controller!),
                ),
              ),
              // AI 감지 박스 레이어
              LayoutBuilder(builder: (ctx, constraints) {
                return CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _DetectionBoxPainter(
                    detections: _verifyDetections,
                    targetIdx: targetIdx,
                    displayScale: 1.20,
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// 앵커 박스 중심에 가장 가까운 감지 객체의 인덱스 반환
  int? _findVerifyTargetIdx() {
    if (_verifyDetections.isEmpty || _targetBox == null) return null;
    // screen 좌표 → raw → display 픽셀 (normBox와 같은 좌표계)
    final rawCenter = screenToRaw(
      Offset(_targetBox!.centerX, _targetBox!.centerY),
      1.20,
    );
    final displayNorm = Offset(1 - rawCenter.dx, 1 - rawCenter.dy);

    int bestIdx = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < _verifyDetections.length; i++) {
      final c = _verifyDetections[i].normBox.center;
      final d = (c - displayNorm).distance;
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  Widget _buildVerificationLegend() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(children: [
        _legendItem(const Color(0xFFFF3B3B), '타겟'),
        const SizedBox(width: 16),
        _legendItem(Colors.green, '기타 감지'),
        const Spacer(),
        Text(
          '앵커: ${(_anchorMsForVerification / 1000).toStringAsFixed(1)}s',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ]),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(children: [
      Container(
        width: 14, height: 14,
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    ]);
  }

  Widget _buildVerificationButtons() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => setState(() {
              _isVerifying = false;
              _pendingTrajectory = [];
              _verifyDetections = [];
            }),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('재설정'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white54,
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: _approveAndNavigate,
            icon: const Icon(Icons.check),
            label: const Text('승인 후 편집 시작'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF3B3B),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildTranscoding() => const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    CircularProgressIndicator(color: Color(0xFFFF3B3B)),
    SizedBox(height: 20),
    Text('영상 변환 중...', style: TextStyle(color: Colors.white, fontSize: 16)),
    SizedBox(height: 8),
    Text('4K HDR 영상을 미리보기용으로 변환합니다', style: TextStyle(color: Colors.white54, fontSize: 12)),
  ]));

  Widget _buildAnalyzingOverlay() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.smart_toy, color: Color(0xFFFF3B3B), size: 56),
          const SizedBox(height: 24),
          const Text(
            'AI 분석 중...',
            style: TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),
          LinearProgressIndicator(
            value: _analyzeProgress,
            backgroundColor: Colors.white12,
            color: const Color(0xFFFF3B3B),
            minHeight: 6,
          ),
          const SizedBox(height: 16),
          Text(
            _analyzeStatus,
            style: const TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            '${(_analyzeProgress * 100).toStringAsFixed(0)}%',
            style: const TextStyle(
                color: Color(0xFFFF3B3B),
                fontSize: 28,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),
          TextButton(
            onPressed: () {
              _trackingService.cancel();
              setState(() => _isAnalyzing = false);
            },
            child: const Text('취소', style: TextStyle(color: Colors.white38)),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AI 감지 박스 페인터
// ─────────────────────────────────────────────────────────────────────────────

/// 앵커 프레임에서 ML Kit이 감지한 모든 객체를 그림.
///
/// 좌표 변환:
///   display 정규화(0~1) → raw(1-display) → rawToScreen → 위젯 픽셀
///   결과: screen_x = -0.20 + disp_x * displayScale
///          screen_y = 0.50 + (disp_y - 0.50) * displayScale
class _DetectionBoxPainter extends CustomPainter {
  final List<AnchorDetection> detections;
  final int? targetIdx;       // 타겟 객체 인덱스 (빨간색)
  final double displayScale;  // Transform.scale 값 (1.20)

  _DetectionBoxPainter({
    required this.detections,
    required this.targetIdx,
    required this.displayScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < detections.length; i++) {
      final d = detections[i];
      final isTarget = i == targetIdx;

      // display 정규화 → screen 정규화
      // screen_x = 1 - (1-disp_x)*scale = -0.20 + disp_x*scale (with scale=1.20)
      // screen_y = 0.5 + (disp_y - 0.5)*scale
      final sl = (-0.20 + d.normBox.left * displayScale) * size.width;
      final st = (0.5 + (d.normBox.top - 0.5) * displayScale) * size.height;
      final sw = d.normBox.width * displayScale * size.width;
      final sh = d.normBox.height * displayScale * size.height;

      final rect = Rect.fromLTWH(sl, st, sw, sh);

      // 박스 테두리
      final borderPaint = Paint()
        ..color = isTarget ? const Color(0xFFFF3B3B) : Colors.green
        ..strokeWidth = isTarget ? 2.5 : 1.5
        ..style = PaintingStyle.stroke;
      canvas.drawRect(rect, borderPaint);

      // 박스 배경 (반투명)
      final fillPaint = Paint()
        ..color = (isTarget ? const Color(0xFFFF3B3B) : Colors.green)
            .withValues(alpha: 0.08)
        ..style = PaintingStyle.fill;
      canvas.drawRect(rect, fillPaint);

      // 레이블 (타겟: "타겟", 기타: 신뢰도 %)
      final label = isTarget
          ? '타겟'
          : '${(d.confidence * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: isTarget ? const Color(0xFFFF3B3B) : Colors.green,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black54,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      // 레이블 위치: 박스 상단 왼쪽 (화면 안에 들어오도록 클램프)
      final labelX = sl.clamp(0.0, size.width - tp.width);
      final labelY = (st - tp.height - 2).clamp(0.0, size.height - tp.height);
      tp.paint(canvas, Offset(labelX, labelY));
    }
  }

  @override
  bool shouldRepaint(_DetectionBoxPainter old) =>
      old.detections != detections || old.targetIdx != targetIdx;
}
