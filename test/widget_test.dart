import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:inventree_smt/app.dart";
import "package:inventree_smt/auth/auth_service.dart";
import "package:inventree_smt/core/credential_store.dart";
import "package:inventree_smt/ui/home_screen.dart";

void main() {
  testWidgets("No stored login - shows the login screen", (tester) async {
    final auth = AuthService(store: MemoryCredentialStore());

    await tester.pumpWidget(SmtApp(auth: auth));
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

    await tester.pumpWidget(SmtApp(auth: auth));
    await tester.runAsync(auth.restore);
    await tester.pump();

    expect(find.text("reader"), findsOneWidget);
    expect(find.text("https://inventree.example.com/"), findsOneWidget);
  });

  testWidgets("Plain HTTP to a remote host shows a warning", (tester) async {
    final auth = AuthService(store: MemoryCredentialStore());

    await tester.pumpWidget(SmtApp(auth: auth));
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

    expect(find.text("Logged in as allaccess"), findsOneWidget);
    expect(find.text("localhost:8000  ·  InvenTree 1.8.0 dev"), findsOneWidget);
  });
}
