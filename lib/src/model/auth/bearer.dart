import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Secret used to sign bearer tokens.
///
/// Declared here rather than in `constants.dart` so that this library has no Flutter
/// dependency: `tool/external_engine_spike.dart` imports it and must run on the plain Dart VM.
const kLichessWSSecret = String.fromEnvironment(
  'LICHESS_WS_SECRET',
  defaultValue: 'somethingElseInProd',
);

final hmacSha1 = Hmac(sha1, utf8.encode(kLichessWSSecret));

/// Sign a bearer token with the lichess secret.
String signBearerToken(String token) {
  final digest = hmacSha1.convert(utf8.encode(token));
  return '$token:$digest';
}
