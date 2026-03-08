import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/constants/enums.dart';
import '../../../core/models/trajectory_point.dart';
import '../shared/result_screen.dart';
import 'manual_recorder_service.dart';
import 'manual_renderer_service.dart';

class ManualDirectorScreen extends StatefulWidget {
  final String videoPath;

  /// AI 트래킹 모드에서 전달되는 사전 계산된 궤적 (없으면 순수 수동 모드)
  final List<TrajectoryPoint>? aiTrajectory;

  /// 최초 출력 비율 (AI 모드에서 선택한 비율 유지용)
  final TargetAspectRatio? initialAspectRatio;

  const ManualDirectorScreen({
    super.key,
    required this.videoPath,
    this.aiTrajectory,
    this.initialAspectRatio,
  });

  @override
  State<ManualDirectorScreen> createState() => _ManualDirectorScreenState();
}

class _ManualDirectorScreenState extends State<ManualDirectorScreen> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isRendering = false;
  bool _isTranscoding = false;
  String _renderStatus = '';
  bool _isEditMode = false;

  late final ManualRecorderService _recorderService;
  late final ManualRendererService _rendererService;
  TargetAspectRatio _selectedRatio = TargetAspectRatio.vertical_9_16;
  bool get _isHybridMode => widget.aiTrajectory != null;

  Timer? _inputLoopTimer;
  double _joyDeltaX = 0.0;
  double _joyDeltaY = 0.0;
  double _joyVisX = 0.5;
  double _joyVisY = 0.5;
  double _zDelta = 0.0;
  Offset _joyCurrent = Offset.zero; // 상대 조이스틱 누적 오프셋

  @override
  void initState() {
    super.initState();
    _recorderService = ManualRecorderService();
    _rendererService = ManualRendererService();
    if (widget.initialAspectRatio != null) {
      _selectedRatio = widget.initialAspectRatio!;
    }
    _initializeVideo();
    _startInputLoop();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    try {
      await _controller!.initialize();
      await _controller!.seekTo(Duration.zero); // 첫 프레임 디코딩 강제 → 검은 화면 방지
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
      await _controller!.seekTo(Duration.zero);
    }
    if (mounted) {
      _recorderService.initialize(
        totalDurationMs: _controller!.value.duration.inMilliseconds,
        videoAspectRatio: _controller!.value.aspectRatio,
        ratio: _selectedRatio,
      );
      _recorderService.setDisplayScale(1.20); // ClipRect+scale 1.20 보정 → 화면 왼쪽 이탈 방지
      if (_isHybridMode) {
        _recorderService.importAiTrajectory(widget.aiTrajectory!);
      }
      setState(() => _isInitialized = true);
      _controller!.addListener(_onFrameChange);
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

  // 하드웨어 디코더가 Surface 연결 후 지연 실패하는 경우 감지 (ExoPlayer 비동기 에러)
  void _checkVideoError() {
    if (_controller?.value.hasError == true && !_isTranscoding) {
      _controller!.removeListener(_checkVideoError);
      _controller!.removeListener(_onFrameChange);
      _switchToFallbackVideo();
    }
  }

  Future<void> _switchToFallbackVideo() async {
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
    await _controller!.seekTo(Duration.zero);
    if (mounted) {
      setState(() => _isInitialized = true);
      _controller!.addListener(_onFrameChange);
    }
  }

  // 조이스틱 입력 상수
  static const double _kDeadzone   = 0.15;  // 이 범위 안의 입력은 무시 (드리프트 방지)
  static const double _kScaleComp  = 1.0 / 1.20;  // 1.20 확대 보정
  static const double _kSpeedCoeff = 0.07;         // 지수 가속 계수

  void _startInputLoop() {
    _inputLoopTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!_isEditMode || !_isInitialized) return;
      bool changed = false;

      if (_joyDeltaX != 0 || _joyDeltaY != 0) {
        // [데드존] ±_kDeadzone 이하 미세 입력 무시 → Y축 누적 드리프트 원천 차단
        final double dX = _joyDeltaX.abs() > _kDeadzone ? _joyDeltaX : 0.0;
        final double dY = _joyDeltaY.abs() > _kDeadzone ? _joyDeltaY : 0.0;

        if (dX != 0 || dY != 0) {
          // [지수형 가속] 데드존 외부에서 중앙 거리 제곱 비례 가속
          // [스케일 보정] updatePosition의 rotation 180° 반전은 서비스 내부에서 처리
          final double speedX = (dX * dX.abs()) * _kSpeedCoeff * _kScaleComp;
          final double speedY = (dY * dY.abs()) * _kSpeedCoeff * _kScaleComp;
          _recorderService.updatePosition(speedX, speedY);
          changed = true;
        }
      }

      if (_zDelta != 0) {
        _recorderService.updateZoom(_zDelta);
        changed = true;
      }
      if (changed && mounted) setState(() {});
    });
  }

  void _onFrameChange() {
    if (!mounted || _controller == null) return;
    final ms = _controller!.value.position.inMilliseconds;
    if (_isEditMode && _controller!.value.isPlaying) {
      _recorderService.recordFrame(ms);
    } else if (!_isEditMode) {
      if (_recorderService.restoreFromFrame(ms)) setState(() {});
    }
  }

  @override
  void dispose() {
    _inputLoopTimer?.cancel();
    _controller?.removeListener(_checkVideoError);
    _controller?.dispose();
    super.dispose();
  }

  // 상대 조이스틱: 터치 시작점 기준 delta 누적 → 130px 원 반경(65px) 내 클램프
  static const double _kJoyRadius = 65.0;

  void _onJoystickStart(DragStartDetails details) {
    if (!_isEditMode) return;
    setState(() {
      _joyCurrent = Offset.zero;
      _joyDeltaX = 0; _joyDeltaY = 0;
      _joyVisX = 0.5; _joyVisY = 0.5;
    });
    // AI 모드: 현재 AI 궤적 좌표를 기준점으로 동기화 → 첫 터치 시 좌표 튐 방지
    if (_isHybridMode) {
      final ms = _controller?.value.position.inMilliseconds ?? 0;
      _recorderService.syncToAiPosition(ms);
    }
  }

  void _onJoystickUpdate(DragUpdateDetails details) {
    if (!_isEditMode) return;
    Offset raw = _joyCurrent + details.delta;
    if (raw.distance > _kJoyRadius) raw = raw * (_kJoyRadius / raw.distance);
    setState(() {
      _joyCurrent = raw;
      _joyDeltaX = raw.dx / _kJoyRadius;  // -1.0 ~ 1.0
      _joyDeltaY = raw.dy / _kJoyRadius;  // -1.0 ~ 1.0
      _joyVisX = (0.5 + raw.dx / 130).clamp(0.1, 0.9);
      _joyVisY = (0.5 + raw.dy / 130).clamp(0.1, 0.9);
    });
  }

  void _onJoystickEnd() {
    setState(() {
      _joyCurrent = Offset.zero;
      _joyDeltaX = 0; _joyDeltaY = 0; _joyVisX = 0.5; _joyVisY = 0.5;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _isTranscoding ? _buildTranscoding() : (_isRendering ? _buildLoading() : _buildMain())),
    );
  }

  Widget _buildMain() {
    return Column(children: [
      _buildHeader(),
      Expanded(child: _buildPreview()),
      _buildTimeline(),
      _buildControls(),
      _buildRatioSelect(),
      _buildConsole(),
      _buildRenderBtn(),
    ]);
  }

  Widget _buildHeader() {
    return Padding(padding: const EdgeInsets.all(12), child: Row(children: [
      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Colors.white)),
      if (_isHybridMode)
        Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFFF3B3B).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFFF3B3B), width: 1),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.smart_toy, color: Color(0xFFFF3B3B), size: 12),
            SizedBox(width: 4),
            Text('AI', style: TextStyle(color: Color(0xFFFF3B3B), fontSize: 11, fontWeight: FontWeight.bold)),
          ]),
        ),
      Expanded(
        child: Text(
          _isHybridMode ? 'AI + 수동 보정 모드' : 'MANUAL CONSOLE V5',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      Text("${_recorderService.currentZoom.toStringAsFixed(1)}x", style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
    ]));
  }

  Widget _buildPreview() {
    return Center(
      child: AspectRatio(
        aspectRatio: _isInitialized ? _controller!.value.aspectRatio : 16/9,
        child: Stack(fit: StackFit.expand, children: [
          if (_isInitialized)
            ClipRect(
              child: Transform.scale(
                scale: 1.20,
                alignment: Alignment.centerRight, // 왼쪽 초록색(stride padding) 크롭
                child: VideoPlayer(_controller!),
              ),
            ),
          Positioned.fill(child: CustomPaint(painter: _GuidePainter(centerX: _recorderService.currentX, centerY: _recorderService.currentY, boxSize: _recorderService.getBoxSize(), isEditMode: _isEditMode, previewScale: 1.20))),
        ]),
      ),
    );
  }

  Widget _buildTimeline() {
    if (!_isInitialized) return const SizedBox();
    return Slider(
      value: _controller!.value.position.inMilliseconds.toDouble().clamp(0, _controller!.value.duration.inMilliseconds.toDouble()),
      max: _controller!.value.duration.inMilliseconds.toDouble(),
      onChanged: (v) => _controller!.seekTo(Duration(milliseconds: v.toInt())),
      activeColor: Colors.red,
    );
  }

  Widget _buildControls() {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      IconButton(icon: Icon(_controller?.value.isPlaying == true ? Icons.pause_circle : Icons.play_circle, color: Colors.white, size: 36), onPressed: () => setState(() => _controller!.value.isPlaying ? _controller!.pause() : _controller!.play())),
      const SizedBox(width: 16),
      ElevatedButton(onPressed: () => setState(() => _isEditMode = !_isEditMode), style: ElevatedButton.styleFrom(backgroundColor: _isEditMode ? Colors.red : Colors.white10), child: Text(_isEditMode ? "RECORDING" : "EDIT UNLOCK")),
    ]);
  }

  Widget _buildRatioSelect() {
    return Wrap(spacing: 8, children: TargetAspectRatio.values.map((r) => ChoiceChip(
      label: Text(r.toString().split('.').last.replaceAll('_', ':'), style: const TextStyle(fontSize: 10)),
      selected: _selectedRatio == r, onSelected: (v) { setState(() => _selectedRatio = r); _recorderService.setAspectRatio(r); },
    )).toList());
  }

  Widget _buildConsole() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(30), border: Border.all(color: _isEditMode ? Colors.red.withValues(alpha: 0.3) : Colors.white10)),
      child: Row(children: [
        Expanded(flex: 3, child: GestureDetector(
            onPanStart: _onJoystickStart,
            onPanUpdate: _onJoystickUpdate,
            onPanEnd: (_) => _onJoystickEnd(),
            onPanCancel: () => _onJoystickEnd(),
            child: Center(child: Container(
              width: 130, height: 130, 
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: Colors.black, border: Border.all(color: Colors.white10, width: 2),
                boxShadow: [BoxShadow(color: Colors.red.withValues(alpha: 0.05), blurRadius: 20, spreadRadius: 5)]
              ), 
              child: Stack(alignment: Alignment.center, children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 50), 
                  left: _joyVisX * 130 - 25, top: _joyVisY * 130 - 25, 
                  child: Container(width: 50, height: 50, decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: _isEditMode ? [Colors.redAccent, Colors.red[900]!] : [Colors.grey[700]!, Colors.grey[900]!])))
                )
              ]))),
        )),
        Expanded(flex: 2, child: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
          _buildZoomBtn("ZOOM IN", Icons.add, 0.03, Colors.redAccent),
          const SizedBox(height: 12),
          _buildZoomBtn("ZOOM OUT", Icons.remove, -0.03, Colors.blueGrey),
        ])),
      ]),
    );
  }

  Widget _buildZoomBtn(String label, IconData icon, double delta, Color color) {
    return Listener(
      onPointerDown: (_) { if (_isEditMode) { HapticFeedback.lightImpact(); _zDelta = delta; } },
      onPointerUp: (_) => _zDelta = 0,
      child: Column(children: [
        Container(width: 50, height: 50, decoration: BoxDecoration(shape: BoxShape.circle, color: _isEditMode ? color : Colors.white10), child: Icon(icon, color: Colors.white)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 9)),
      ]),
    );
  }

  Widget _buildRenderBtn() {
    return Padding(padding: const EdgeInsets.all(12), child: ElevatedButton(onPressed: _recorderService.hasData ? _renderVideo : null, style: ElevatedButton.styleFrom(backgroundColor: Colors.red, minimumSize: const Size(double.infinity, 45)), child: const Text('GENERATE VIDEO')));
  }

  Widget _buildTranscoding() => const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    CircularProgressIndicator(color: Colors.red),
    SizedBox(height: 20),
    Text('영상 변환 중...', style: TextStyle(color: Colors.white, fontSize: 16)),
    SizedBox(height: 8),
    Text('4K HDR 영상을 미리보기용으로 변환합니다', style: TextStyle(color: Colors.white54, fontSize: 12)),
  ]));

  Widget _buildLoading() => Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const CircularProgressIndicator(color: Colors.red), const SizedBox(height: 20), Text(_renderStatus, style: const TextStyle(color: Colors.white))]));

  Future<void> _renderVideo() async {
    setState(() { _isRendering = true; _renderStatus = '최종 렌더링 중...'; });
    try {
      final out = await _rendererService.render(
        videoPath: widget.videoPath,
        recorderService: _recorderService,
        aspectRatio: _selectedRatio,
        quality: VideoQuality.hd,
        videoAspectRatio: _controller!.value.aspectRatio,
        totalDurationMs: _controller!.value.duration.inMilliseconds,
      );
      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (c) => ResultScreen(videoPath: out, strikeCount: 0, canGoBack: false),
        ));
      }
    } catch (e) { if (mounted) setState(() => _isRendering = false); }
  }
}

