import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/engine/engine.dart';

part 'external_engine.freezed.dart';

/// Status of the external engine connection.
///
/// The status is scoped to an engine session (i.e. an analysis screen instance): it is reset
/// when the evaluation service is quit.
enum ExternalEngineStatus {
  /// No external engine request has been made in this session.
  none,

  /// An analysis request has been sent, waiting for the first evaluation line.
  connecting,

  /// The external engine is streaming (or has streamed) evaluations in this session.
  connected,

  /// The external engine failed (timeout, network or server error).
  ///
  /// While offline, evaluation requests fall back to the local engine for the rest of the
  /// session. The status can be reset with the evaluation service's `retryExternalEngine`, by
  /// toggling the engine, or by starting a new session.
  offline,
}

/// An external engine registered with the Lichess External Engine API.
///
/// External engines are registered per account by a provider daemon running on the user's own
/// hardware. See https://lichess.org/api#tag/External-engine.
@freezed
sealed class ExternalEngine with _$ExternalEngine {
  const ExternalEngine._();

  const factory ExternalEngine({
    required String id,
    required String name,

    /// Secret token that grants permission to request analysis from this engine.
    ///
    /// This is sensitive data: it must not be persisted on the device.
    required String clientSecret,
    required int maxThreads,
    required int maxHash,

    /// The UCI variant names supported by the engine (e.g. 'chess', 'atomic', '3check').
    required IList<String> variants,
  }) = _ExternalEngine;

  /// Whether the engine supports the given [Variant].
  bool supportsVariant(Variant variant) => variants.contains(variant.fairy);

  /// The slim value object carried by an `EvalWork` to request analysis from this engine.
  ExternalEngineWorkSpec get workSpec => ExternalEngineWorkSpec(
    id: id,
    name: name,
    clientSecret: clientSecret,
    maxThreads: maxThreads,
    maxHash: maxHash,
  );
}

/// The external engine parameters carried by an `EvalWork`.
///
/// When this is set on a work item, the evaluation service routes the work to the external
/// engine broker instead of the local Stockfish (unless the external engine is offline).
///
/// The work item's own `threads` and `hashSize` fields keep their local-engine values so that
/// a fallback to the local engine can reuse the same work unchanged; the broker request uses
/// [maxThreads] and [maxHash] instead (that is the point of running on one's own hardware).
@freezed
sealed class ExternalEngineWorkSpec with _$ExternalEngineWorkSpec {
  const factory ExternalEngineWorkSpec({
    required String id,
    required String name,
    required String clientSecret,
    required int maxThreads,
    required int maxHash,
  }) = _ExternalEngineWorkSpec;
}
