import 'package:agent_os/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiConfig.parse', () {
    test('a :8000 address keeps its host and pairs it with :8080 for brain', () {
      final c = ApiConfig.parse('http://10.201.71.252:8000');
      expect(c.consoleBase, 'http://10.201.71.252:8000');
      expect(c.brainBase, 'http://10.201.71.252:8080');
    });

    test('localhost over adb reverse', () {
      final c = ApiConfig.parse('http://localhost:8000/');
      expect(c.consoleBase, 'http://localhost:8000');
      expect(c.brainBase, 'http://localhost:8080');
    });

    test('a missing scheme defaults to http', () {
      final c = ApiConfig.parse(' localhost:8000 ');
      expect(c.consoleBase, 'http://localhost:8000');
      expect(c.brainBase, 'http://localhost:8080');
    });

    test('anything else is one hosted origin', () {
      final c = ApiConfig.parse('https://agentos.duckdns.org/');
      expect(c.consoleBase, 'https://agentos.duckdns.org');
      expect(c.brainBase, 'https://agentos.duckdns.org');
    });
  });

  test('localDev targets localhost, reachable from emulator and phone via adb reverse', () {
    expect(ApiConfig.localDev.consoleBase, 'http://localhost:8000');
    expect(ApiConfig.localDev.brainBase, 'http://localhost:8080');
  });

  test('toJson/fromJson round-trips', () {
    final c = ApiConfig.parse('http://192.168.1.5:8000');
    final back = ApiConfig.fromJson(c.toJson());
    expect(back.consoleBase, c.consoleBase);
    expect(back.brainBase, c.brainBase);
  });
}
