import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/engine/engine.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_preferences.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine_providers.dart';
import 'package:lichess_mobile/src/model/engine/nnue_service.dart';
import 'package:lichess_mobile/src/utils/l10n_context.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/engine_settings_widget.dart';
import 'package:lichess_mobile/src/widgets/adaptive_choice_picker.dart';
import 'package:lichess_mobile/src/widgets/buttons.dart';
import 'package:lichess_mobile/src/widgets/list.dart';
import 'package:lichess_mobile/src/widgets/platform_alert_dialog.dart';
import 'package:lichess_mobile/src/widgets/settings.dart';
import 'package:lichess_mobile/src/widgets/shimmer.dart';

class EngineSettingsScreen extends ConsumerStatefulWidget {
  const EngineSettingsScreen({super.key});

  static Route<dynamic> buildRoute() {
    return buildScreenRoute(screen: const EngineSettingsScreen());
  }

  @override
  ConsumerState<EngineSettingsScreen> createState() => _EngineSettingsScreenState();
}

class _EngineSettingsScreenState extends ConsumerState<EngineSettingsScreen> {
  /// null = loading, true = has files with checked integrity, false = doesn't have files
  bool? _hasVerifiedNNUEFiles;

  Future<bool>? _downloadNNUEFilesFuture;

  late final ValueListenable<double> _downloadProgress;

  @override
  void initState() {
    ref.read(nnueServiceProvider).checkNNUEFiles().then((good) {
      if (mounted) {
        setState(() {
          _hasVerifiedNNUEFiles = good;
        });
      }
    });

    _downloadProgress = ref.read(nnueServiceProvider).nnueDownloadProgress;

    super.initState();
  }

