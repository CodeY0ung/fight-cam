import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 백그라운드 작업 알림 서비스 (Singleton)
///
/// 기능:
/// - 진행률 알림: 앱이 백그라운드에 있어도 작업 진행 상황 표시
/// - 포그라운드 서비스: ongoing=true로 OS에게 "중요한 작업 중"이라고 알림
/// - 완료 알림: 작업이 끝나면 소리와 함께 알림
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  /// 알림 시스템 초기화
  /// 앱 시작 시 호출 필요
  Future<void> init() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  /// 진행률 알림 표시 (진행 중일 때 계속 업데이트)
  ///
  /// [progress]: 0~100 사이의 진행률
  /// [message]: 현재 작업 설명 (예: "AI 분석 중...", "영상 생성 중...")
  Future<void> showProgressNotification(int progress, String message) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'fight_cam_processing', // 채널 ID
      'Video Processing', // 채널 이름
      channelDescription: 'Showing progress of video processing',
      importance: Importance.low, // 소리 안 나게 (업데이트 빈번함)
      priority: Priority.low,
      onlyAlertOnce: true, // 알림이 올 때마다 딩동거리지 않게
      showProgress: true, // 진행률 바 표시
      maxProgress: 100,
      progress: progress.clamp(0, 100), // 0~100 범위 보장
      ongoing: true, // 사용자가 못 지우게 함 (작업 중임을 표시)
      autoCancel: false,
    );

    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      888, // 알림 ID (고정)
      'Fight Cam 작업 중...',
      '$message ($progress%)',
      platformChannelSpecifics,
    );
  }

  /// 완료 알림 표시
  ///
  /// [path]: 생성된 파일 경로 (현재는 미사용, 향후 탭하면 파일 열기 기능 추가 가능)
  Future<void> showCompleteNotification(String path) async {
    // 진행률 알림 삭제
    await flutterLocalNotificationsPlugin.cancel(888);

    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'fight_cam_completed',
      'Processing Completed',
      channelDescription: 'Notifies when video processing is done',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true, // 완료 시에는 소리 울림
    );

    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      999,
      '작업 완료! 🎉',
      '멋진 직캠이 생성되었습니다. 갤러리를 확인하세요.',
      platformChannelSpecifics,
    );
  }

  /// 에러 발생 시 알림 취소
  /// 작업이 실패하거나 사용자가 취소했을 때 호출
  Future<void> cancelAll() async {
    await flutterLocalNotificationsPlugin.cancelAll();
  }
}
