import "package:inventree_smt/auth/allauth_client.dart";
import "package:inventree_smt/core/api_client.dart";
import "package:inventree_smt/inventree/models.dart";

/// Longest barcode payload accepted (anything longer is not a part label).
const int kMaxBarcodeLength = 4096;

/// A part identified down to an exact manufacturer part (MPN).
class ResolvedPart {
  const ResolvedPart({
    required this.part,
    required this.manufacturerPart,
    this.stockItem,
  });

  final PartInfo part;
  final ManufacturerPartInfo manufacturerPart;

  /// Set when the barcode was an InvenTree stock item label.
  final StockItemInfo? stockItem;
}

/// A problem with the data in InvenTree which must be fixed there.
class DataIssue {
  const DataIssue({
    required this.title,
    required this.detail,
    this.webPath = "",
  });

  final String title;
  final String detail;

  /// Path of the record to fix in the InvenTree web UI (relative to the server), e.g. "web/stock/item/12".
  final String webPath;
}

/// The outcome of resolving a scanned barcode.
sealed class ScanOutcome {
  const ScanOutcome();
}

/// Resolved to exactly one MPN.
class ScanResolved extends ScanOutcome {
  const ScanResolved(this.result);
  final ResolvedPart result;
}

/// The MPN matched more than one manufacturer part - the user must choose.
class ScanAmbiguous extends ScanOutcome {
  const ScanAmbiguous(this.options);
  final List<ResolvedPart> options;
}

/// The barcode was recognised, but the data in InvenTree is incomplete.
class ScanDataError extends ScanOutcome {
  const ScanDataError(this.issue);
  final DataIssue issue;
}

/// Nothing in InvenTree matches the barcode.
class ScanNotFound extends ScanOutcome {
  const ScanNotFound(this.message);
  final String message;
}

/// The lookup failed (network, server error, permissions).
class ScanFailed extends ScanOutcome {
  const ScanFailed(this.message);
  final String message;
}

/// A stock item which could be loaded, classified against the expected MPN.
enum CandidateKind { exact, alternate, dataError }

class StockCandidate {
  const StockCandidate(this.item, this.kind);

  final StockItemInfo item;
  final CandidateKind kind;

  bool get selectable => kind != CandidateKind.dataError;
}

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});
  final String message;

  /// HTTP status, if the server responded (null for network errors).
  final int? statusCode;

  bool get isNotFound => statusCode == 404;
  @override
  String toString() => message;
}

/// Data access for the reel-loading workflow.
class InvenTreeRepository {
  InvenTreeRepository(this.api);

  final InvenTreeApi api;

  static const Map<String, String> _stockDetail = {
    "part_detail": "true",
    "supplier_part_detail": "true",
    "location_detail": "true",
  };

  String _errorFor(ApiResponse r, String what) {
    if (!r.isValid) return describeFailure(r);
    if (r.statusCode == 401) {
      return "Your session has expired. Please log in again.";
    }
    if (r.statusCode == 403) return "You do not have permission to $what.";
    if (r.statusCode == 404) return "Not found in InvenTree ($what).";

    final Map<String, dynamic> body = r.asMap();
    final dynamic detail =
        body["detail"] ?? body["error"] ?? body["non_field_errors"];
    final String extra = detail is List
        ? detail.join(" ")
        : (detail?.toString() ?? "");

    return "Server returned status ${r.statusCode} when trying to $what"
        "${extra.isEmpty ? "" : ": $extra"}";
  }

  Future<Map<String, dynamic>> _getObject(
    String endpoint,
    String what, {
    Map<String, String>? query,
  }) async {
    final ApiResponse r = await api.get(endpoint, query: query);
    if (!r.isSuccess) {
      throw ApiException(
        _errorFor(r, what),
        statusCode: r.isValid ? r.statusCode : null,
      );
    }
    return r.asMap();
  }

  /// GET a list endpoint, following pagination (up to [maxItems]).
  Future<List<Map<String, dynamic>>> _getList(
    String endpoint,
    String what, {
    Map<String, String> query = const {},
    int pageSize = 100,
    int maxItems = 1000,
  }) async {
    final List<Map<String, dynamic>> results = [];
    int offset = 0;

    while (true) {
      final ApiResponse r = await api.get(
        endpoint,
        query: {...query, "limit": "$pageSize", "offset": "$offset"},
      );

      if (!r.isSuccess) throw ApiException(_errorFor(r, what));

      final dynamic data = r.data;
      final List<dynamic> page;
      int count;

      if (data is Map<String, dynamic> && data["results"] is List) {
        page = data["results"] as List<dynamic>;
        count = (data["count"] as int?) ?? page.length;
      } else if (data is List) {
        page = data;
        count = page.length;
      } else {
        throw ApiException("Unexpected response when trying to $what.");
      }

      results.addAll(page.whereType<Map<String, dynamic>>());
      offset += page.length;

      if (page.isEmpty || offset >= count || results.length >= maxItems) break;
    }

    return results;
  }

