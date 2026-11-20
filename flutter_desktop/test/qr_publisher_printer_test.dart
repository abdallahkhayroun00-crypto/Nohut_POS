import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/printer_management.dart';
import 'package:nohut_falafel_desktop/qr_publisher_client.dart';

void main() {
  test('installed Windows printer list supports single and multiple entries',(){
    final one=parseWindowsPrinters(
      '{"Name":"Xprinter XP-237B","DriverName":"XP Driver",'
      '"PortName":"USB001","Default":true,"WorkOffline":false,'
      '"PrinterStatus":3}');
    expect(one,singleElement);
    expect(one.first.name,'Xprinter XP-237B');
    expect(one.first.isDefault,isTrue);
    expect(one.first.offline,isFalse);
    final multiple=parseWindowsPrinters(
      '[{"Name":"Xprinter XP-237B","DriverName":"XP","PortName":"USB001"},'
      '{"Name":"Microsoft Print to PDF","DriverName":"PDF","WorkOffline":true},'
      '{"Name":"Xprinter XP-237B"}]');
    expect(multiple,hasLength(2));
    expect(multiple.first.name,'Microsoft Print to PDF');
    expect(multiple.first.offline,isTrue);
  });

  test('publisher bridge allows only HTTPS or local loopback HTTP',(){
    expect(QrPublisherClient.checkEndpoint('http://127.0.0.1:8787').host,
      '127.0.0.1');
    expect(QrPublisherClient.checkEndpoint('https://publisher.example.org')
      .scheme,'https');
    for(final bad in [
      'http://example.org',
      'http://192.168.1.40:8787',
      'https://user:token@example.org',
      'https://example.org/path',
      'https://example.org/?token=secret',
      'file:///etc/passwd',
    ]){
      expect(()=>QrPublisherClient.checkEndpoint(bad),
        throwsFormatException,reason:bad);
    }
  });
}
