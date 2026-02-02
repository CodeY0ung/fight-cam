import 'package:flutter/material.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';
import '../../../core/models/detected_person.dart';
import '../../../core/models/tracking_segment.dart';
import '../../../core/constants/enums.dart';
import '../../../core/services/editor_service.dart';
import 'processing_screen.dart';

class SelectionScreenV5 extends StatefulWidget {
  final File videoFile;
  const SelectionScreenV5({super.key, required this.videoFile});

  @override
  State<SelectionScreenV5> createState() => _SelectionScreenV5State();
}

class _SelectionScreenV5State extends State<SelectionScreenV5> {
  late VideoPlayerController _videoController;
  bool _isVideoInitialized = false;
  bool _isPlaying = false;
  String? _errorMessage;
  Duration _currentPosition = Duration.zero;

  VideoProject? _project;
  int _currentSegmentIndex = 0;

  TargetAspectRatio _selectedRatio = TargetAspectRatio.vertical_9_16;
  final VideoQuality _selectedQuality = VideoQuality.hd; 
  bool _showPreview = false;
  
  final TransformationController _transformationController = TransformationController();
  final GlobalKey _videoKey = GlobalKey();

  final EditorService _editorService = EditorService();
  File? _previewImage;
  bool _isPreviewLoading = false;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      _videoController = VideoPlayerController.file(widget.videoFile);
      await _videoController.initialize();
      if (!mounted) return;

      _project = VideoProject.create(
        videoPath: widget.videoFile.path,
        totalDuration: _videoController.value.duration,
        fps: 30.0,
        segmentDurationSeconds: 5, 
      );