  // ---------------------------------------------------------------------------
  // Lookups
  // ---------------------------------------------------------------------------

  Future<StockItemInfo> getStockItem(int pk) async => StockItemInfo.fromJson(
    await _getObject("stock/$pk/", "load stock item #$pk", query: _stockDetail),
  );

  Future<PartInfo> getPart(int pk) async =>
      PartInfo.fromJson(await _getObject("part/$pk/", "load part #$pk"));

  Future<ManufacturerPartInfo> getManufacturerPart(int pk) async =>
      ManufacturerPartInfo.fromJson(
        await _getObject(
          "company/part/manufacturer/$pk/",
          "load manufacturer part #$pk",
          query: {"manufacturer_detail": "true"},
        ),
      );

  Future<StockLocationInfo> getLocation(int pk) async =>
      StockLocationInfo.fromJson(
        await _getObject("stock/location/$pk/", "load stock location #$pk"),
      );

  Future<List<StockLocationInfo>> searchLocations(String search) async {
    final rows = await _getList(
      "stock/location/",
      "search stock locations",
      query: {
        if (search.trim().isNotEmpty) "search": search.trim(),
        "ordering": "pathstring",
      },
      maxItems: 100,
    );
    return rows.map(StockLocationInfo.fromJson).toList();
  }

  // ---------------------------------------------------------------------------
  // Barcode resolution
  // ---------------------------------------------------------------------------

  /// Resolve a scanned barcode (or typed MPN) to an exact MPN.
  ///
  /// Precedence: stock item label > manufacturer part > supplier part.
  /// If no barcode plugin recognises the data, it is tried as an exact MPN.
  /// A barcode which identifies a part but not its MPN is a [ScanDataError].
  Future<ScanOutcome> resolveBarcode(String raw) async {
    final String data = raw.trim();

    if (data.isEmpty) return const ScanNotFound("The barcode was empty.");

    if (data.length > kMaxBarcodeLength) {
      return const ScanNotFound("The barcode is too long to be a part label.");
    }

    try {
      final ApiResponse r = await api.post("barcode/", body: {"barcode": data});

      if (!r.isValid ||
          r.statusCode == 401 ||
          r.statusCode == 403 ||
          r.statusCode >= 500) {
        return ScanFailed(_errorFor(r, "look up the barcode"));
      }

      final Map<String, dynamic> body = r.asMap();

      if (r.isSuccess) {
        final ScanOutcome? outcome = await _fromBarcodeMatch(body);
        if (outcome != null) return outcome;
      }

      // No plugin recognised it - try it as an exact MPN
      return await _resolveMpn(data);
    } on ApiException catch (e) {
      return ScanFailed(e.message);
    }
  }

  Future<ScanOutcome?> _fromBarcodeMatch(Map<String, dynamic> body) async {
    int? pkOf(String key) {
      final dynamic v = body[key];
      if (v is Map<String, dynamic>) return v["pk"] as int?;
      return null;
    }

    final int? stockPk = pkOf("stockitem");
    if (stockPk != null) return _fromStockItem(await getStockItem(stockPk));

    final int? mpPk = pkOf("manufacturerpart");
    if (mpPk != null) return _fromManufacturerPart(mpPk);

    final int? spPk = pkOf("supplierpart");
    if (spPk != null) {
      final sp = await _getObject(
        "company/part/$spPk/",
        "load supplier part #$spPk",
      );
      final int? mp = sp["manufacturer_part"] as int?;

      if (mp == null) {
        return ScanDataError(
          DataIssue(
            title: "Supplier part has no MPN",
            detail:
                "Supplier part ${sp["SKU"] ?? "#$spPk"} is not linked to a manufacturer part, "
                "so the MPN cannot be verified. Link it to the correct manufacturer part in InvenTree.",
            webPath: "web/purchasing/supplier-part/$spPk",
          ),
        );
      }

      return _fromManufacturerPart(mp);
    }

    final int? partPk = pkOf("part");
    if (partPk != null) {
      final PartInfo part = await getPart(partPk);
      return ScanDataError(
        DataIssue(
          title: "Barcode does not identify an MPN",
          detail:
              "This barcode identifies part ${part.displayName}, but not which manufacturer part (MPN). "
              "Scan the reel's stock label or the manufacturer's label instead.",
          webPath: "web/part/$partPk",
        ),
      );
    }

    // Some other kind of object (location, order...)
    final known = body.keys.where(
      (k) => body[k] is Map && !const ["barcode_data", "instance"].contains(k),
    );
    if (known.isNotEmpty) {
      return ScanNotFound(
        "This barcode is a ${known.first}, not a part or reel label.",
      );
    }

    return null;
  }

