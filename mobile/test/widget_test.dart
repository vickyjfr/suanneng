import 'package:flutter_test/flutter_test.dart';
import 'package:se9_mobile/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders the SE9 file manager shell', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const Se9App());
    expect(find.text('SE9 文件管理'), findsOneWidget);
    expect(find.text('未登录'), findsOneWidget);
  });
}
