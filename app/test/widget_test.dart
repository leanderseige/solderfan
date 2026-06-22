import 'package:flutter_test/flutter_test.dart';

import 'package:solderfan_control/main.dart';

void main() {
  testWidgets('SolderFan app shows the main control surface', (tester) async {
    await tester.pumpWidget(const SolderFanApp());

    expect(find.text('SolderFan'), findsOneWidget);
    expect(find.text('Fan 1'), findsNWidgets(2));
    expect(find.text('Fan 2'), findsNWidgets(2));
    expect(find.text('Potentiometer mode'), findsOneWidget);
  });
}
