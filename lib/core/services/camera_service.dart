import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:path_provider/path_provider.dart';

class CameraService {
  CameraController? _controller;
  bool _isRecording = false;

  CameraController? get controller => _controller;
  bool get isRecording => _isRecording;

  Future<bool> initializeCamera(CameraDescription camera) async {
    try {
      _controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: true,
      );

      await _controller!.initialize();
      return true;
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    try {
      await _controller?.dispose();
      _controller = null;
    } catch (e) {
      debugPrint('Error disposing camera: $e');
    }
  }

  Future<String?> startRecording() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      return null;
    }

    try {
      final directory = await getTemporaryDirectory();
      final String filePath = '${directory.path}/fight_cam_${DateTime.now().millisecondsSinceEpoch}.mp4';
      
      await _controller!.startVideoRecording();
      _isRecording = true;
      
      return filePath;
    } catch (e) {
      debugPrint('Error starting recording: $e');
      return null;
    }
  }

  Future<String?> stopRecording() async {
    if (_controller == null || !_isRecording) {
      return null;
    }

    try {
      final XFile videoFile = await _controller!.stopVideoRecording();
      _isRecording = false;
      
      return videoFile.path;
    } catch (e) {
      debugPrint('Error stopping recording: $e');
      return null;
    }
  }

  Future<bool> saveVideoToGallery(String filePath) async {
    try {
      final result = await ImageGallerySaver.saveFile(filePath);
      return result != null && result['isSuccess'] == true;
    } catch (e) {
      debugPrint('Error saving video to gallery: $e');
      return false;
    }
  }

  Future<void> switchCamera(CameraDescription newCamera) async {
    try {
      await dispose();
      await initializeCamera(newCamera);
    } catch (e) {
      debugPrint('Error switching camera: $e');
    }
  }

  Future<void> setFlashMode(FlashMode mode) async {
    if (_controller != null && _controller!.value.isInitialized) {
      try {
        await _controller!.setFlashMode(mode);
      } catch (e) {
        debugPrint('Error setting flash mode: $e');
      }
    }
  }

  void setZoomLevel(double zoom) {
    if (_controller != null && _controller!.value.isInitialized) {
      try {
        _controller!.setZoomLevel(zoom);
      } catch (e) {
        debugPrint('Error setting zoom level: $e');
      }
    }
  }

  Future<double> getMaxZoomLevel() async {
    if (_controller != null && _controller!.value.isInitialized) {
      try {
        return await _controller!.getMaxZoomLevel();
      } catch (e) {
        debugPrint('Error getting max zoom level: $e');
        return 1.0;
      }
    }
    return 1.0;
  }

  Future<double> getMinZoomLevel() async {
    if (_controller != null && _controller!.value.isInitialized) {
      try {
        return await _controller!.getMinZoomLevel();
      } catch (e) {
        debugPrint('Error getting min zoom level: $e');
        return 1.0;
      }
    }
    return 1.0;
  }
}