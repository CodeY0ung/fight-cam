/// 타겟 화면 비율
enum TargetAspectRatio {
  vertical_9_16,   // 세로 9:16 (인스타그램 릴스, 틱톡)
  square_1_1,      // 정사각형 1:1 (인스타그램 피드)
  portrait_4_5,    // 세로 4:5 (인스타그램 피드)
  landscape_16_9,  // 가로 16:9 (유튜브)
}

/// 비디오 화질 설정
/// 처리 속도와 화질 사이의 균형을 선택
enum VideoQuality {
  fhd, // 1080p, 10Mbps, Lanczos (High Quality, Slow)
  hd,  // 720p, 5Mbps, Bilinear (Standard, Fast)
}

extension VideoQualityExtension on VideoQuality {
  String get label {
    switch (this) {
      case VideoQuality.fhd:
        return 'FHD (1080p) - 고화질 (느림)';
      case VideoQuality.hd:
        return 'HD (720p) - 일반 (빠름/추천)';
    }
  }

  /// 기본 해상도 (짧은 쪽 기준)
  int get baseSize {
    switch (this) {
      case VideoQuality.fhd:
        return 1080;
      case VideoQuality.hd:
        return 720;
    }
  }

  /// 비트레이트 (Mbps)
  int get bitrate {
    switch (this) {
      case VideoQuality.fhd:
        return 10; // 방송급 화질
      case VideoQuality.hd:
        return 5; // 일반 화질
    }
  }

  /// 스케일링 알고리즘
  String get scalingAlgorithm {
    switch (this) {
      case VideoQuality.fhd:
        return 'lanczos'; // 고품질 보간
      case VideoQuality.hd:
        return 'bilinear'; // 빠른 보간
    }
  }

  /// 예상 처리 속도 (상대적)
  String get speedDescription {
    switch (this) {
      case VideoQuality.fhd:
        return '매우 느림 (10분 영상 = 약 1시간)';
      case VideoQuality.hd:
        return '빠름 (10분 영상 = 약 15분, 추천)';
    }
  }
}
