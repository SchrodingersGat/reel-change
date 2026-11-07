import "package:flutter/foundation.dart";

import "package:inventree_smt/core/app_log.dart";
import "package:inventree_smt/core/settings_store.dart";
import "package:inventree_smt/inventree/inventree_repository.dart";
import "package:inventree_smt/inventree/models.dart";

enum WorkflowStep {
  /// 1. Scan the empty reel and confirm the part / MPN.
  scanPart,

  /// 2. Choose a replacement reel from stock, and verify it by scanning.
  selectStock,

  /// 3. Review, adjust quantity, and transfer into the machine.
  load,

  /// Transfer complete.
  done,
}

/// Validate a quantity typed by the user. Returns an error, or null if OK.
///
/// Whole numbers are required when the stock quantity is a whole number
/// (e.g. reels of components); fractional quantities are allowed otherwise.
String? validateQuantity(String text, double available) {
  final double? q = double.tryParse(text.trim());

  if (q == null || q.isNaN || q.isInfinite) return "Enter a number.";
  if (q <= 0) return "Quantity must be greater than zero.";
  if (q > available + 1e-9) {
    return "Cannot move more than ${formatQuantity(available)} (the quantity in stock).";
  }
  if (available == available.roundToDouble() && q != q.roundToDouble()) {
    return "Enter a whole number.";
  }

  return null;
}

/// State for one reel swap: scan part -> select stock -> load into machine.
///
/// The UI shows exactly one step at a time, driven by [step].
/// [reset] can be called at any time; any request still in flight is ignored.
class LoadWorkflow extends ChangeNotifier {
  LoadWorkflow({required this.repo, required this.settings});

  final InvenTreeRepository repo;

  /// Source / machine locations (must be complete before starting).
  WorkflowSettings settings;

  StockLocationInfo get source => settings.source!;
  StockLocationInfo get machine => settings.machine!;

  // Incremented on reset - results of requests started before a reset are discarded
  int _generation = 0;

  WorkflowStep _step = WorkflowStep.scanPart;
  WorkflowStep get step => _step;

  bool _busy = false;
  bool get busy => _busy;

  String _busyMessage = "";
  String get busyMessage => _busyMessage;

  // --- Step 1 ---------------------------------------------------------------

  ScanOutcome? _partScan;

  /// Result of the last part scan (null until something is scanned).
  ScanOutcome? get partScan => _partScan;

  ResolvedPart? _expected;

  /// The part / MPN being loaded. Set once the scan resolves to a single MPN
  /// (or the user picks one of several); confirmed by [confirmPart].
  ResolvedPart? get expected => _expected;

  // --- Step 2 ---------------------------------------------------------------

  List<StockCandidate> _candidates = [];
  List<StockCandidate> get candidates => _candidates;

  String? _stockError;
  String? get stockError => _stockError;

  StockCandidate? _selected;
  StockCandidate? get selected => _selected;

  bool _verified = false;

  /// The selected reel has been confirmed by scanning its label.
  bool get selectionVerified => _verified;

  String _verifyMessage = "";
  String get verifyMessage => _verifyMessage;

  bool _verifyIsError = false;
  bool get verifyIsError => _verifyIsError;

  DataIssue? _verifyIssue;

  /// Set if the verification scan hit a data problem.
  DataIssue? get verifyIssue => _verifyIssue;

  bool get isAlternate => _selected?.kind == CandidateKind.alternate;

  List<StockCandidate> get exactCandidates =>
      _candidates.where((c) => c.kind == CandidateKind.exact).toList();
  List<StockCandidate> get alternateCandidates =>
      _candidates.where((c) => c.kind == CandidateKind.alternate).toList();
  List<StockCandidate> get dataErrorCandidates =>
      _candidates.where((c) => c.kind == CandidateKind.dataError).toList();

  // --- Step 3 ---------------------------------------------------------------

  double _quantity = 0;
  double get quantity => _quantity;

  String? _transferError;
  String? get transferError => _transferError;

  bool get isPartial =>
      _selected != null && _quantity < _selected!.item.quantity - 1e-9;

  // --- Done -----------------------------------------------------------------

  double _transferredQuantity = 0;
  double get transferredQuantity => _transferredQuantity;

