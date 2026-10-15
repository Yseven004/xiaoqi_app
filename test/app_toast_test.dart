import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiaoqi_app/widgets/app_toast.dart';

void main() {
  testWidgets('does not insert a toast after its source context is unmounted', (
    tester,
  ) async {
    late BuildContext sourceContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            sourceContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    AppToast.show(sourceContext, '不会显示');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(find.text('不会显示'), findsNothing);
  });
}
