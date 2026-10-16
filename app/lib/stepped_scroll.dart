/// Converts continuous finger motion into deliberate discrete wheel steps.
/// Does not send a scroll event until the finger has moved far enough.
class SteppedScroll {
  SteppedScroll({this.pixelsPerStep = 24, this.maxStepsPerEvent = 6})
      : assert(pixelsPerStep > 0), assert(maxStepsPerEvent > 0);

  final double pixelsPerStep;
  final int maxStepsPerEvent;
  double _remainder = 0;

  int add(double pixels) {
    if (!pixels.isFinite) return 0;
    _remainder += pixels;
    final steps = (_remainder / pixelsPerStep).truncate()
        .clamp(-maxStepsPerEvent, maxStepsPerEvent);
    _remainder -= steps * pixelsPerStep;
    return steps;
  }

  void reset() => _remainder = 0;
}
