/*
 * Widget tests for screens which need a connected session
 * (run against the fake InvenTree server).
 */

import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/app_log.dart";
import "package:inventree_smt/core/credential_store.dart";
import "package:inventree_smt/core/device.dart";
import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/ui/home_screen.dart";
import "package:inventree_smt/ui/settings_screen.dart";
import "package:inventree_smt/ui/workflow/done_step.dart";
import "package:inventree_smt/ui/workflow/select_stock_step.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

import "fake_inventree.dart";

class FakeDevice extends DeviceService {
  final List<bool> keepScreenOn = [];

  @override
  Future<void> setKeepScreenOn(bool on) async => keepScreenOn.add(on);

  @override
  Future<String> appVersion() async => "9.9.9 (99)";
}

const source = StockLocationInfo(pk: 1, name: "Stores", pathstring: "Stores");
const machine = StockLocationInfo(
  pk: 3,
  name: "SMT Line",
  pathstring: "SMT Line",
);

void main() {
  late FakeInvenTree server;
  late AuthService auth;
  late SettingsStore settings;
  late FakeDevice device;

  // Real HTTP to the local fake server (flutter_test blocks it by default)
  setUp(() => HttpOverrides.global = null);

  Future<void> connect(
    WidgetTester tester, {
    AppPreferences prefs = const AppPreferences(),
  }) async {
    await tester.runAsync(() async {
      server = await FakeInvenTree.start();
      auth = AuthService(store: MemoryCredentialStore());
      await auth.login(server.url, "reader", "secret");
      settings = SettingsStore(MemorySettingsBackend());
      await settings.load(server.url);
      await settings.save(
        const WorkflowSettings(source: source, machine: machine),
      );
      await settings.savePrefs(prefs);
    });
    device = FakeDevice();
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(auth: auth, settings: settings, device: device),
      ),
    );
    await settle(tester);
  }

  Future<void> typeBarcode(WidgetTester tester, String barcode) async {
    await tester.tap(find.text("TYPE BARCODE OR MPN"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), barcode);
    await tester.tap(find.text("OK"));
    await tester.pump();
    await settle(tester);
  }

  tearDown(() async => server.close());

  /// Requests made from taps run on the test's fake clock - close the HTTP
  /// client so its idle-connection timers do not outlive the test.
  Future<void> finish(WidgetTester tester) async {
    auth.api.close();
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets("A deleted location is reported on startup", (tester) async {
    await connect(tester);
    server.inventory.locations.remove(3);

    await pumpHome(tester);

    expect(find.byKey(const Key("location-problems")), findsOneWidget);
    expect(
      find.textContaining("\"SMT Line\" no longer exists"),
      findsOneWidget,
    );
    expect(find.text("CONFIGURE LOCATIONS"), findsOneWidget);
    expect(find.text("SCAN PART"), findsNothing);
    await finish(tester);
  });

  testWidgets("Valid locations go straight to the workflow", (tester) async {
    await connect(tester);
    await pumpHome(tester);

    expect(find.byKey(const Key("location-problems")), findsNothing);
    expect(find.text("SCAN PART"), findsOneWidget);
    await finish(tester);
  });

  testWidgets("Every step has the same action heading at the top left", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await connect(tester, prefs: const AppPreferences(autoReturn: false));
    await pumpHome(tester);

    Rect? first;
    TextStyle? firstStyle;
    final List<String> titles = [];

    void checkHeading() {
      final Finder heading = find.byKey(const Key("step-action"));
      expect(heading, findsOneWidget);
      final Rect box = tester.getRect(heading);
      final Text text = tester.widget<Text>(heading);
      titles.add(text.data!);
      expect(text.textAlign, TextAlign.start, reason: text.data);
      first ??= box;
      firstStyle ??= text.style;
      expect(box.left, first!.left, reason: text.data);
      expect(box.top, first!.top, reason: text.data);
      expect(text.style, firstStyle, reason: text.data);
    }

    checkHeading(); // step 1 start

    await typeBarcode(tester, "INV-SI1007");
    checkHeading(); // step 1 check part

    await tester.tap(find.text("CONFIRM PART"));
    await settle(tester);
    checkHeading(); // step 2 select

    await tester.tap(find.byKey(const Key("candidate-1000")));
    await tester.pump();
    checkHeading(); // step 2 scan selected

    // (Scanning opens the camera - drive the verification directly)
    final LoadWorkflow wf = tester
        .widget<SelectStockStep>(find.byType(SelectStockStep))
        .workflow;
    await tester.runAsync(() => wf.verifyScan("INV-SI1000"));
    await tester.pump();
    checkHeading(); // step 2 confirm

    await tester.tap(find.text("CONFIRM REEL"));
    await tester.pump();
    checkHeading(); // step 3

    await tester.tap(find.text("TRANSFER INTO MACHINE"));
    await settle(tester);
    checkHeading(); // done

    expect(titles, [
      "Scan Empty Reel",
      "Check Part",
      "Select Replacement Reel",
      "Scan Selected Reel",
      "Confirm Reel",
      "Load Into Machine",
      "Transfer Complete",
    ]);
    await finish(tester);
  });

  testWidgets("Missing permissions block the workflow", (tester) async {
    await tester.runAsync(() async {
      server = await FakeInvenTree.start();
      server.roles = {
        "part": ["view"],
        "stock": ["view"],
        "stock_location": ["view"],
      };
      auth = AuthService(store: MemoryCredentialStore());
      await auth.login(server.url, "reader", "secret");
      settings = SettingsStore(MemorySettingsBackend());
      await settings.load(server.url);
      await settings.save(
        const WorkflowSettings(source: source, machine: machine),
      );
    });
    device = FakeDevice();
    await pumpHome(tester);

    expect(find.text("PERMISSION REQUIRED"), findsOneWidget);
    expect(find.textContaining("Stock - change"), findsOneWidget);
    expect(find.text("SCAN PART"), findsNothing);
    expect(find.byKey(const Key("reset-workflow")), findsNothing);
    expect(find.byKey(const Key("workflow-progress")), findsNothing);
    // Settings (e.g. to log out) are still available
    expect(find.byKey(const Key("open-settings")), findsOneWidget);
    await finish(tester);
  });

  testWidgets("Screen is kept on only while a swap is active", (tester) async {
    await connect(tester);
    await pumpHome(tester);

    expect(find.text("SCAN PART"), findsOneWidget);
    expect(device.keepScreenOn, isEmpty);

    await typeBarcode(tester, "INV-SI1007");
    expect(find.text("CONFIRM PART"), findsOneWidget);
    expect(device.keepScreenOn, [true]);

    await tester.tap(find.byKey(const Key("reset-workflow")));
    await tester.pump();
    expect(device.keepScreenOn, [true, false]);
    await finish(tester);
  });

  testWidgets("Keep-screen-on can be turned off", (tester) async {
    await connect(tester, prefs: const AppPreferences(keepScreenOn: false));
    await pumpHome(tester);

    await typeBarcode(tester, "INV-SI1007");
    expect(find.text("CONFIRM PART"), findsOneWidget);
    expect(device.keepScreenOn, isEmpty);
    await finish(tester);
  });

  group("Done screen:", () {
    late LoadWorkflow workflow;

    Future<void> transferred(WidgetTester tester) async {
      await connect(tester);
      await tester.runAsync(() async {
        workflow = LoadWorkflow(
          repo: InvenTreeRepository(auth.api),
          settings: settings.settings,
        );
        await workflow.scanPart("INV-SI1007");
        await workflow.confirmPart();
        await workflow.verifyScan("INV-SI1000");
        workflow.confirmSelection();
        await workflow.transfer();
      });
      expect(workflow.step, WorkflowStep.done);
    }

    Widget host(bool autoReturn) => MaterialApp(
      home: Scaffold(
        body: DoneStep(workflow: workflow, autoReturn: autoReturn),
      ),
    );

    testWidgets("Returns to step 1 after 5 seconds", (tester) async {
      await transferred(tester);
      await tester.pumpWidget(host(true));

      expect(find.text("Returning to start in 5 s"), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text("Returning to start in 2 s"), findsOneWidget);
      expect(workflow.step, WorkflowStep.done);

      await tester.pump(const Duration(seconds: 2));
      expect(workflow.step, WorkflowStep.scanPart);
    });

    testWidgets("'Stay' cancels the countdown", (tester) async {
      await transferred(tester);
      await tester.pumpWidget(host(true));

      await tester.tap(find.byKey(const Key("auto-return-stay")));
      await tester.pump(const Duration(seconds: 10));
      expect(workflow.step, WorkflowStep.done);
      expect(find.byKey(const Key("auto-return-countdown")), findsNothing);
    });

    testWidgets("No countdown when the option is off", (tester) async {
      await transferred(tester);
      await tester.pumpWidget(host(false));

      expect(find.byKey(const Key("auto-return-countdown")), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(workflow.step, WorkflowStep.done);
    });
  });

  testWidgets("Settings screen: sections, preferences, log", (tester) async {
    // Phone-sized screen (Pixel 9: 1080 x 2424 px)
    tester.view.physicalSize = const Size(1080, 2424);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await connect(tester);
    final log = AppLog()..error("test", "Something went wrong");

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          store: settings,
          repo: InvenTreeRepository(auth.api),
          auth: auth,
          device: device,
          log: log,
        ),
      ),
    );
    await settle(tester);

    for (final title in ["Locations", "Workflow"]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text("Stores"), findsOneWidget);
    expect(find.text("SMT Line"), findsOneWidget);

    // Toggle auto-return off - saved immediately
    await tester.tap(find.byKey(const Key("pref-auto-return")));
    await settle(tester);
    expect(settings.prefs.autoReturn, isFalse);

    await tester.ensureVisible(find.byKey(const Key("pref-keep-screen-on")));
    await tester.tap(find.byKey(const Key("pref-keep-screen-on")));
    await settle(tester);
    expect(settings.prefs.keepScreenOn, isFalse);

    // Lower sections
    await tester.scrollUntilVisible(
      find.text("9.9.9 (99)"),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text("reader (Test User)"), findsOneWidget);
    expect(find.textContaining("1 errors"), findsOneWidget);
    expect(find.byKey(const Key("settings-logout")), findsOneWidget);

    // Open the log
    await tester.tap(find.byKey(const Key("settings-view-log")));
    await tester.pumpAndSettle();
    expect(find.text("Something went wrong"), findsOneWidget);
    await finish(tester);
  });
}
