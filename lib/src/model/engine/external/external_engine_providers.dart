import 'package:collection/collection.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_preferences.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_service.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine_repository.dart';
import 'package:lichess_mobile/src/network/http.dart';

/// Fetches the external engines registered for the current account.
///
/// Returns an empty list when the user is not logged in.
final externalEnginesProvider = FutureProvider.autoDispose<IList<ExternalEngine>>((Ref ref) {
  final isLoggedIn = ref.watch(isLoggedInProvider);
  if (!isLoggedIn) {
    return Future.value(const IListConst([]));
  }
  return ref.withClientCacheFor(
    (client) => ExternalEngineRepository(client).listEngines(),
    const Duration(minutes: 5),
  );
}, name: 'ExternalEnginesProvider');

/// Resolves the external engine selected in the engine preferences.
///
/// Returns `null` (meaning the local engine will be used) when no external engine is selected,
/// the user is logged out, the engine is no longer registered server-side, or the engine list
/// cannot be fetched.
final selectedExternalEngineProvider = FutureProvider.autoDispose<ExternalEngine?>((Ref ref) async {
  final selectedId = ref.watch(
    engineEvaluationPreferencesProvider.select((s) => s.externalEngineId),
  );
  if (selectedId == null) return null;
  if (!ref.watch(isLoggedInProvider)) return null;
  try {
    final engines = await ref.watch(externalEnginesProvider.future);
    return engines.firstWhereOrNull((engine) => engine.id == selectedId);
  } catch (_) {
    return null;
  }
}, name: 'SelectedExternalEngineProvider');

/// Exposes the status of the external engine connection to the UI.
final externalEngineStatusProvider =
    NotifierProvider.autoDispose<ExternalEngineStatusNotifier, ExternalEngineStatus>(
      ExternalEngineStatusNotifier.new,
      name: 'ExternalEngineStatusProvider',
    );

class ExternalEngineStatusNotifier extends Notifier<ExternalEngineStatus> {
  late ValueListenable<ExternalEngineStatus> _listenable;

  @override
  ExternalEngineStatus build() {
    _listenable = ref.watch(evaluationServiceProvider).externalEngineStatus;

    _listenable.addListener(_listener);

    ref.onDispose(() {
      _listenable.removeListener(_listener);
    });

    return _listenable.value;
  }

  void _listener() {
    // Defer state update to run outside Riverpod's callback stack, as notifications can be
    // triggered during disposal of other providers (see EngineEvaluationNotifier).
    Future.microtask(() {
      if (!ref.mounted) return;
      state = _listenable.value;
    });
  }
}
