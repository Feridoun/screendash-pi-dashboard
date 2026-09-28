import 'package:flutter_test/flutter_test.dart';
import 'package:screendash/services/system_ops.dart';

/// The Wi-Fi scanner parses `nmcli -t -f SSID,SIGNAL,SECURITY device wifi list`.
/// nmcli's terse mode ':'-separates fields and backslash-escapes any literal
/// ':' inside a value, so a naive `split(':')` mangles SSIDs that contain one.
void main() {
  group('splitNmcliLine', () {
    test('plain three-field line', () {
      expect(
        SystemOps.splitNmcliLine('Office-Guest:72:WPA2'),
        ['Office-Guest', '72', 'WPA2'],
      );
    });

    test('open network has an empty security field', () {
      expect(
        SystemOps.splitNmcliLine('CoffeeShop:40:'),
        ['CoffeeShop', '40', ''],
      );
    });

    test('escaped colon inside the SSID is preserved, not split', () {
      // nmcli emits an SSID "Net:5G" as "Net\:5G".
      expect(
        SystemOps.splitNmcliLine(r'Net\:5G:88:WPA2'),
        ['Net:5G', '88', 'WPA2'],
      );
    });

    test('multiple escaped colons', () {
      expect(
        SystemOps.splitNmcliLine(r'a\:b\:c:10:WPA3'),
        ['a:b:c', '10', 'WPA3'],
      );
    });

    test('a hidden/blank SSID yields an empty first field', () {
      expect(SystemOps.splitNmcliLine(':55:WPA2').first, '');
    });
  });
}
