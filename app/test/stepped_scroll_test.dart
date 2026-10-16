import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/stepped_scroll.dart';

void main() {
  test('small motion accumulates into deliberate wheel steps', () {
    final scroll = SteppedScroll();
    expect(scroll.add(10), 0);
    expect(scroll.add(13), 0);
    expect(scroll.add(2), 1);
    expect(scroll.add(24), 1);
    expect(scroll.add(-48), -1);
    expect(scroll.add(-24), -1);
    scroll.reset();
    expect(scroll.add(12), 0);
    expect(scroll.add(12), 1);
  });

  test('each packet is bounded even for a sudden large gesture', () {
    final scroll = SteppedScroll();
    expect(scroll.add(600), 6);
    expect(scroll.add(0), 6);
    expect(scroll.add(double.nan), 0);
    scroll.reset();
    expect(scroll.add(-24), -1);
  });
}