class _GuidePainter extends CustomPainter {
  final double centerX, centerY;
  final Size boxSize;
  final bool isEditMode;
  /// Transform.scale 값 (Alignment.centerRight 기준 좌표 변환에 사용)
  final double previewScale;

  _GuidePainter({
    required this.centerX,
    required this.centerY,
    required this.boxSize,
    required this.isEditMode,
    this.previewScale = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // [rotation 180° + scale + Alignment.centerRight] raw 좌표 → 화면 좌표 변환
    //
    // 영상 rotation 180°로 인해 raw 좌표계와 display 좌표계가 반전됨:
    //   displayed_x = 1 - raw_x,  displayed_y = 1 - raw_y
    //
    // 이후 Transform.scale(previewScale, Alignment.centerRight) 적용:
    //   screen_x = displayed_x * scale - (scale - 1)
    //            = (1 - raw_x) * scale - (scale - 1)
    //            = 1.0 - raw_x * scale
    //
    //   screen_y = 0.5 + (displayed_y - 0.5) * scale
    //            = 0.5 + (0.5 - raw_y) * scale
    final double sCX = (1.0 - centerX * previewScale).clamp(0.0, 1.0);
    final double sCY = (0.5 + (0.5 - centerY) * previewScale).clamp(0.0, 1.0);

    final double bw = boxSize.width * previewScale * size.width;
    final double bh = boxSize.height * previewScale * size.height;
    final Rect rect = Rect.fromLTWH(sCX * size.width - bw / 2, sCY * size.height - bh / 2, bw, bh);

    canvas.drawPath(
      Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRect(rect)
        ..fillType = PathFillType.evenOdd,
      Paint()..color = Colors.black54,
    );

    // 격자 및 정밀 조준점
    final p = Paint()..color = isEditMode ? Colors.red : Colors.white..style = PaintingStyle.stroke..strokeWidth = 2;
    canvas.drawRect(rect, p);
    final gp = Paint()..color = Colors.white.withValues(alpha: 0.1)..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(rect.left + bw / 3, rect.top), Offset(rect.left + bw / 3, rect.bottom), gp);
    canvas.drawLine(Offset(rect.left + 2 * bw / 3, rect.top), Offset(rect.left + 2 * bw / 3, rect.bottom), gp);
    canvas.drawLine(Offset(rect.left, rect.top + bh / 3), Offset(rect.right, rect.top + bh / 3), gp);
    canvas.drawLine(Offset(rect.left, rect.top + 2 * bh / 3), Offset(rect.right, rect.top + 2 * bh / 3), gp);

    final centerPoint = Offset(sCX * size.width, sCY * size.height);
    canvas.drawCircle(centerPoint, 3, Paint()..color = isEditMode ? Colors.red : Colors.white);
    final hp = Paint()..color = (isEditMode ? Colors.red : Colors.white).withValues(alpha: 0.5)..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(centerPoint.dx - 12, centerPoint.dy), Offset(centerPoint.dx + 12, centerPoint.dy), hp);
    canvas.drawLine(Offset(centerPoint.dx, centerPoint.dy - 12), Offset(centerPoint.dx, centerPoint.dy + 12), hp);
  }

  @override
  bool shouldRepaint(covariant _GuidePainter oldDelegate) => true;
}