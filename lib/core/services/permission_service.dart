import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  
  Future<bool> requestCameraPermission() async {
    try {
      final status = await Permission.camera.request();
      return status.isGranted;
    } catch (e) {
      return false;
    }
  }

  Future<bool> requestMicrophonePermission() async {
    try {
      final status = await Permission.microphone.request();
      return status.isGranted;
    } catch (e) {
      return false;
    }
  }

  Future<bool> requestStoragePermission() async {
    try {
      final status = await Permission.storage.request();
      return status.isGranted;
    } catch (e) {
      return false;
    }
  }

  Future<bool> requestPhotosPermission() async {
    try {
      final status = await Permission.photos.request();
      return status.isGranted;
    } catch (e) {
      return false;
    }
  }

  Future<bool> requestAllPermissions() async {
    try {
      final cameraGranted = await requestCameraPermission();
      final microphoneGranted = await requestMicrophonePermission();
      final storageGranted = await requestStoragePermission();
      final photosGranted = await requestPhotosPermission();
      
      return cameraGranted && microphoneGranted && storageGranted && photosGranted;
    } catch (e) {
      return false;
    }
  }

  Future<bool> hasCameraPermission() async {
    return await Permission.camera.isGranted;
  }

  Future<bool> hasMicrophonePermission() async {
    return await Permission.microphone.isGranted;
  }

  Future<bool> hasStoragePermission() async {
    return await Permission.storage.isGranted;
  }

  Future<bool> hasPhotosPermission() async {
    return await Permission.photos.isGranted;
  }
}