import "package:inventree_smt/core/app_log.dart";
import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/inventree/models.dart";

/// Result of re-checking the stored locations against the server.
class LocationCheckResult {
  const LocationCheckResult({this.problems = const [], this.unchecked = false});

  /// Why a stored location was removed (shown to the user).
  final List<String> problems;

  /// The server could not be reached, so the stored locations were kept as they were.
  final bool unchecked;
}

/// Re-check the stored source / machine locations with the server (on startup).
///
/// - A location which no longer exists is removed from the settings.
/// - Names and paths are refreshed (e.g. a location was renamed or moved).
/// - If the locations are no longer valid together (e.g. the machine location
///   has been made structural, or moved inside the source location), the
///   machine location is removed.
/// - If the server cannot be reached, nothing is changed: the workflow checks
///   the data again as it goes.
///
/// Any location removed must be chosen again in Settings before the workflow
/// can be used.
Future<LocationCheckResult> recheckLocations(
  SettingsStore store,
  InvenTreeRepository repo,
) async {
  final WorkflowSettings stored = store.settings;
  final List<String> problems = [];
  bool unchecked = false;

  Future<StockLocationInfo?> check(StockLocationInfo? loc, String name) async {
    if (loc == null) return null;
    try {
      final StockLocationInfo fresh = await repo.getLocation(loc.pk);
      if (fresh.pathstring != loc.pathstring) {
        appLog.info(
          "settings",
          "$name location #${loc.pk} is now \"${fresh.pathstring}\" (was \"${loc.pathstring}\")",
        );
      }
      return fresh;
    } on ApiException catch (e) {
      if (e.isNotFound) {
        problems.add(
          "The $name location \"${loc.pathstring}\" no longer exists in InvenTree.",
        );
        return null;
      }
      unchecked = true;
      appLog.warning(
        "settings",
        "Could not check the $name location (${loc.pathstring}): ${e.message}",
      );
      return loc;
    }
  }

  StockLocationInfo? source = await check(stored.source, "source");
  StockLocationInfo? machine = await check(stored.machine, "machine");

  // Still valid together?
  final String? invalid = validateLocations(source, machine);
  if (invalid != null && machine != null) {
    problems.add("Machine location \"${machine.pathstring}\": $invalid");
    machine = null;
  }

  bool same(StockLocationInfo? a, StockLocationInfo? b) =>
      a?.pk == b?.pk &&
      a?.pathstring == b?.pathstring &&
      a?.structural == b?.structural;

  if (!same(source, stored.source) || !same(machine, stored.machine)) {
    await store.save(WorkflowSettings(source: source, machine: machine));
  }

  for (final p in problems) {
    appLog.error("settings", p);
  }

  return LocationCheckResult(problems: problems, unchecked: unchecked);
}
