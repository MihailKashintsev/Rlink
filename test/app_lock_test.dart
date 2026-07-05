import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/app_lock_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('passcode verifies correctly and rejects wrong codes', () async {
    await AppLockService.instance.setPasscode('1379');
    expect(AppLockService.instance.isEnabled, isTrue);
    expect(AppLockService.instance.codeLength, 4);
    expect(await AppLockService.instance.verify('1379'), isTrue);
    expect(await AppLockService.instance.verify('0000'), isFalse);
  });

  test('disable clears the passcode', () async {
    await AppLockService.instance.setPasscode('123456');
    await AppLockService.instance.disable();
    expect(AppLockService.instance.isEnabled, isFalse);
    expect(await AppLockService.instance.verify('123456'), isFalse);
  });
}
