/// Shared marker and timing helper for Fastlane's Flutter screenshot capture.
library;

typedef ScreenshotWait = Future<void> Function(Duration duration);
typedef ScreenshotPump = Future<void> Function(Duration duration);

/// Settles a screen, announces it to the host capture script, and holds it.
final class PlayScreenshotDriver {
  const PlayScreenshotDriver({
    required this.wait,
    required this.pump,
    this.settleCycles = 15,
    this.frameDelay = const Duration(milliseconds: 40),
    this.pumpDuration = const Duration(milliseconds: 100),
    this.captureDuration = const Duration(seconds: 3),
  });

  final ScreenshotWait wait;
  final ScreenshotPump pump;
  final int settleCycles;
  final Duration frameDelay;
  final Duration pumpDuration;
  final Duration captureDuration;

  Future<void> capture(String name) async {
    if (!RegExp(r'^[0-9a-z-]+$').hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Use lowercase letters, digits, and hyphens.',
      );
    }
    if (settleCycles < 1) {
      throw ArgumentError.value(
        settleCycles,
        'settleCycles',
        'Must be positive.',
      );
    }
    for (var i = 0; i < settleCycles; i++) {
      await wait(frameDelay);
      await pump(pumpDuration);
    }
    // ignore: avoid_print
    print('PLAY_SHOT $name');
    await wait(captureDuration);
  }
}