      setState(() => _isVideoInitialized = true);
      _videoController.addListener(_onVideoPositionChanged);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = '로드 실패: $e');
    }
  }

  void _onVideoPositionChanged() {
    if (!mounted || _videoController.value.isBuffering) return;
    final position = _videoController.value.position;
    
    if (_project != null) {
      // 재생 중일 때만 현재 세그먼트 인덱스를 자동으로 추적
      if (_isPlaying) {
        for (int i = 0; i < _project!.segments.length; i++) {
          final segment = _project!.segments[i];
          if (position >= segment.startTime && position < segment.endTime) {
            if (_currentSegmentIndex != i) {
              setState(() => _currentSegmentIndex = i);
            }
            break;
          }
        }
      }
    }
    setState(() {
      _currentPosition = position;
      _isPlaying = _videoController.value.isPlaying;
    });
  }

  @override
  void dispose() {
    _videoController.removeListener(_onVideoPositionChanged);
    _transformationController.dispose();
    _videoController.dispose();
    super.dispose();
  }

  // [신규] 자동 다음 세그먼트 이동 유틸리티
  void _moveToNextSegment() {
    if (_project == null) return;
    
    if (_currentSegmentIndex < _project!.segments.length - 1) {
      setState(() {
        _currentSegmentIndex++;
        final nextSegment = _project!.segments[_currentSegmentIndex];
        // 비디오 시점을 다음 세그먼트 시작으로 이동
        _videoController.seekTo(nextSegment.startTime);
        _showPreview = false;
        _previewImage = null;
      });
    } else {
      // 마지막 세그먼트 완료 시 피드백
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('모든 세그먼트 설정 완료! 렌더링을 시작하세요.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // [UX 개선] Gap 설정 후 자동 이동
  void _setCurrentSegmentAsGap() {
    if (_project == null) return;
    setState(() {
      final segment = _project!.segments[_currentSegmentIndex];
      segment.initialTarget = null;
      segment.state = SegmentState.confirmed; // Gap이자 확정 상태로 바로 전이
    });
    _moveToNextSegment();
  }

  // [UX 개선] 확정 후 자동 이동
  void _confirmCurrentSegment() {
    if (_project == null) return;
    setState(() {
      final segment = _project!.segments[_currentSegmentIndex];
      segment.state = SegmentState.confirmed;
    });
    _moveToNextSegment();
  }

  void _handleTapToSelectTarget(Offset tapPosition) {
    final RenderBox? renderBox = _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final Size widgetSize = renderBox.size;
    final Matrix4 transform = _transformationController.value;
    final Matrix4 inverse = Matrix4.inverted(transform);
    final Offset originalOffset = MatrixUtils.transformPoint(inverse, tapPosition);

    final normalizedX = (originalOffset.dx / widgetSize.width).clamp(0.0, 1.0);
    final normalizedY = (originalOffset.dy / widgetSize.height).clamp(0.0, 1.0);

    const boxSize = 0.2; 
    setState(() {
      final segment = _project!.segments[_currentSegmentIndex];
      segment.initialTarget = DetectedPerson(
        boundingBox: BoundingBox(
          left: (normalizedX - boxSize / 2).clamp(0.0, 1.0 - boxSize),
          top: (normalizedY - boxSize / 2).clamp(0.0, 1.0 - boxSize),
          width: boxSize,
          height: boxSize,
        ),
        center: Point(normalizedX, normalizedY),
        confidence: 1.0,
      );
      // 타겟을 새로 찍으면 Gap 상태였더라도 수동 지정 상태로 복구
      segment.state = SegmentState.targetSet;
    });
  }

  Future<void> _updatePreview() async {
    final segment = _project?.segments[_currentSegmentIndex];
    if (segment?.initialTarget == null) return;

    final boxHeight = segment!.initialTarget!.boundingBox.height;

    setState(() => _isPreviewLoading = true);
    try {
      final previewFile = await _editorService.generatePreviewFrame(
        videoPath: widget.videoFile.path,
        centerPoint: segment.initialTarget!.center,
        ratio: _selectedRatio,
        timestamp: segment.startTime.inMilliseconds / 1000.0,
        cropSizeRatio: boxHeight, 
      );
      if (mounted) setState(() { _previewImage = previewFile; _showPreview = true; _isPreviewLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isPreviewLoading = false);
    }
  }

  void _startProcessing() {
    if (_project == null || !_project!.isAllConfirmed) return;
    
    Navigator.push(context, MaterialPageRoute(builder: (context) => ProcessingScreen(
      videoFile: widget.videoFile,
      project: _project!, 
      aspectRatio: _selectedRatio,
      quality: _selectedQuality,
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: _isVideoInitialized && _project != null
          ? Column(
              children: [
                _buildHeader(),
                _buildSegmentTimeline(),
                _buildVideoArea(),
                _buildVideoControls(),
                _buildSegmentActions(),
                _buildBottomPanel(),
              ],
            )
          : const Center(child: CircularProgressIndicator(color: Color(0xFFFF3B3B))),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Colors.white)),
          const Expanded(child: Text('타겟 정밀 설정', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white))),
          Text('${_project!.progressPercentage.toStringAsFixed(0)}%', style: const TextStyle(color: Color(0xFFFF3B3B), fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildSegmentTimeline() {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _project!.segments.length,
        itemBuilder: (c, i) => _buildSegmentCard(_project!.segments[i], i),
      ),
    );
  }

  Widget _buildSegmentCard(TrackingSegment s, int i) {
    bool isCurrent = i == _currentSegmentIndex;
    // Gap 상태 판별
    bool isGap = (s.initialTarget == null && s.isConfirmed);
    
    Color statusColor = isGap 
        ? Colors.blue 
        : (s.isConfirmed ? Colors.green : (s.initialTarget != null ? Colors.orange : Colors.white24));

    return GestureDetector(
      onTap: () {
        setState(() => _currentSegmentIndex = i);
        _videoController.seekTo(s.startTime);
      },
      child: Container(
        width: 70,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: isCurrent ? statusColor.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isCurrent ? const Color(0xFFFF3B3B) : statusColor, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('#${i+1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            if (isGap) const Icon(Icons.zoom_out_map, size: 14, color: Colors.blue),
            if (s.isConfirmed && !isGap) const Icon(Icons.check_circle, size: 14, color: Colors.green),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    final currentSegment = _project!.segments[_currentSegmentIndex];
    bool isGapMode = (currentSegment.initialTarget == null && currentSegment.isConfirmed);

    return Expanded(
      child: Center(
        child: AspectRatio(
          aspectRatio: _videoController.value.aspectRatio,
          child: InteractiveViewer(
            transformationController: _transformationController,
            maxScale: 10.0,
            child: Stack(
              key: _videoKey,
              children: [
                VideoPlayer(_videoController),
                if (isGapMode)
                  Positioned.fill(
                    child: Container(
                      color: Colors.blue.withValues(alpha: 0.15),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.zoom_out_map, color: Colors.blue, size: 40),
                            SizedBox(height: 8),
                            Text("Gap 구간: 전체 화면 전환", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (!_isPlaying && !_showPreview && !isGapMode) 
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent, 
                      onTapUp: (d) => _handleTapToSelectTarget(d.localPosition), 
                      child: Container(color: Colors.transparent)
                    ),
                  ),
                if (!_isPlaying && !_showPreview && currentSegment.initialTarget != null) 
                  _buildTargetBoxWithHandles(currentSegment.initialTarget!),
                if (_showPreview && _previewImage != null) _buildPreviewOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTargetBoxWithHandles(DetectedPerson person) {
    return LayoutBuilder(builder: (context, constraints) {
      final box = person.boundingBox;
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final left = box.left * size.width;
      final top = box.top * size.height;
      final width = box.width * size.width;
      final height = box.height * size.height;

      return Stack(
        children: [
          Positioned(
            left: left, top: top, width: width, height: height,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFFF3B3B), width: 2.0),
              ),
            ),
          ),
          _buildHandle(left, top, 'topLeft', size),
          _buildHandle(left + width, top, 'topRight', size),
          _buildHandle(left, top + height, 'bottomLeft', size),
          _buildHandle(left + width, top + height, 'bottomRight', size),
        ],
      );
    });
  }

  Widget _buildHandle(double x, double y, String corner, Size widgetSize) {
    return Positioned(
      left: x - 20, top: y - 20,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          setState(() {
            final segment = _project!.segments[_currentSegmentIndex];
            final box = segment.initialTarget!.boundingBox;
            final double scale = _transformationController.value.getMaxScaleOnAxis();

            double dx = (details.delta.dx / scale) / widgetSize.width;
            double dy = (details.delta.dy / scale) / widgetSize.height;

            double left = box.left; double top = box.top; double width = box.width; double height = box.height;
            if (corner == 'topLeft') { left += dx; top += dy; width -= dx; height -= dy; }
            else if (corner == 'topRight') { top += dy; width += dx; height -= dy; }
            else if (corner == 'bottomLeft') { left += dx; width -= dx; height += dy; }
            else if (corner == 'bottomRight') { width += dx; height += dy; }

            segment.initialTarget = DetectedPerson(
              boundingBox: BoundingBox(
                left: left.clamp(0.0, 1.0), 
                top: top.clamp(0.0, 1.0), 
                width: width.clamp(0.02, 1.0), 
                height: height.clamp(0.02, 1.0)
              ),
              center: Point(left + width / 2, top + height / 2),
              confidence: 1.0,
            );
          });
        },
        child: Container(
          width: 40, height: 40,
          color: Colors.transparent,
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

  Widget _buildVideoControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: Row(children: [
        IconButton(onPressed: () => setState(() => _isPlaying ? _videoController.pause() : _videoController.play()), icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: const Color(0xFFFF3B3B))),
        Expanded(child: Slider(value: _currentPosition.inMilliseconds.toDouble().clamp(0.0, _videoController.value.duration.inMilliseconds.toDouble()), max: _videoController.value.duration.inMilliseconds.toDouble(), onChanged: (v) => _videoController.seekTo(Duration(milliseconds: v.toInt())), activeColor: const Color(0xFFFF3B3B))),
      ]),
    );
  }

  Widget _buildSegmentActions() {
    final segment = _project!.segments[_currentSegmentIndex];
    bool isGap = (segment.initialTarget == null && segment.isConfirmed);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: _setCurrentSegmentAsGap, 
            icon: Icon(isGap ? Icons.check : Icons.zoom_out_map, size: 18),
            label: Text(isGap ? 'Gap 적용됨' : 'Gap 설정'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.blue,
              side: const BorderSide(color: Colors.blue, width: 1.5),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          )),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: ElevatedButton.icon(
            onPressed: segment.canConfirm ? _confirmCurrentSegment : null, 
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('현재 구간 확정'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00C853),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildBottomPanel() {
    bool canPreview = _project?.segments[_currentSegmentIndex].initialTarget != null;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Wrap(
            spacing: 8.0, runSpacing: 8.0, alignment: WrapAlignment.center,
            children: TargetAspectRatio.values.map((r) => ChoiceChip(
              label: Text(r.toString().split('.').last.replaceAll('_', ':')), 
              selected: _selectedRatio == r, 
              onSelected: (v) => setState(() => _selectedRatio = r)
            )).toList(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: OutlinedButton(
                onPressed: (_isPreviewLoading || !canPreview) ? null : _updatePreview,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15), 
                  side: BorderSide(color: canPreview ? const Color(0xFFFF3B3B) : Colors.white10)
                ),
                child: _isPreviewLoading 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) 
                  : Text('🔍 미리보기', style: TextStyle(color: canPreview ? Colors.white : Colors.white24)),
              )),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: ElevatedButton(
                onPressed: (_project != null && _project!.isAllConfirmed) ? _startProcessing : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF3B3B), 
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  disabledBackgroundColor: Colors.white10,
                ),
                child: const Text('렌더링 시작', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              )),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewOverlay() {
    return GestureDetector(
      onTap: () => setState(() => _showPreview = false), 
      child: Container(
        color: Colors.black.withValues(alpha: 0.95), 
        child: Stack(
          children: [
            Center(child: Image.file(_previewImage!, fit: BoxFit.contain)),
            const Positioned(
              top: 40, right: 20,
              child: Icon(Icons.close, color: Colors.white, size: 30),
            ),
            const Positioned(
              bottom: 40, left: 0, right: 0,
              child: Center(child: Text("화면을 터치하면 편집으로 돌아갑니다", style: TextStyle(color: Colors.white70))),
            )
          ],
        )
      )
    );
  }
}