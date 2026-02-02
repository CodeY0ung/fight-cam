import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../../../core/constants/enums.dart';
import '../shared/result_screen.dart';
import 'manual_recorder_service.dart';
import 'manual_renderer_service.dart';

class ManualDirectorScreen extends StatefulWidget {
  final String videoPath;
  const ManualDirectorScreen({super.key, required this.videoPath});

  @override
  State<ManualDirectorScreen> createState() => _ManualDirectorScreenState();
}

class _ManualDirectorScreenState extends State<ManualDirectorScreen> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isRendering = false;
  String _renderStatus = '';
  bool _isEditMode = false;

  late final ManualRecorderService _recorderService;
  late final ManualRendererService _rendererService;
  TargetAspectRatio _selectedRatio = TargetAspectRatio.vertical_9_16;

  Timer? _inputLoopTimer;
  double _joyDeltaX = 0.0;
  double _joyDeltaY = 0.0;
  double _joyVisX = 0.5;
  double _joyVisY = 0.5;
  double _zDelta = 0.0;

  @override
  void initState() {
    super.initState();
    _recorderService = ManualRecorderService();
    _rendererService = ManualRendererService();
    _initializeVideo();
    _startInputLoop();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller!.initialize();
    if (mounted) {
      _recorderService.initialize(
        totalDurationMs: _controller!.value.duration.inMilliseconds,
        videoAspectRatio: _controller!.value.aspectRatio,
        ratio: _selectedRatio,
      );
      setState(() => _isInitialized = true);
      _controller!.addListener(_onFrameChange);
    }
  }

  // [핵심 수정] 조이스틱 가속도 및 이동 속도 개선 루프
  void _startInputLoop() {
    _inputLoopTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!_isEditMode || !_isInitialized) return;
      bool changed = false;

      if (_joyDeltaX != 0 || _joyDeltaY != 0) {
        // [지수형 가속] 중앙에서 멀어질수록 속도가 급격히 증가 (기본 계수 0.04)
        double speedX = (_joyDeltaX * _joyDeltaX.abs()) * 0.07;
        double speedY = (_joyDeltaY * _joyDeltaY.abs()) * 0.07;

        _recorderService.updatePosition(speedX, speedY);
        changed = true;
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
    _controller?.dispose();
    super.dispose();
  }

  void _onJoystickUpdate(DragUpdateDetails details, Size size) {
    if (!_isEditMode) return;
    setState(() {
      // 조이스틱 중앙 대비 델타값 (-1.0 ~ 1.0)
      _joyDeltaX = ((details.localPosition.dx / size.width) - 0.5) * 2;
      _joyDeltaY = ((details.localPosition.dy / size.height) - 0.5) * 2;
      
      _joyVisX = (details.localPosition.dx / size.width).clamp(0.1, 0.9);
      _joyVisY = (details.localPosition.dy / size.height).clamp(0.1, 0.9);
    });
  }

  void _onJoystickEnd() {
    setState(() { _joyDeltaX = 0; _joyDeltaY = 0; _joyVisX = 0.5; _joyVisY = 0.5; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _isRendering ? _buildLoading() : _buildMain()),
    );
  }

  Widget _buildMain() {
    return Column(children: [
      _buildHeader(),
      _buildPreview(),
      _buildTimeline(),
      _buildControls(),
      _buildRatioSelect(),
      Expanded(child: _buildConsole()),
      _buildRenderBtn(),
    ]);
  }

  Widget _buildHeader() {
    return Padding(padding: const EdgeInsets.all(12), child: Row(children: [
      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Colors.white)),
      const Text('MANUAL CONSOLE V5', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      const Spacer(),
      Text("${_recorderService.currentZoom.toStringAsFixed(1)}x", style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
    ]));
  }

  Widget _buildPreview() {
    return AspectRatio(
      aspectRatio: _isInitialized ? _controller!.value.aspectRatio : 16/9,
      child: Stack(fit: StackFit.expand, children: [
        if (_isInitialized) VideoPlayer(_controller!),
        Positioned.fill(child: CustomPaint(painter: _GuidePainter(centerX: _recorderService.currentX, centerY: _recorderService.currentY, boxSize: _recorderService.getBoxSize(), isEditMode: _isEditMode))),
      ]),
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
        Expanded(flex: 3, child: LayoutBuilder(builder: (context, constraints) {
          return GestureDetector(
            onPanUpdate: (d) => _onJoystickUpdate(d, constraints.biggest),
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
          );
        })),
        Expanded(flex: 2, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
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

  Widget _buildLoading() => Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const CircularProgressIndicator(color: Colors.red), const SizedBox(height: 20), Text(_renderStatus, style: const TextStyle(color: Colors.white))]));

  Future<void> _renderVideo() async {
    setState(() { _isRendering = true; _renderStatus = '최종 렌더링 중...'; });
    try {
      final out = await _rendererService.render(videoPath: widget.videoPath, recorderService: _recorderService, aspectRatio: _selectedRatio, quality: VideoQuality.hd, videoAspectRatio: _controller!.value.aspectRatio, totalDurationMs: _controller!.value.duration.inMilliseconds);
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (c) => ResultScreen(videoPath: out, strikeCount: 0, canGoBack: false)));
    } catch (e) { if (mounted) setState(() => _isRendering = false); }
  }
}

class _GuidePainter extends CustomPainter {
  final double centerX, centerY; final Size boxSize; final bool isEditMode;
  _GuidePainter({required this.centerX, required this.centerY, required this.boxSize, required this.isEditMode});
  @override
  void paint(Canvas canvas, Size size) {
    final double bw = boxSize.width * size.width; final double bh = boxSize.height * size.height;
    final Rect rect = Rect.fromLTWH((centerX * size.width) - bw/2, (centerY * size.height) - bh/2, bw, bh);
    canvas.drawPath(Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height))..addRect(rect)..fillType = PathFillType.evenOdd, Paint()..color = Colors.black54);
    
    // 격자 및 정밀 조준점 추가
    final p = Paint()..color = isEditMode ? Colors.red : Colors.white..style = PaintingStyle.stroke..strokeWidth = 2;
    canvas.drawRect(rect, p);
    final gp = Paint()..color = Colors.white.withValues(alpha: 0.1)..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(rect.left+bw/3, rect.top), Offset(rect.left+bw/3, rect.bottom), gp);
    canvas.drawLine(Offset(rect.left+2*bw/3, rect.top), Offset(rect.left+2*bw/3, rect.bottom), gp);
    canvas.drawLine(Offset(rect.left, rect.top+bh/3), Offset(rect.right, rect.top+bh/3), gp);
    canvas.drawLine(Offset(rect.left, rect.top+2*bh/3), Offset(rect.right, rect.top+2*bh/3), gp);
    
    final centerPoint = Offset(centerX * size.width, centerY * size.height);
    canvas.drawCircle(centerPoint, 3, Paint()..color = isEditMode ? Colors.red : Colors.white);
    final hp = Paint()..color = (isEditMode ? Colors.red : Colors.white).withValues(alpha: 0.5)..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(centerPoint.dx-12, centerPoint.dy), Offset(centerPoint.dx+12, centerPoint.dy), hp);
    canvas.drawLine(Offset(centerPoint.dx, centerPoint.dy-12), Offset(centerPoint.dx, centerPoint.dy+12), hp);
  }
  @override bool shouldRepaint(covariant _GuidePainter oldDelegate) => true;
}