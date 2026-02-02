import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 임시 파일 정리 서비스
/// 분석 및 편집 과정에서 생성된 임시 파일들을 삭제
class CleanupService {
  /// 임시 디렉토리의 모든 파일 삭제
  Future<void> cleanupTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      debugPrint('임시 파일 정리 시작: ${tempDir.path}');

      int deletedCount = 0;
      int totalSize = 0;

      // 임시 디렉토리의 모든 항목 탐색
      final entities = tempDir.listSync(recursive: true);

      for (final entity in entities) {
        try {
          if (entity is File) {
            // 파일 크기 계산
            final size = await entity.length();
            totalSize += size;

            // 파일 삭제
            await entity.delete();
            deletedCount++;
          }
        } catch (e) {
          debugPrint('파일 삭제 실패: ${entity.path} - $e');
        }
      }

      debugPrint('임시 파일 정리 완료: $deletedCount개 파일, ${(totalSize / 1024 / 1024).toStringAsFixed(2)}MB 확보');
    } catch (e) {
      debugPrint('임시 파일 정리 오류: $e');
    }
  }

  /// 특정 패턴의 파일만 삭제 (예: fight_cam으로 시작하는 파일)
  ///
  /// [excludePath]: 삭제에서 제외할 파일 경로 (현재 사용 중인 비디오 등)
  Future<void> cleanupFightCamFiles({String? excludePath}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      debugPrint('Fight-Cam 임시 파일 정리 시작');
      if (excludePath != null) {
        debugPrint('제외 경로: $excludePath');
      }

      int deletedCount = 0;

      final entities = tempDir.listSync(recursive: true);

      for (final entity in entities) {
        try {
          if (entity is File) {
            // 제외 경로와 일치하면 건너뛰기
            if (excludePath != null && entity.path == excludePath) {
              debugPrint('제외: ${entity.path}');
              continue;
            }

            final fileName = entity.path.split('/').last;

            // fight_cam으로 시작하는 파일만 삭제
            if (fileName.startsWith('fight_cam_') ||
                fileName.startsWith('flutter_') ||
                fileName.endsWith('.jpg') ||
                fileName.endsWith('.jpeg')) {
              await entity.delete();
              deletedCount++;
            }
          }
        } catch (e) {
          debugPrint('파일 삭제 실패: ${entity.path} - $e');
        }
      }

      debugPrint('Fight-Cam 임시 파일 정리 완료: $deletedCount개 파일 삭제');
    } catch (e) {
      debugPrint('Fight-Cam 파일 정리 오류: $e');
    }
  }

  /// 오래된 파일 정리 (24시간 이상 된 파일)
  Future<void> cleanupOldFiles({Duration age = const Duration(hours: 24)}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final now = DateTime.now();

      debugPrint('오래된 파일 정리 시작 (${age.inHours}시간 이상)');

      int deletedCount = 0;

      final entities = tempDir.listSync(recursive: true);

      for (final entity in entities) {
        try {
          if (entity is File) {
            final stat = await entity.stat();
            final fileAge = now.difference(stat.modified);

            if (fileAge > age) {
              await entity.delete();
              deletedCount++;
            }
          }
        } catch (e) {
          debugPrint('파일 삭제 실패: ${entity.path} - $e');
        }
      }

      debugPrint('오래된 파일 정리 완료: $deletedCount개 파일 삭제');
    } catch (e) {
      debugPrint('오래된 파일 정리 오류: $e');
    }
  }

  /// 캐시 디렉토리 정리
  Future<void> cleanupCacheDirectory() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      debugPrint('캐시 디렉토리 정리: ${cacheDir.path}');

      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
        await cacheDir.create(); // 디렉토리 재생성
        debugPrint('캐시 디렉토리 정리 완료');
      }
    } catch (e) {
      debugPrint('캐시 디렉토리 정리 오류: $e');
    }
  }

  /// 앱 종료 시 자동 정리
  Future<void> cleanupOnAppExit() async {
    debugPrint('앱 종료 - 임시 파일 자동 정리');
    await cleanupFightCamFiles();
  }
}
