import 'package:flutter_test/flutter_test.dart';
import 'package:nohut_falafel_desktop/trendyol_admin.dart';
import 'package:nohut_falafel_desktop/trendyol_go_readonly.dart';
import 'package:nohut_falafel_desktop/pos_logic.dart';

void main() {
  const credentials = TgoCredentials('12345', 'key', 'secret', 'a@b.com');

  test('updatePrice always includes restaurantId to protect other stores', () async {
    final calls = <String>[];
    Json? sent;
    final admin = TgoMealAdmin(credentials,
      transport: (method, uri, payload) async {
        calls.add(method + ' ' + uri.path);
        sent = payload;
        return const TgoResponse(200, {
          'batchRequestId': 'batch-12345678',
        });
      },
    );
    final result = await admin.updatePrice(
      restaurantId: 99,
      productId: 1001,
      sellingPriceCents: 18550,
    );
    expect(result.confirmed, isFalse);
    expect(result.pendingBatchId, 'batch-12345678');
    expect((sent?['items'] as List).single, {
      'restaurantId': 99,
      'productId': 1001,
      'sellingPrice': 185.5,
    });
    expect(calls.single, contains('/integrator/product/meal/suppliers/12345/products/price'));
  });

  test('batch is only confirmed when each item succeeded', () async {
    final admin = TgoMealAdmin(credentials, transport: (_, uri, __) async {
      expect(uri.path, contains('/batch-requests/'));
      return const TgoResponse(200, {
        'status': 'COMPLETED',
        'failedItemCount': 0,
        'items': [{'status': 'SUCCESS'}],
      });
    });
    final result = await admin.checkPriceBatch('batch-12345678');
    expect(result.confirmed, isTrue);
    expect(result.pendingBatchId, isNull);
  });

  test('failed price batch never appears as completed', () async {
    final admin = TgoMealAdmin(credentials, transport: (_, __, ___) async {
      return const TgoResponse(200, {
        'status': 'COMPLETED',
        'failedItemCount': 1,
        'items': [{'status': 'FAILED'}],
      });
    });
    expect(
      () => admin.checkPriceBatch('batch-12345678'),
      throwsFormatException,
    );
  });

  test('product and category updates use numeric store-scoped IDs', () async {
    final requests = <String>[];
    final bodies = <Json?>[];
    final admin = TgoMealAdmin(credentials, transport: (method, uri, body) async {
      requests.add(method + ' ' + uri.path);
      bodies.add(body);
      return const TgoResponse(200, {});
    });
    await admin.updateProductStatus(storeId: 77, productId: 55, active: false);
    await admin.updateSectionStatus(storeId: 77, sectionId: 8, active: true);
    expect(requests[0], contains('/stores/77/products/55/status'));
    expect(requests[1], contains('/stores/77/sections/8/status'));
    expect(bodies[0], {'status': 'PASSIVE'});
    expect(bodies[1], {'status': 'ACTIVE'});
  });

  test('working hours reject invalid input and preserve complete week', () async {
    final admin = TgoMealAdmin(credentials,
        transport: (method, uri, body) async {
      expect(method, 'PUT');
      expect(uri.path, contains('/working-hours'));
      expect(body?['workingHours'], isA<List>());
      return const TgoResponse(200, {});
    });
    expect(() => admin.updateWorkingHours(
      storeId: 77,
      hours: [{'dayOfWeek': 'MONDAY', 'openingTime': '99:00:00',
               'closingTime': '20:00:00'}],
    ), throwsFormatException);
    final result = await admin.updateWorkingHours(storeId: 77, hours: [
      {'dayOfWeek': 'MONDAY',
       'openingTime': '10:00:00', 'closingTime': '21:00:00'},
    ]);
    expect(result.confirmed, isFalse); // API acknowledgement, not readback
  });
}