  void _startDownload() {
    final future = ref.read(nnueServiceProvider).downloadNNUEFiles(inBackground: false);
    future.then((downloaded) {
      if (mounted && downloaded) {
        setState(() {
          _hasVerifiedNNUEFiles = true;
        });
      }
    });
    setState(() {
      _downloadNNUEFilesFuture = future;
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(engineEvaluationPreferencesProvider);
    final isLoggedIn = ref.watch(isLoggedInProvider);
    final externalEngines = ref.watch(externalEnginesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Chess engine')),
      body: ListView(
        children: [
          if (_hasVerifiedNNUEFiles == null)
            Shimmer(
              child: ShimmerLoading(isLoading: true, child: ListSection.loading(itemsNumber: 2)),
            )
          else
            ListSection(
              children: [
                SettingsListTile(
                  settingsLabel: const Text('Engine'),
                  settingsValue: prefs.enginePref.label,
                  onTap: () {
                    showChoicePicker(
                      context,
                      choices: ChessEnginePref.values,
                      selectedItem: prefs.enginePref,
                      labelBuilder: (ChessEnginePref t) => Text(t.label),
                      onSelectedItemChanged: (ChessEnginePref? value) {
                        ref
                            .read(engineEvaluationPreferencesProvider.notifier)
                            .setEvaluationFunction(value ?? ChessEnginePref.sf16);
                        if (value == ChessEnginePref.sfLatest && _hasVerifiedNNUEFiles == false) {
                          _startDownload();
                        }
                      },
                    );
                  },
                ),
                if (prefs.enginePref == ChessEnginePref.sfLatest && _hasVerifiedNNUEFiles == false)
                  LoadingButtonBuilder(
                    initialFuture: _downloadNNUEFilesFuture,
                    fetchData: () =>
                        ref.read(nnueServiceProvider).downloadNNUEFiles(inBackground: false),
                    builder: (context, isLoading, fetchData) {
                      return ListTile(
                        trailing: isLoading
                            ? AnimatedBuilder(
                                animation: _downloadProgress,
                                builder: (_, _) {
                                  final progress = _downloadProgress.value;
                                  return CircularProgressIndicator(
                                    value: progress > 0.0 ? progress : null,
                                  );
                                },
                              )
                            : const Icon(Icons.download),
                        title: Text(isLoading ? 'Downloading NNUE files' : 'Download NNUE files'),
                        subtitle: const Text(nnueTotalSizeMB),
                        enabled: !isLoading,
                        onTap: () async {
                          final downloaded = await fetchData();
                          if (context.mounted && downloaded) {
                            setState(() {
                              _hasVerifiedNNUEFiles = true;
                            });
                          }
                        },
                      );
                    },
                  )
                else if (prefs.enginePref == ChessEnginePref.sfLatest &&
                    _hasVerifiedNNUEFiles == true)
                  ListTile(
                    trailing: const Icon(Icons.check),
                    title: const Text('NNUE files downloaded'),
                    subtitle: const Text('$nnueTotalSizeMB (tap to delete)'),
                    onTap: () async {
                      final isOk = await showAdaptiveDialog<bool>(
                        context: context,
                        barrierDismissible: true,
                        builder: (context) {
                          return AlertDialog.adaptive(
                            content: const Text('Do you want to delete the NNUE files?'),
                            actions: [
                              PlatformDialogAction(
                                child: const Text('OK'),
                                onPressed: () {
                                  Navigator.of(context).pop(true);
                                },
                              ),
                              PlatformDialogAction(
                                child: Text(context.l10n.cancel),
                                onPressed: () {
                                  Navigator.of(context).pop(false);
                                },
                              ),
                            ],
                          );
                        },
                      );
                      if (isOk == true) {
                        await ref.read(nnueServiceProvider).deleteNNUEFiles();
                        if (!mounted) return;
                        setState(() {
                          _hasVerifiedNNUEFiles = false;
                        });
                      }
                    },
                  ),
              ],
            ),
          if (isLoggedIn)
            switch (externalEngines) {
              AsyncData(:final value) => ListSection(
                header: const SettingsSectionTitle('External engines'),
                footer: const Text(
                  'External engines run on your own hardware and are registered with your '
                  'Lichess account. When the selected engine is unreachable, analysis falls '
                  'back to the local engine.',
                ),
                children: [
                  if (value.isEmpty)
                    const ListTile(
                      title: Text('No external engine registered'),
                      subtitle: Text(
                        'Run an engine provider on your own hardware to register one with your '
                        'account.',
                      ),
                    )
                  else
                    for (final engine in value)
                      ListTile(
                        title: Text(engine.name),
                        subtitle: Text('${engine.maxThreads} threads, ${engine.maxHash} MB hash'),
                        trailing: prefs.externalEngineId == engine.id
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () {
                          ref
                              .read(engineEvaluationPreferencesProvider.notifier)
                              .setExternalEngine(
                                prefs.externalEngineId == engine.id ? null : engine,
                              );
                        },
                      ),
                  if (prefs.externalEngineId != null &&
                      value.every((engine) => engine.id != prefs.externalEngineId))
                    ListTile(
                      leading: const Icon(Icons.warning_amber),
                      title: Text(prefs.externalEngineName ?? 'Selected engine'),
                      subtitle: const Text(
                        'No longer available — using local engine (tap to clear)',
                      ),
                      onTap: () {
                        ref
                            .read(engineEvaluationPreferencesProvider.notifier)
                            .setExternalEngine(null);
                      },
                    ),
                ],
              ),
              AsyncError() => const ListSection(
                header: SettingsSectionTitle('External engines'),
                children: [ListTile(title: Text('Could not load external engines'))],
              ),
              _ => Shimmer(
                child: ShimmerLoading(
                  isLoading: true,
                  child: ListSection.loading(itemsNumber: 1, header: true),
                ),
              ),
            },
          EngineSettingsWidget(
            onSetEngineSearchTime: (value) {
              ref.read(engineEvaluationPreferencesProvider.notifier).setEngineSearchTime(value);
            },
            onSetEngineCores: (value) {
              ref.read(engineEvaluationPreferencesProvider.notifier).setEngineCores(value);
            },
            onSetNumEvalLines: (value) {
              ref.read(engineEvaluationPreferencesProvider.notifier).setNumEvalLines(value);
            },
          ),
        ],
      ),
    );
  }
}
