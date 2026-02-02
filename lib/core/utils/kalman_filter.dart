import '../models/detected_person.dart';

class AlphaBetaGammaFilter2D {
  double x = 0, y = 0;   
  double vx = 0, vy = 0; 
  double ax = 0, ay = 0; 

  // [V4.1 묵직한 질감] 극도로 낮춘 추종성
  double alpha = 0.05; 
  double beta = 0.015;  
  double gamma = 0.002; 

  double maxVelocity = 0.6;      
  double maxAcceleration = 0.3;  

  AlphaBetaGammaFilter2D({double? alpha, double? beta, double? gamma}) {
    if (alpha != null) this.alpha = alpha;
    if (beta != null) this.beta = beta;
    if (gamma != null) this.gamma = gamma;
  }

  void init(Point p) { x = p.x; y = p.y; vx = 0; vy = 0; ax = 0; ay = 0; }
  void reset(Point p) => init(p);

  Point predict(double dt) {
    x = (x + (vx * dt) + (0.5 * ax * dt * dt)).clamp(0.0, 1.0);
    y = (y + (vy * dt) + (0.5 * ay * dt * dt)).clamp(0.0, 1.0);
    vx = (vx + (ax * dt)).clamp(-maxVelocity, maxVelocity);
    vy = (vy + (ay * dt)).clamp(-maxVelocity, maxVelocity);
    return Point(x, y);
  }

  Point update(Point measure, double dt) {
    double rx = measure.x - x;
    double ry = measure.y - y;
    double dist = rx.abs() + ry.abs();

    // [트래킹 튐 방지 로직]
    double adaptiveAlpha = alpha;
    
    // 1. 천장 오인식 방지: 화면 상단 20% 지점으로 급격히 튀면 무시
    if (measure.y < 0.2 && ry < -0.15) {
      adaptiveAlpha *= 0.1;
    }
    
    // 2. 타인 점프 방지: 현재 위치에서 갑자기 25% 이상 멀어지면 신뢰도 하향
    if (dist > 0.25) {
      adaptiveAlpha *= 0.2;
    }

    x += adaptiveAlpha * rx;
    y += adaptiveAlpha * ry;

    vx = (vx + (beta / dt) * rx).clamp(-maxVelocity, maxVelocity);
    vy = (vy + (beta / dt) * ry).clamp(-maxVelocity, maxVelocity);
    ax = (ax + (gamma / (0.5 * dt * dt)) * rx).clamp(-maxAcceleration, maxAcceleration);
    ay = (ay + (gamma / (0.5 * dt * dt)) * ry).clamp(-maxAcceleration, maxAcceleration);

    return Point(x, y);
  }
}

class KalmanFilter1D {
  double v = 0;
  double p = 1.0;
  final double q = 0.00001; // 더 극단적으로 매끄럽게
  final double r = 3.0;     // 측정값 무시 수준 상향

  void init(double initialV) { v = initialV; p = 1.0; }
  void reset(double val) => init(val);

  double filter(double m) {
    p = p + q;
    double k = p / (p + r);
    v = v + k * (m - v);
    p = (1 - k) * p;
    return v;
  }
}