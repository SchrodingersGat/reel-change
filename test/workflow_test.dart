/*
 * Reel-loading workflow tests, against the fake InvenTree server.
 * See fake_inventory.dart for the test data.
 */

import "package:flutter_test/flutter_test.dart";

import "package:reel_change/auth/auth_service.dart";
import "package:reel_change/core/credential_store.dart";
import "package:reel_change/core/settings_store.dart";
import "package:reel_change/inventree/inventree_repository.dart";
import "package:reel_change/inventree/models.dart";
import "package:reel_change/workflow/load_workflow.dart";

import "fake_inventree.dart";

const source = StockLocationInfo(pk: 1, name: "Stores", pathstring: "Stores");
const machine = StockLocationInfo(
  pk: 3,
  name: "SMT Line",
  pathstring: "SMT Line",
);

void main() {
  late FakeInvenTree server;
  late AuthService auth;
  late InvenTreeRepository repo;
  late LoadWorkflow wf;

  setUp(() async {
    server = await FakeInvenTree.start();
    auth = AuthService(store: MemoryCredentialStore());
    await auth.login(server.url, "reader", "secret");
    expect(auth.phase, AuthPhase.connected);
    repo = InvenTreeRepository(auth.api);
    wf = LoadWorkflow(
      repo: repo,
      settings: const WorkflowSettings(source: source, machine: machine),
    );
  });

  tearDown(() => server.close());

  /// Scan the empty reel in the machine (#1007, MPN RC0402-10K) and confirm.
  Future<void> toStep2() async {
    await wf.scanPart("INV-SI1007");
    await wf.confirmPart();
    expect(wf.step, WorkflowStep.selectStock);
  }

  /// Select + verify reel [pk] and confirm (accepting an alternate).
  Future<void> toStep3(int pk) async {
    await toStep2();
    wf.select(wf.candidates.firstWhere((c) => c.item.pk == pk));
    await wf.verifyScan("INV-SI$pk");
    expect(wf.selectionVerified, isTrue, reason: wf.verifyMessage);
    wf.confirmSelection();
    expect(wf.step, WorkflowStep.load);
  }

  group("Barcode resolution:", () {
    test("Stock item label", () async {
      final r = await repo.resolveBarcode("INV-SI1000");
      expect(r, isA<ScanResolved>());
      final p = (r as ScanResolved).result;
      expect(p.manufacturerPart.pk, 100);
      expect(p.manufacturerPart.mpn, "RC0402-10K");
      expect(p.manufacturerPart.manufacturerName, "Yageo");
      expect(p.part.displayName, "R 10k 0402");
      expect(p.stockItem?.pk, 1000);
    });

    test("Supplier label", () async {
      final r = await repo.resolveBarcode("SUPPLIER:201");
      expect((r as ScanResolved).result.manufacturerPart.mpn, "ERJ-2RKF1002X");
      expect(r.result.stockItem, isNull);
    });

    test("Manufacturer label", () async {
      final r = await repo.resolveBarcode("MFR:102");
      expect((r as ScanResolved).result.part.pk, 20);
    });

    test("Typed MPN (no barcode match) - exact lookup", () async {
      final r = await repo.resolveBarcode("  RC0402-10K ");
      expect((r as ScanResolved).result.manufacturerPart.pk, 100);
    });

    test("MPN shared by two manufacturers is ambiguous", () async {
      final r = await repo.resolveBarcode("DUP-1");
      expect(r, isA<ScanAmbiguous>());
      expect((r as ScanAmbiguous).options.map((o) => o.manufacturerPart.pk), [
        103,
        104,
      ]);
    });

    test("Stock item without supplier part is a data error", () async {
      final r = await repo.resolveBarcode("INV-SI1003");
      expect(r, isA<ScanDataError>());
      expect((r as ScanDataError).issue.webPath, "web/stock/item/1003");
      expect(r.issue.detail, contains("#1003"));
    });

    test("Supplier part without manufacturer part is a data error", () async {
      final r1 = await repo.resolveBarcode("INV-SI1004");
      expect(
        (r1 as ScanDataError).issue.webPath,
        "web/purchasing/supplier-part/202",
      );

      final r2 = await repo.resolveBarcode("SUPPLIER:202");
      expect(
        (r2 as ScanDataError).issue.webPath,
        "web/purchasing/supplier-part/202",
      );
    });

    test("Part-only barcode is a data error (MPN unknown)", () async {
      final r = await repo.resolveBarcode("PARTONLY:10");
      expect((r as ScanDataError).issue.webPath, "web/part/10");
    });

    test("Unknown, non-part and oversized barcodes", () async {
      expect(await repo.resolveBarcode("nothing-here"), isA<ScanNotFound>());
      expect(await repo.resolveBarcode("LOC:1"), isA<ScanNotFound>());
      expect(await repo.resolveBarcode(""), isA<ScanNotFound>());
      expect(
        await repo.resolveBarcode("x" * (kMaxBarcodeLength + 1)),
        isA<ScanNotFound>(),
      );
    });

    test("A plugin error is shown instead of a generic no-match", () async {
      server.inventory.pluginErrors["[)>06DIGIKEY"] =
          "Multiple matching supplier parts found";

      final r = await repo.resolveBarcode("[)>06DIGIKEY");
      expect(r, isA<ScanNotFound>());
      final String message = (r as ScanNotFound).message;
      expect(message, contains("DigiKeyPlugin"));
      expect(message, contains("Multiple matching supplier parts found"));

      // Generic no-match keeps the generic message
      final r2 = await repo.resolveBarcode("nothing-here");
      expect((r2 as ScanNotFound).message, isNot(contains("plugin")));
    });

    test("Plugin \"None\" gets the generic no-match message", () async {
      server.inventory.pluginErrors["UNKNOWN-LABEL"] =
          "No match found for barcode data";
      server.inventory.pluginErrorName = "None";

      final r = await repo.resolveBarcode("UNKNOWN-LABEL");
      final String message = (r as ScanNotFound).message;
      expect(message, isNot(contains("plugin")));
      expect(message, startsWith("No match found in InvenTree"));
    });

    test("A plugin error does not block an exact MPN match", () async {
      server.inventory.pluginErrors["RC0402-10K"] = "Some plugin problem";
      final r = await repo.resolveBarcode("RC0402-10K");
      expect((r as ScanResolved).result.manufacturerPart.pk, 100);
    });

    test("Plugin errors are read from either response shape", () {
      expect(
        PluginError.fromResponse({"error": "No match", "plugin": null}),
        isNull,
      );
      expect(PluginError.fromResponse({"plugin": "X"}), isNull);

      // "None" (Python's None as text) means no plugin matched
      for (final none in ["None", "none", " NULL "]) {
        expect(
          PluginError.fromResponse({
            "error": "No match found for barcode data",
            "plugin": none,
          }),
          isNull,
          reason: none,
        );
      }
      final e = PluginError.fromResponse({
        "error": ["Bad", "data"],
        "plugin": " LCSC ",
      })!;
      expect(e.plugin, "LCSC");
      expect(e.message, "Bad data");
    });

    test("Barcode data is sent as JSON, not in the URL", () async {
      await repo.resolveBarcode("a&b=c?d");
      expect(server.requests, contains("POST /api/barcode/"));
    });
  });

  group("Step 1 - scan part:", () {
    test("Confirm a resolved part", () async {
      await wf.scanPart("INV-SI1007");
      expect(wf.expected?.manufacturerPart.mpn, "RC0402-10K");
      expect(wf.step, WorkflowStep.scanPart);

      await wf.confirmPart();
      expect(wf.step, WorkflowStep.selectStock);
    });

    test("Data error cannot be confirmed", () async {
      await wf.scanPart("INV-SI1003");
      expect(wf.partScan, isA<ScanDataError>());
      expect(wf.expected, isNull);

      await wf.confirmPart();
      expect(wf.step, WorkflowStep.scanPart);
    });

    test("Ambiguous MPN requires a choice", () async {
      await wf.scanPart("DUP-1");
      expect(wf.expected, isNull);

      await wf.confirmPart();
      expect(wf.step, WorkflowStep.scanPart);

      wf.chooseExpected((wf.partScan as ScanAmbiguous).options[1]);
      expect(wf.expected?.manufacturerPart.pk, 104);
    });
  });

  group("Step 2 - select stock:", () {
    test("Scanning the empty reel again is an error", () async {
      await toStep2(); // empty reel #1007 (in the machine)
      await wf.verifyScan("INV-SI1007");
      expect(wf.selectionVerified, isFalse);
      expect(wf.verifyIsError, isTrue);
      expect(wf.verifyMessage, startsWith("SAME REEL"));
      expect(wf.verifyMessage, contains("#1007"));
      expect(wf.selected, isNull);
    });

    test("An empty reel still in the source location is not listed", () async {
      // InvenTree still has the empty reel #1000 in Stores
      await wf.scanPart("INV-SI1000");
      await wf.confirmPart();
      expect(wf.candidates.map((c) => c.item.pk), isNot(contains(1000)));

      await wf.verifyScan("INV-SI1000");
      expect(wf.verifyMessage, startsWith("SAME REEL"));
      expect(wf.selected, isNull);

      // A supplier label picks the only other reel with the MPN, not the empty one
      await wf.verifyScan("SUPPLIER:200");
      expect(wf.selectionVerified, isTrue);
      expect(wf.selected?.item.pk, 1001);
    });

    test(
      "Candidates: exact first, then alternates, then data errors; machine and other locations excluded",
      () async {
        await toStep2();

        expect(wf.exactCandidates.map((c) => c.item.pk), [1000, 1001]);
        expect(wf.alternateCandidates.map((c) => c.item.pk), [1002]);
        expect(wf.dataErrorCandidates.map((c) => c.item.pk), [1003, 1004]);
        // 1005 is elsewhere, 1006 is another part, 1007 is in the machine
        expect(wf.candidates.map((c) => c.item.pk), isNot(contains(1005)));
        expect(wf.candidates.map((c) => c.item.pk), isNot(contains(1006)));
        expect(wf.candidates.map((c) => c.item.pk), isNot(contains(1007)));
      },
    );

    test("Candidates carry manufacturer and supplier names", () async {
      await toStep2();

      StockItemInfo item(int pk) =>
          wf.candidates.firstWhere((c) => c.item.pk == pk).item;

      // Bought from a distributor
      expect(item(1000).manufacturerName, "Yageo");
      expect(item(1000).supplierName, "DigiKey");
      expect(item(1000).distinctSupplierName, "DigiKey");

      // Bought direct from the manufacturer - supplier not repeated
      expect(item(1002).manufacturerName, "Panasonic");
      expect(item(1002).supplierName, "Panasonic");
      expect(item(1002).distinctSupplierName, "");

      // No manufacturer part, but the supplier is known
      expect(item(1004).manufacturerName, "");
      expect(item(1004).supplierName, "DigiKey");

      // No supplier part at all
      expect(item(1003).manufacturerName, "");
      expect(item(1003).supplierName, "");

      // One extra request for all the names
      expect(
        server.requests.where((r) => r == "GET /api/company/part/").length,
        1,
      );
    });

    test("Candidates are still listed if the names cannot be loaded", () async {
      server.inventory.failSupplierPartList = true;
      await toStep2();

      expect(wf.stockError, isNull);
      expect(wf.exactCandidates.map((c) => c.item.pk), [1000, 1001]);
      expect(wf.exactCandidates.first.item.manufacturerName, "");
    });

    test("Supplier is only shown when different from the manufacturer", () {
      StockItemInfo item(String mfr, String supplier) => StockItemInfo(
        pk: 1,
        partId: 1,
        quantity: 1,
        manufacturerName: mfr,
        supplierName: supplier,
      );

      expect(item("Molex", "DigiKey").distinctSupplierName, "DigiKey");
      expect(item("Molex", "Molex").distinctSupplierName, "");
      expect(item("Molex", " molex ").distinctSupplierName, "");
      expect(item("Molex", "").distinctSupplierName, "");
      expect(item("", "DigiKey").distinctSupplierName, "DigiKey");
    });

    test("Data error reels cannot be selected", () async {
      await toStep2();
      wf.select(wf.dataErrorCandidates.first);
      expect(wf.selected, isNull);
    });

    test("Selection must be verified by scanning before confirming", () async {
      await toStep2();
      wf.select(wf.exactCandidates.first);

      wf.confirmSelection();
      expect(wf.step, WorkflowStep.selectStock);

      await wf.verifyScan("INV-SI1000");
      expect(wf.selectionVerified, isTrue);

      wf.confirmSelection();
      expect(wf.step, WorkflowStep.load);
    });

    test("Scanning a different listed reel selects it", () async {
      await toStep2();
      wf.select(wf.exactCandidates.first);

      await wf.verifyScan("INV-SI1001");
      expect(wf.selected?.item.pk, 1001);
      expect(wf.selectionVerified, isTrue);
      expect(wf.verifyMessage, contains("now selected"));
    });

    test("Scanning a reel without selecting first selects it", () async {
      await toStep2();
      await wf.verifyScan("INV-SI1002");
      expect(wf.selected?.item.pk, 1002);
      expect(wf.isAlternate, isTrue);
    });

    test("Wrong part is rejected", () async {
      await toStep2();
      wf.select(wf.exactCandidates.first);
      await wf.verifyScan("INV-SI1006");
      expect(wf.selectionVerified, isFalse);
      expect(wf.verifyMessage, contains("WRONG PART"));
    });

    test("Reel outside the source location is rejected", () async {
      await toStep2();
      await wf.verifyScan("INV-SI1005");
      expect(wf.selectionVerified, isFalse);
      expect(wf.verifyMessage, contains("not in Stores"));
    });

    test("Reel with no MPN link is a data error", () async {
      await toStep2();
      await wf.verifyScan("INV-SI1003");
      expect(wf.selectionVerified, isFalse);
      expect(wf.verifyIssue?.webPath, "web/stock/item/1003");
    });

    test("Supplier label must match the selected reel's MPN", () async {
      await toStep2();
      wf.select(wf.exactCandidates.first);

      await wf.verifyScan("SUPPLIER:201");
      expect(wf.selectionVerified, isFalse);

      await wf.verifyScan("SUPPLIER:200");
      expect(wf.selectionVerified, isTrue);
      expect(wf.verifyMessage, contains("not the individual reel"));
    });

    test(
      "Supplier label with several matching reels requires a selection",
      () async {
        await toStep2();
        await wf.verifyScan("SUPPLIER:200");
        expect(wf.selected, isNull);
        expect(wf.verifyMessage, contains("Several reels"));

        // Only one reel has the alternate MPN - selected automatically
        await wf.verifyScan("SUPPLIER:201");
        expect(wf.selected?.item.pk, 1002);
        expect(wf.selectionVerified, isTrue);
      },
    );

    test("Changing the selection clears verification", () async {
      await toStep2();
      wf.select(wf.exactCandidates.first);
      await wf.verifyScan("INV-SI1000");
      wf.select(wf.exactCandidates.last);
      expect(wf.selectionVerified, isFalse);
    });
  });

  group("Step 3 - load:", () {
    test("Quantity validation", () {
      expect(validateQuantity("100", 5000), isNull);
      expect(validateQuantity("5000", 5000), isNull);
      expect(validateQuantity("0", 5000), isNotNull);
      expect(validateQuantity("-1", 5000), isNotNull);
      expect(validateQuantity("5001", 5000), contains("more than"));
      expect(validateQuantity("1.5", 5000), contains("whole number"));
      expect(validateQuantity("1.5", 2.5), isNull);
      expect(validateQuantity("abc", 5000), isNotNull);
    });

    test("Full reel transfer", () async {
      await toStep3(1000);
      expect(wf.quantity, 5000);
      expect(wf.isPartial, isFalse);

      await wf.transfer();

      expect(wf.step, WorkflowStep.done, reason: wf.transferError);
      final t = server.inventory.transfers.single;
      expect(t["location"], 3);
      expect(t["items"], [
        {"pk": 1000, "quantity": 5000.0},
      ]);
      expect(t["notes"], contains("Expected MPN RC0402-10K"));
      expect(server.inventory.stock[1000]!["location"], 3);
    });

    test("Partial transfer splits the reel", () async {
      await toStep3(1000);
      wf.setQuantity(1200);
      expect(wf.isPartial, isTrue);

      await wf.transfer();

      expect(wf.step, WorkflowStep.done);
      expect(wf.transferredQuantity, 1200);
      expect(server.inventory.stock[1000]!["quantity"], 3800);
      expect(server.inventory.stock[1000]!["location"], 1);
      expect(
        server.inventory.transfers.single["notes"],
        contains("Partial quantity: 1200 of 5000"),
      );
    });

    test("Invalid quantity is ignored", () async {
      await toStep3(1000);
      wf.setQuantity(99999);
      expect(wf.quantity, 5000);
    });

    test("Alternate is recorded in the notes", () async {
      await toStep3(1002);
      await wf.transfer();
      expect(
        server.inventory.transfers.single["notes"],
        contains("ALTERNATE MPN confirmed"),
      );
    });

    test("Reel moved since listing - no transfer made", () async {
      await toStep3(1000);
      server.inventory.stock[1000]!["location"] = 4;

      await wf.transfer();

      expect(wf.step, WorkflowStep.load);
      expect(wf.transferError, contains("has been moved"));
      expect(server.inventory.transfers, isEmpty);
    });

    test("Quantity reduced since listing - no transfer made", () async {
      await toStep3(1000);
      server.inventory.stock[1000]!["quantity"] = 100.0;

      await wf.transfer();

      expect(wf.transferError, contains("only 100"));
      expect(server.inventory.transfers, isEmpty);
    });

    test("Rejected transfer shows an error and can be retried", () async {
      await toStep3(1000);
      server.inventory.rejectTransfersWithStatus = 403;

      await wf.transfer();
      expect(wf.step, WorkflowStep.load);
      expect(wf.transferError, contains("permission"));

      server.inventory.rejectTransfersWithStatus = null;
      await wf.transfer();
      expect(wf.step, WorkflowStep.done);
    });

    test(
      "Transfer applied but response lost - treated as done, not repeated",
      () async {
        await toStep3(1000);
        server.inventory.failTransferAfterApplying = true;

        await wf.transfer();

        expect(wf.step, WorkflowStep.done);
        expect(server.inventory.transfers.length, 1);
      },
    );
  });

  group("Reset:", () {
    test("Reset at each step returns to an empty step 1", () async {
      for (final int stage in [1, 2, 3, 4]) {
        wf.reset();
        if (stage >= 2) await toStep2();
        if (stage == 1) await wf.scanPart("INV-SI1007");
        if (stage >= 3) {
          wf.reset();
          await toStep3(1000);
        }
        if (stage == 4) await wf.transfer();

        wf.reset();

        expect(wf.step, WorkflowStep.scanPart, reason: "stage $stage");
        expect(wf.partScan, isNull);
        expect(wf.expected, isNull);
        expect(wf.selected, isNull);
        expect(wf.candidates, isEmpty);
        expect(wf.canReset, isFalse);
      }
    });

    test("Results of a request in flight during reset are discarded", () async {
      final Future<void> pending = wf.scanPart("INV-SI1007");
      wf.reset();
      await pending;

      expect(wf.partScan, isNull);
      expect(wf.busy, isFalse);
    });
  });

  group("Settings:", () {
    test("Location validation", () {
      const structural = StockLocationInfo(
        pk: 5,
        name: "S",
        pathstring: "S",
        structural: true,
      );
      const shelf = StockLocationInfo(
        pk: 2,
        name: "Shelf A",
        pathstring: "Stores/Shelf A",
      );

      expect(validateLocations(source, machine), isNull);
      expect(validateLocations(source, source), contains("different"));
      expect(validateLocations(source, shelf), contains("inside"));
      expect(validateLocations(source, structural), contains("structural"));
    });

    test("Settings are only restored for the same server", () async {
      final backend = MemorySettingsBackend();
      final store = SettingsStore(backend);

      await store.load("https://a.example.com/");
      await store.save(
        const WorkflowSettings(source: source, machine: machine),
      );

      final again = SettingsStore(backend);
      await again.load("https://a.example.com/");
      expect(again.settings.machine?.pk, 3);

      final other = SettingsStore(backend);
      await other.load("https://b.example.com/");
      expect(other.settings.isComplete, isFalse);
    });

    test("Location search", () async {
      final results = await repo.searchLocations("stores");
      expect(results.map((l) => l.pk), [1, 2]);
    });
  });
}