  /// Anything to reset?
  bool get canReset => _step != WorkflowStep.scanPart || _partScan != null;

  int get stepNumber => switch (_step) {
    WorkflowStep.scanPart => 1,
    WorkflowStep.selectStock => 2,
    WorkflowStep.load => 3,
    WorkflowStep.done => 4,
  };

  void _setBusy(bool busy, [String message = ""]) {
    _busy = busy;
    _busyMessage = message;
    notifyListeners();
  }

  /// Run [action] unless busy; drop its effects if a reset happens meanwhile.
  Future<void> _run(
    String message,
    Future<void> Function(bool Function() stale) action,
  ) async {
    if (_busy) return;

    final int generation = _generation;
    bool stale() => generation != _generation;

    _setBusy(true, message);

    try {
      await action(stale);
    } catch (e) {
      // Unexpected (e.g. malformed server data) - report it on the current step
      if (!stale()) {
        final String message = e is ApiException
            ? e.message
            : "Unexpected error: $e";
        appLog.error("workflow", message);
        switch (_step) {
          case WorkflowStep.scanPart:
            _partScan = ScanFailed(message);
            _expected = null;
          case WorkflowStep.selectStock:
            if (_candidates.isEmpty) {
              _stockError = message;
            } else {
              _verifyFail(message);
            }
          case WorkflowStep.load:
          case WorkflowStep.done:
            _transferError = message;
        }
      }
    } finally {
      if (!stale()) _setBusy(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Step 1: scan part
  // ---------------------------------------------------------------------------

  Future<void> scanPart(String barcode) =>
      _run("Looking up barcode...", (stale) async {
        appLog.info("workflow", "Step 1: scanned ${logSnippet(barcode)}");
        final ScanOutcome outcome = await repo.resolveBarcode(barcode);
        if (stale()) return;

        _logOutcome("Step 1", outcome);
        _partScan = outcome;
        _expected = outcome is ScanResolved ? outcome.result : null;
      });

  /// Choose one of several manufacturer parts which share the scanned MPN.
  void chooseExpected(ResolvedPart option) {
    if (_step != WorkflowStep.scanPart || _partScan is! ScanAmbiguous) return;
    _expected = option;
    notifyListeners();
  }

  /// Discard the part scan, to scan again.
  void clearPartScan() {
    if (_busy || _step != WorkflowStep.scanPart) return;
    _partScan = null;
    _expected = null;
    notifyListeners();
  }

  /// The user has checked the part against the SMT machine - move to step 2.
  Future<void> confirmPart() async {
    if (_busy || _step != WorkflowStep.scanPart || _expected == null) return;
    appLog.info(
      "workflow",
      "Step 1: confirmed MPN ${_expected!.manufacturerPart.mpn} (${_expected!.part.displayName})",
    );
    _step = WorkflowStep.selectStock;
    notifyListeners();
    await loadCandidates();
  }

  // ---------------------------------------------------------------------------
  // Step 2: select stock
  // ---------------------------------------------------------------------------

  Future<void> loadCandidates() => _run("Loading stock...", (stale) async {
    final ResolvedPart? expected = _expected;
    if (expected == null) return;

    _stockError = null;

    try {
      final list = await repo.stockCandidates(
        partId: expected.part.pk,
        expectedMpPk: expected.manufacturerPart.pk,
        source: source,
        machine: machine,
      );
      if (stale()) return;

      _candidates = list;
      appLog.info(
        "workflow",
        "Step 2: ${list.where((c) => c.kind == CandidateKind.exact).length} exact, "
            "${list.where((c) => c.kind == CandidateKind.alternate).length} alternate, "
            "${list.where((c) => c.kind == CandidateKind.dataError).length} needing a data fix "
            "in ${source.pathstring}",
      );
      for (final c in list.where((c) => c.kind == CandidateKind.dataError)) {
        appLog.error(
          "data",
          "Reel #${c.item.pk} in ${c.item.locationPath} has no MPN link "
              "(${c.item.supplierPartId == null ? "no supplier part" : "supplier part #${c.item.supplierPartId} has no manufacturer part"})",
        );
      }

      // Keep the selection if the reel is still listed
      if (_selected != null) {
        final int pk = _selected!.item.pk;
        final matches = list.where((c) => c.item.pk == pk && c.selectable);
        _selected = matches.isEmpty ? null : matches.first;
        if (_selected == null) _clearVerification();
      }
    } on ApiException catch (e) {
      if (stale()) return;
      appLog.error("workflow", "Step 2: could not load stock - ${e.message}");
      _stockError = e.message;
    }
  });

  void _clearVerification() {
    _verified = false;
    _verifyMessage = "";
    _verifyIsError = false;
    _verifyIssue = null;
  }

  void select(StockCandidate candidate) {
    if (_busy || _step != WorkflowStep.selectStock || !candidate.selectable) {
      return;
    }
    if (_selected?.item.pk == candidate.item.pk) return;

    _selected = candidate;
    _clearVerification();
    notifyListeners();
  }

  void _verifyFail(String message, [DataIssue? issue]) {
    appLog.warning("workflow", "Step 2: not verified - $message");
    _verified = false;
    _verifyIsError = true;
    _verifyMessage = message;
    _verifyIssue = issue;
  }

  void _verifyOk(String message) {
    appLog.info("workflow", "Step 2: $message");
    _verified = true;
    _verifyIsError = false;
    _verifyMessage = message;
    _verifyIssue = null;
  }

  void _logOutcome(String step, ScanOutcome outcome) {
    switch (outcome) {
      case ScanResolved(:final result):
        appLog.info(
          "workflow",
          "$step: resolved to MPN ${result.manufacturerPart.mpn} "
              "(${result.part.displayName}${result.stockItem == null ? "" : ", reel #${result.stockItem!.pk}"})",
        );
      case ScanAmbiguous(:final options):
        appLog.warning(
          "workflow",
          "$step: MPN ${options.first.manufacturerPart.mpn} matches ${options.length} manufacturer parts",
        );
      case ScanDataError(:final issue):
        appLog.error(
          "data",
          "${issue.title}: ${issue.detail} [${issue.webPath}]",
        );
      case ScanNotFound(:final message):
        appLog.warning("workflow", "$step: $message");
      case ScanFailed(:final message):
        appLog.error("workflow", "$step: lookup failed - $message");
    }
  }

  String _describe(ResolvedPart p) =>
      "${p.part.displayName} (MPN ${p.manufacturerPart.mpn})";

  /// Verify the physical reel by scanning its label.
  ///
  /// - InvenTree stock label: must be a selectable reel in the list. If it is a
  ///   different reel to the one selected, that reel is selected instead.
  /// - Supplier / manufacturer label: identifies the MPN but not the specific
  ///   reel, so it must match the selected reel's MPN.
  Future<void> verifyScan(String barcode) => _run("Checking reel...", (
    stale,
  ) async {
    final ResolvedPart? expected = _expected;
    if (_step != WorkflowStep.selectStock || expected == null) return;

    appLog.info("workflow", "Step 2: scanned ${logSnippet(barcode)}");
    final ScanOutcome outcome = await repo.resolveBarcode(barcode);
    if (stale()) return;

    _logOutcome("Step 2", outcome);

    switch (outcome) {
      case ScanFailed(:final message):
        _verifyFail(message);

      case ScanNotFound(:final message):
        _verifyFail(message);

      case ScanDataError(:final issue):
        _verifyFail(issue.title, issue);

      case ScanAmbiguous(:final options):
        final int? mp = _selected?.item.manufacturerPartId;
        final match = options.where((o) => o.manufacturerPart.pk == mp);
        if (match.isNotEmpty) {
          _verifyLabel(match.first);
        } else {
          _verifyFail(
            _selected == null
                ? "Select the reel from the list first, then scan its label."
                : "The scanned label does not match the selected reel's MPN.",
          );
        }

      case ScanResolved(:final result):
        final StockItemInfo? scannedItem = result.stockItem;

        if (scannedItem != null) {
          _verifyStockLabel(result, scannedItem, expected);
        } else {
          _verifyLabel(result);
        }
    }
  });

  void _verifyStockLabel(
    ResolvedPart result,
    StockItemInfo scanned,
    ResolvedPart expected,
  ) {
    final listed = _candidates.where(
      (c) => c.item.pk == scanned.pk && c.selectable,
    );

    if (listed.isNotEmpty) {
      final bool switched =
          _selected != null && _selected!.item.pk != scanned.pk;
      _selected = listed.first;
      _verifyOk(
        switched
            ? "You scanned reel ${scanned.label} - it is now selected and verified."
            : "Reel ${scanned.label} verified.",
      );
      return;
    }

    if (result.part.pk != expected.part.pk) {
      _verifyFail(
        "WRONG PART. The scanned reel is ${_describe(result)}. Expected ${_describe(expected)}.",
      );
    } else if (!scanned.inStock || scanned.quantity <= 0) {
      _verifyFail("Reel ${scanned.label} is not in stock in InvenTree.");
    } else if (scanned.locationId == machine.pk) {
      _verifyFail("Reel ${scanned.label} is already in the machine location.");
    } else {
      _verifyFail(
        "Reel ${scanned.label} is not in ${source.pathstring}"
        "${scanned.locationPath.isEmpty ? "" : " (InvenTree says it is in ${scanned.locationPath})"}. "
        "Only reels from the source location can be loaded.",
      );
    }
  }

  /// A label which identifies an MPN but not an individual reel.
  void _verifyLabel(ResolvedPart result) {
    final StockCandidate? selected = _selected;
    final int mp = result.manufacturerPart.pk;

    if (selected == null) {
      // Auto-select if exactly one reel has this MPN
      final matching = _candidates
          .where((c) => c.selectable && c.item.manufacturerPartId == mp)
          .toList();

      if (matching.length == 1) {
        _selected = matching.single;
        _verifyOk(
          "Label matches MPN ${result.manufacturerPart.mpn}. Reel ${_selected!.item.label} selected "
          "(the only reel with this MPN). This label type identifies the part, not the reel.",
        );
      } else if (matching.isEmpty) {
        _verifyFail(_mismatchMessage(result));
      } else {
        _verifyFail(
          "Several reels have MPN ${result.manufacturerPart.mpn}. Select the one you have from the list, then scan again.",
        );
      }
      return;
    }

    if (selected.item.manufacturerPartId == mp) {
      _verifyOk(
        "Label matches MPN ${result.manufacturerPart.mpn}. This label type identifies the part, "
        "not the individual reel. Make sure you have reel ${selected.item.label}.",
      );
    } else {
      _verifyFail(_mismatchMessage(result));
    }
  }

  String _mismatchMessage(ResolvedPart scanned) {
    final ResolvedPart expected = _expected!;

    if (scanned.part.pk != expected.part.pk) {
      return "WRONG PART. The scanned label is ${_describe(scanned)}. Expected ${_describe(expected)}.";
    }

    final String selectedMpn =
        _selected?.item.mpn ?? expected.manufacturerPart.mpn;
    return "The scanned label is MPN ${scanned.manufacturerPart.mpn}, which does not match the "
        "selected reel (MPN $selectedMpn).";
  }

  /// Confirm the selected, verified reel - move to step 3.
  /// For an alternate MPN, the UI must have obtained explicit confirmation first.
  void confirmSelection() {
    if (_busy || _step != WorkflowStep.selectStock) return;
    final StockCandidate? selected = _selected;
    if (selected == null || !_verified) return;

    _quantity = selected.item.quantity;
    _transferError = null;
    appLog.info(
      "workflow",
      "Step 2: confirmed reel #${selected.item.pk} (MPN ${selected.item.mpn}"
          "${isAlternate ? ", ALTERNATE confirmed by operator" : ""})",
    );
    _step = WorkflowStep.load;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Step 3: load into machine
  // ---------------------------------------------------------------------------

  /// Set the quantity to move (validate first with [validateQuantity]).
  void setQuantity(double quantity) {
    final StockCandidate? selected = _selected;
    if (_step != WorkflowStep.load || selected == null) return;
    if (validateQuantity("$quantity", selected.item.quantity) != null) return;

    _quantity = quantity;
    appLog.info(
      "workflow",
      "Step 3: quantity set to ${formatQuantity(quantity)}",
    );
    notifyListeners();
  }

  String _notes() {
    final ResolvedPart expected = _expected!;
    final StockItemInfo item = _selected!.item;

    final buffer = StringBuffer(
      "SMT reel load (SMT Reel Loader app). Expected MPN ${expected.manufacturerPart.mpn}",
    );
    if (expected.manufacturerPart.manufacturerName.isNotEmpty) {
      buffer.write(" (${expected.manufacturerPart.manufacturerName})");
    }
    buffer.write(", loaded MPN ${item.mpn}.");

    if (isAlternate) buffer.write(" ALTERNATE MPN confirmed by operator.");
    if (isPartial) {
      buffer.write(
        " Partial quantity: ${formatQuantity(_quantity)} of ${formatQuantity(item.quantity)}.",
      );
    }

    return buffer.toString();
  }

  /// Transfer the selected reel into the machine location.
  ///
  /// The stock item is re-checked first; if anything changed since it was
  /// listed, the transfer is not made.
  Future<void> transfer() => _run("Transferring...", (stale) async {
    final StockCandidate? selected = _selected;
    if (_step != WorkflowStep.load || selected == null || _expected == null) {
      return;
    }

    _transferError = null;

    final StockItemInfo listed = selected.item;
    final double q = _quantity;

    final StockItemInfo before;

    try {
      before = await repo.getStockItem(listed.pk);
    } on ApiException catch (e) {
      if (!stale()) {
        appLog.error("workflow", "Step 3: ${e.message}");
        _transferError = e.message;
      }
      return;
    }

    if (stale()) return;

    final String? changed = _changedSinceListed(listed, before, q);
    if (changed != null) {
      appLog.warning("workflow", "Step 3: transfer not made - $changed");
      _transferError = changed;
      return;
    }

    try {
      await repo.transfer(
        stockItemPk: listed.pk,
        quantity: q,
        location: machine.pk,
        notes: _notes(),
      );
    } on ApiException catch (e) {
      // The request may have reached the server even though no (valid) response
      // came back - check before reporting a failure, so it is not repeated.
      if (stale()) return;
      if (!await _transferHappened(listed.pk, before, q)) {
        if (!stale()) {
          appLog.error("workflow", "Step 3: ${e.message}");
          _transferError = e.message;
        }
        return;
      }
    }

    if (stale()) return;

    appLog.info(
      "workflow",
      "Step 3: transferred ${formatQuantity(q)} of reel #${listed.pk} into ${machine.pathstring}",
    );
    _transferredQuantity = q;
    _step = WorkflowStep.done;
  });

  String? _changedSinceListed(
    StockItemInfo listed,
    StockItemInfo now,
    double q,
  ) {
    if (now.partId != listed.partId ||
        now.manufacturerPartId != listed.manufacturerPartId) {
      return "Reel ${listed.label} has changed in InvenTree (different part or MPN). Reset and start again.";
    }
    if (!now.inStock || now.quantity <= 0) {
      return "Reel ${listed.label} is no longer in stock in InvenTree. Reset and start again.";
    }
    if (now.locationId != listed.locationId) {
      return "Reel ${listed.label} has been moved since it was listed "
          "(now in ${now.locationPath.isEmpty ? "another location" : now.locationPath}). Reset and start again.";
    }
    if (now.quantity + 1e-9 < q) {
      return "Reel ${listed.label} now has only ${formatQuantity(now.quantity)} in stock - "
          "less than the ${formatQuantity(q)} to move. Adjust the quantity.";
    }
    return null;
  }

  Future<bool> _transferHappened(int pk, StockItemInfo before, double q) async {
    try {
      final StockItemInfo after = await repo.getStockItem(pk);
      if (after.locationId == machine.pk) return true;
      return after.quantity <= before.quantity - q + 1e-9;
    } on ApiException {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Reset
  // ---------------------------------------------------------------------------

  /// Abandon the current swap and return to step 1. Safe at any time.
  void reset() {
    if (canReset) appLog.info("workflow", "Reset (was at ${_step.name})");
    _generation++;

    _step = WorkflowStep.scanPart;
    _busy = false;
    _busyMessage = "";
    _partScan = null;
    _expected = null;
    _candidates = [];
    _stockError = null;
    _selected = null;
    _clearVerification();
    _quantity = 0;
    _transferError = null;
    _transferredQuantity = 0;

    notifyListeners();
  }
}
