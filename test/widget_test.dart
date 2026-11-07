import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:inventree_smt/app.dart";
import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/credential_store.dart";
import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/inventree/models.dart";
import "package:inventree_smt/scanner/scanner_page.dart";
import "package:inventree_smt/ui/home_screen.dart";
import "package:inventree_smt/ui/splash_screen.dart";
import "package:inventree_smt/ui/workflow/widgets.dart";
import "package:inventree_smt/workflow/load_workflow.dart";

void main() {
  testWidgets("No stored login - shows the login screen", (tester) async {
    final auth = AuthService(store: MemoryCredentialStore());

    await tester.pumpWidget(
      SmtApp(auth: auth, settings: SettingsStore(MemorySettingsBackend())),
    );
    await tester.runAsync(auth.restore);
    await tester.pump();

    expect(find.text("Log in to InvenTree"), findsOneWidget);
    expect(find.text("Server address"), findsOneWidget);
    expect(find.text("Username"), findsOneWidget);
    expect(find.text("Password"), findsOneWidget);
    expect(find.text("LOG IN"), findsOneWidget);
  });

  testWidgets("Stored username is pre-filled", (tester) async {
    final store = MemoryCredentialStore()
      ..profile = const ServerProfile(
        server: "https://inventree.example.com/",
        username: "reader",
      );
    final auth = AuthService(store: store);

    await tester.pumpWidget(
      SmtApp(auth: auth, settings: SettingsStore(MemorySettingsBackend())),
    );
    await tester.runAsync(auth.restore);
    await tester.pump();

    expect(find.text("reader"), findsOneWidget);
    expect(find.text("https://inventree.example.com/"), findsOneWidget);
  });

  testWidgets("Plain HTTP to a remote host shows a warning", (tester) async {
    final auth = AuthService(store: MemoryCredentialStore());

    await tester.pumpWidget(
      SmtApp(auth: auth, settings: SettingsStore(MemorySettingsBackend())),
    );
    await tester.runAsync(auth.restore);
    await tester.pump();

    await tester.enterText(
      find.byType(TextField).first,
      "http://inventree.local",
    );
    await tester.pump();
    expect(find.textContaining("Unencrypted"), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).first,
      "http://localhost:8000",
    );
    await tester.pump();
    expect(find.textContaining("Unencrypted"), findsNothing);
  });

  testWidgets("Login status banner", (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LoginStatusBanner(
            info: ConnectionInfo(
              server: "http://localhost:8000/",
              username: "allaccess",
              serverVersion: "1.8.0 dev",
            ),
          ),
        ),
      ),
    );

    expect(
      find.text(
        "Logged in as allaccess  ·  localhost:8000  ·  InvenTree 1.8.0 dev",
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  group("Workflow screens:", () {
    Future<void> pumpHome(
      WidgetTester tester, {
      required bool configured,
    }) async {
      final backend = MemorySettingsBackend();
      if (configured) {
        // Settings for the (unconfigured, empty) server address used here
        final store = SettingsStore(backend);
        await tester.runAsync(() => store.load(""));
        await tester.runAsync(
          () => store.save(
            const WorkflowSettings(
              source: StockLocationInfo(
                pk: 1,
                name: "Stores",
                pathstring: "Stores",
              ),
              machine: StockLocationInfo(
                pk: 3,
                name: "SMT Line",
                pathstring: "SMT Line",
              ),
            ),
          ),
        );
      }

      final auth = AuthService(store: MemoryCredentialStore());
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(auth: auth, settings: SettingsStore(backend)),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    testWidgets("Locations must be configured first", (tester) async {
      await pumpHome(tester, configured: false);

      expect(find.text("CONFIGURE LOCATIONS"), findsOneWidget);
      expect(find.text("SCAN PART"), findsNothing);
      expect(find.byKey(const Key("workflow-progress")), findsNothing);
    });

    testWidgets("Step 1 start: scan button, progress bar, reset disabled", (
      tester,
    ) async {
      await pumpHome(tester, configured: true);

      expect(find.text("SCAN PART"), findsOneWidget);
      expect(find.text("TYPE BARCODE OR MPN"), findsOneWidget);
      expect(find.byKey(const Key("workflow-progress")), findsOneWidget);
      expect(find.text("Scan part"), findsOneWidget);
      expect(find.text("Select reel"), findsOneWidget);
      expect(find.text("Load"), findsOneWidget);

      final TextButton reset = tester.widget(
        find.byKey(const Key("reset-workflow")),
      );
      expect(reset.onPressed, isNull);
    });
  });

  testWidgets("Progress bar marks completed steps", (tester) async {
    for (final step in WorkflowStep.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WorkflowProgressBar(step: step)),
        ),
      );
      final int done = find.byIcon(Icons.check).evaluate().length;
      expect(done, step.index, reason: step.name);
    }
  });

  testWidgets("Manual barcode entry returns the typed value", (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await enterBarcodeManually(context, title: "Scan"),
            child: const Text("open"),
          ),
        ),
      ),
    );

    for (final submit in ["OK", "CANCEL"]) {
      result = null;
      await tester.tap(find.text("open"));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), "  INV-SI330 ");
      await tester.tap(find.text(submit));
      await tester.pumpAndSettle();
      expect(result, submit == "OK" ? "INV-SI330" : null);
      expect(find.byType(AlertDialog), findsNothing);
    }
  });

  testWidgets("Splash screen shows the logo", (tester) async {
    final auth = AuthService(store: MemoryCredentialStore());
    await tester.pumpWidget(MaterialApp(home: SplashScreen(auth: auth)));

    final Image logo = tester.widget(find.byKey(const Key("splash-logo")));
    expect((logo.image as AssetImage).assetName, "assets/images/logo.png");
  });
}
