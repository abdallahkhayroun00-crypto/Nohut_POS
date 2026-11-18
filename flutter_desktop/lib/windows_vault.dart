import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as paths;

final class _DataBlob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> bytes;
}

typedef _DpapiNative =
    Int32 Function(
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_DataBlob>,
    );
typedef _DpapiDart =
    int Function(
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_DataBlob>,
    );

Uint8List _protectForCurrentUser(List<int> data, {required bool decrypt}) {
  if (!Platform.isWindows) {
    throw const FormatException('Windows güvenli kasa gerekli.');
  }
  final crypt32 = DynamicLibrary.open('crypt32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final transform = crypt32.lookupFunction<_DpapiNative, _DpapiDart>(
    decrypt ? 'CryptUnprotectData' : 'CryptProtectData',
  );
  final localFree = kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  final input = calloc<_DataBlob>();
  final output = calloc<_DataBlob>();
  final source = calloc<Uint8>(data.length);
  try {
    source.asTypedList(data.length).setAll(0, data);
    input.ref
      ..length = data.length
      ..bytes = source;
    // Current user scope, with system prompts disabled.
    if (transform(input, nullptr, nullptr, nullptr, nullptr, 1, output) == 0) {
      throw const FormatException('Windows güvenli kasa işlemi başarısız.');
    }
    return Uint8List.fromList(output.ref.bytes.asTypedList(output.ref.length));
  } finally {
    if (output.ref.bytes != nullptr) {
      output.ref.bytes
          .asTypedList(output.ref.length)
          .fillRange(0, output.ref.length, 0);
      localFree(output.ref.bytes.cast<Void>());
    }
    source.asTypedList(data.length).fillRange(0, data.length, 0);
    calloc.free(source);
    calloc.free(output);
    calloc.free(input);
  }
}

class WindowsVault {
  const WindowsVault(this.file);
  final File file;

  Future<Map<String, dynamic>?> load() async {
    if (!await file.exists()) return null;
    final ciphertext = base64Decode((await file.readAsString()).trim());
    final clear = _protectForCurrentUser(ciphertext, decrypt: true);
    try {
      return (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  Future<void> save(Map<String, dynamic> fields) async {
    final clear = utf8.encode(jsonEncode(fields));
    final String encrypted;
    try {
      encrypted = base64Encode(_protectForCurrentUser(clear, decrypt: false));
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
    await file.parent.create(recursive: true);
    final staging = await file.parent.createTemp('.vault-');
    try {
      final pending = File(paths.join(staging.path, 'credentials.dpapi'));
      await pending.writeAsString(encrypted, flush: true);
      await pending.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}
