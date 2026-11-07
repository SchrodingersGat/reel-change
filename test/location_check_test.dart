/*
 * Startup re-check of the stored locations, against the fake InvenTree server.
 * Fake locations: 1 Stores, 2 Stores/Shelf A, 3 SMT Line, 4 Elsewhere.
 */

import "package:flutter_test/flutter_test.dart";

import "package:reel_change/auth/auth_service.dart";
import "package:reel_change/core/credential_store.dart";
import "package:reel_change/core/settings_store.dart";
import "package:reel_change/inventree/inventree_repository.dart";
import "package:reel_change/inventree/models.dart";
import "package:reel_change/workflow/location_check.dart";

import "fake_inventree.dart";

const source = StockLocationInfo(pk: 1, name: "Stores", pathstring: "Stores");
const machine = StockLocationInfo(
  pk: 3,
  name: "SMT Line",
  pathstring: "SMT Line",
);

void main() {
  late FakeInvenTree server;
  late InvenTreeRepository repo;
  late SettingsStore store;
  late MemorySettingsBackend backend;

  setUp(() async {
    server = await FakeInvenTree.start();
    final auth = AuthService(store: MemoryCredentialStore());
    await auth.login(server.url, "reader", "secret");
    repo = InvenTreeRepository(auth.api);

    backend = MemorySettingsBackend();
    store = SettingsStore(backend);
    await store.load(server.url);
    await store.save(const WorkflowSettings(source: source, machine: machine));
  });

  tearDown(() async {
    try {
      await server.close();
    } catch (_) {}
  });

  test("Unchanged locations - nothing to report or save", () async {
    final String? before = backend.data;

    final result = await recheckLocations(store, repo);

    expect(result.problems, isEmpty);
    expect(result.unchecked, isFalse);
    expect(store.settings.isComplete, isTrue);
    expect(backend.data, before);
  });

  test("Renamed location - path refreshed and saved", () async {
    server.inventory.locations[3]!["pathstring"] = "Line 1/SMT Machine";

    final result = await recheckLocations(store, repo);

    expect(result.problems, isEmpty);
    expect(store.settings.machine?.pathstring, "Line 1/SMT Machine");

    final again = SettingsStore(backend);
    await again.load(server.url);
    expect(again.settings.machine?.pathstring, "Line 1/SMT Machine");
  });

  test("Deleted location - removed, with an explanation", () async {
    server.inventory.locations.remove(1);

    final result = await recheckLocations(store, repo);

    expect(result.problems.single, contains("\"Stores\" no longer exists"));
    expect(store.settings.source, isNull);
    expect(store.settings.machine?.pk, 3);
    expect(store.settings.isComplete, isFalse);
  });

  test("Machine location made structural - removed", () async {
    server.inventory.locations[3]!["structural"] = true;

    final result = await recheckLocations(store, repo);

    expect(result.problems.single, contains("structural"));
    expect(store.settings.machine, isNull);
    expect(store.settings.source?.pk, 1);
  });

  test("Machine location moved inside the source - removed", () async {
    server.inventory.locations[3]!["pathstring"] = "Stores/SMT Line";

    final result = await recheckLocations(store, repo);

    expect(result.problems.single, contains("inside the source"));
    expect(store.settings.machine, isNull);
  });

  test("Server unreachable - stored locations kept", () async {
    await server.close();

    final result = await recheckLocations(store, repo);

    expect(result.unchecked, isTrue);
    expect(result.problems, isEmpty);
    expect(store.settings.isComplete, isTrue);
  });
}