  ScanOutcome _fromStockItemData(StockItemInfo item, ManufacturerPartInfo mp) =>
      ScanResolved(
        ResolvedPart(
          part: item.part ?? PartInfo(pk: item.partId),
          manufacturerPart: mp,
          stockItem: item,
        ),
      );

  Future<ScanOutcome> _fromStockItem(StockItemInfo item) async {
    final int? mpPk = item.manufacturerPartId;

    if (mpPk == null) {
      final String partName = item.part?.displayName ?? "#${item.partId}";

      if (item.supplierPartId == null) {
        return ScanDataError(
          DataIssue(
            title: "Stock item has no MPN",
            detail:
                "Stock item #${item.pk} ($partName) has no supplier part, so its MPN cannot be verified. "
                "Set the supplier part on this stock item in InvenTree.",
            webPath: "web/stock/item/${item.pk}",
          ),
        );
      }

      return ScanDataError(
        DataIssue(
          title: "Supplier part has no MPN",
          detail:
              "Stock item #${item.pk} ($partName) uses supplier part ${item.sku.isEmpty ? "#${item.supplierPartId}" : item.sku}, "
              "which is not linked to a manufacturer part. Link it to the correct manufacturer part in InvenTree.",
          webPath: "web/purchasing/supplier-part/${item.supplierPartId}",
        ),
      );
    }

    return _fromStockItemData(item, await getManufacturerPart(mpPk));
  }

  Future<ScanOutcome> _fromManufacturerPart(int pk) async {
    final ManufacturerPartInfo mp = await getManufacturerPart(pk);
    final PartInfo part = await getPart(mp.partId);
    return ScanResolved(ResolvedPart(part: part, manufacturerPart: mp));
  }

  Future<ScanOutcome> _resolveMpn(String mpn) async {
    final rows = await _getList(
      "company/part/manufacturer/",
      "look up the MPN",
      query: {"MPN": mpn, "manufacturer_detail": "true", "part_detail": "true"},
      maxItems: 20,
    );

    // The MPN filter is exact, but check anyway
    final matches = rows
        .map(ManufacturerPartInfo.fromJson)
        .where((m) => m.mpn == mpn)
        .toList();

    if (matches.isEmpty) {
      return const ScanNotFound(
        "No match found in InvenTree for this barcode. "
        "Check that it is the part label, not a location or order label.",
      );
    }

    final List<ResolvedPart> options = [];
    for (final mp in matches) {
      final Map<String, dynamic> row = rows.firstWhere((r) => r["pk"] == mp.pk);
      final Map<String, dynamic> pd = row["part_detail"] is Map<String, dynamic>
          ? row["part_detail"] as Map<String, dynamic>
          : <String, dynamic>{};
      final PartInfo part = pd.isNotEmpty
          ? PartInfo.fromJson(pd)
          : await getPart(mp.partId);
      options.add(ResolvedPart(part: part, manufacturerPart: mp));
    }

    return options.length == 1
        ? ScanResolved(options.single)
        : ScanAmbiguous(options);
  }

  // ---------------------------------------------------------------------------
  // Stock
  // ---------------------------------------------------------------------------

  /// In-stock items of [partId] in the source location (and sub-locations),
  /// classified against [expectedMpPk]. Exact matches first, then alternates,
  /// then items whose MPN cannot be verified. Items already in the machine
  /// location are excluded.
  Future<List<StockCandidate>> stockCandidates({
    required int partId,
    required int expectedMpPk,
    required StockLocationInfo source,
    required StockLocationInfo machine,
  }) async {
    final rows = await _getList(
      "stock/",
      "list stock",
      query: {
        "part": "$partId",
        "location": "${source.pk}",
        "cascade": "true",
        "in_stock": "true",
        "ordering": "pk",
        ..._stockDetail,
      },
    );

    final candidates = <StockCandidate>[];

    for (final row in rows) {
      final item = StockItemInfo.fromJson(row);

      if (item.locationId == machine.pk || item.quantity <= 0) continue;

      final CandidateKind kind = item.manufacturerPartId == null
          ? CandidateKind.dataError
          : item.manufacturerPartId == expectedMpPk
          ? CandidateKind.exact
          : CandidateKind.alternate;

      candidates.add(StockCandidate(item, kind));
    }

    candidates.sort((a, b) {
      final int k = a.kind.index.compareTo(b.kind.index);
      return k != 0 ? k : a.item.pk.compareTo(b.item.pk);
    });

    return candidates;
  }

  /// Move [quantity] of a stock item into [location].
  Future<void> transfer({
    required int stockItemPk,
    required double quantity,
    required int location,
    required String notes,
  }) async {
    final ApiResponse r = await api.post(
      "stock/transfer/",
      body: {
        "items": [
          {"pk": stockItemPk, "quantity": quantity},
        ],
        "location": location,
        "notes": notes,
      },
    );

    if (!r.isSuccess) throw ApiException(_errorFor(r, "move stock"));
  }
}
