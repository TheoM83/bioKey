abstract interface class Clock {
  int nowSec();
}

final class SystemClock implements Clock {
  const SystemClock();
  @override
  int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

final class FakeClock implements Clock {
  FakeClock(this.now);
  int now;
  @override
  int nowSec() => now;
}
