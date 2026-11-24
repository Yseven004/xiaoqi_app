import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoqi_app/services/companion_pdf_reflow.dart';

/// Native file I/O and the Flutter test frame clock must both advance before
/// Windows can release and remove a PDF whose background task outlives its UI.
Future<void> finishCompanionPdfPreparation(WidgetTester tester) async {
  var done = false;
  final pending = CompanionPdfReflow.pendingPreparations.then(
    (_) => done = true,
  );
  for (var step = 0; step < 600 && !done; step++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 32));
  }
  expect(
    done,
    isTrue,
    reason: 'Background PDF worker must close the fixture file',
  );
  await pending;
}
