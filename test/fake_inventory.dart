import "dart:convert";

// In-memory InvenTree inventory data + REST endpoints, for FakeInvenTree.
//
// Locations:  1 Stores (source), 2 Stores/Shelf A, 3 SMT Line (machine),
//             4 Elsewhere, 5 Structural (structural)
// Part 10 "R 10k 0402":
//   MP 100 RC0402-10K (Yageo)     <- the "expected" MPN in most tests
//   MP 101 ERJ-2RKF1002X (Panasonic) - alternate
//   SP 200 -> MP 100, SP 201 -> MP 101, SP 202 -> no MP (data error)
// Part 20 "C 100n": MP 102, SP 203
// Parts 30 / 31 share MPN "DUP-1" (MP 103 / 104) - ambiguous
//
// Barcodes: "INV-SI<pk>" (stock item), "SUPPLIER:<sp>", "MFR:<mp>",
//           "PARTONLY:<part>", "LOC:<pk>". Anything else: no match.
class FakeInventory {
  FakeInventory() {
    _stock(1000, part: 10, sp: 200, loc: 1, qty: 5000);
    _stock(1001, part: 10, sp: 200, loc: 2, qty: 4000);
    _stock(1002, part: 10, sp: 201, loc: 1, qty: 3000);
    _stock(1003, part: 10, sp: null, loc: 1, qty: 1000);
    _stock(1004, part: 10, sp: 202, loc: 1, qty: 2000);
    _stock(1005, part: 10, sp: 200, loc: 4, qty: 6000);
    _stock(1006, part: 20, sp: 203, loc: 1, qty: 10000);
    _stock(1007, part: 10, sp: 200, loc: 3, qty: 10);
  }

  final Map<int, Map<String, dynamic>> locations = {
    1: {"pk": 1, "name": "Stores", "pathstring": "Stores", "structural": false},
    2: {
      "pk": 2,
      "name": "Shelf A",
      "pathstring": "Stores/Shelf A",
      "structural": false,
    },
    3: {
      "pk": 3,
      "name": "SMT Line",
      "pathstring": "SMT Line",
      "structural": false,
    },
    4: {
      "pk": 4,
      "name": "Elsewhere",
      "pathstring": "Elsewhere",
      "structural": false,
    },
    5: {
      "pk": 5,
      "name": "Structural",
      "pathstring": "Structural",
      "structural": true,
    },
  };

  final Map<int, Map<String, dynamic>> parts = {
    10: {
      "pk": 10,
      "name": "R 10k 0402",
      "full_name": "R 10k 0402",
      "IPN": "R-10K",
      "description": "Resistor",
      "units": "",
    },
    20: {
      "pk": 20,
      "name": "C 100n",
      "full_name": "C 100n",
      "IPN": "C-100N",
      "description": "Capacitor",
      "units": "",
    },
    30: {
      "pk": 30,
      "name": "Dup A",
      "full_name": "Dup A",
      "IPN": "",
      "description": "",
      "units": "",
    },
    31: {
      "pk": 31,
      "name": "Dup B",
      "full_name": "Dup B",
      "IPN": "",
      "description": "",
      "units": "",
    },
  };

  final Map<int, Map<String, dynamic>> manufacturerParts = {
    100: {
      "pk": 100,
      "part": 10,
      "MPN": "RC0402-10K",
      "manufacturer": 1,
      "manufacturer_detail": {"name": "Yageo"},
    },
    101: {
      "pk": 101,
      "part": 10,
      "MPN": "ERJ-2RKF1002X",
      "manufacturer": 2,
      "manufacturer_detail": {"name": "Panasonic"},
    },
    102: {
      "pk": 102,
      "part": 20,
      "MPN": "GRM155",
      "manufacturer": 3,
      "manufacturer_detail": {"name": "Murata"},
    },
    103: {
      "pk": 103,
      "part": 30,
      "MPN": "DUP-1",
      "manufacturer": 4,
      "manufacturer_detail": {"name": "Maker A"},
    },
    104: {
      "pk": 104,
      "part": 31,
      "MPN": "DUP-1",
      "manufacturer": 5,
      "manufacturer_detail": {"name": "Maker B"},
    },
  };

  // Company names (manufacturers 1-5, suppliers 10-11)
  final Map<int, String> companies = {
    1: "Yageo",
    2: "Panasonic",
    3: "Murata",
    4: "Maker A",
    5: "Maker B",
    10: "DigiKey",
    11: "Mouser",
  };

  // Set to make the supplier part list fail (names are optional)
  bool failSupplierPartList = false;

  final Map<int, Map<String, dynamic>> supplierParts = {
    200: {
      "pk": 200,
      "supplier": 10,
      "part": 10,
      "SKU": "SKU-A",
      "manufacturer_part": 100,
      "MPN": "RC0402-10K",
    },
    201: {
      "pk": 201,
      "supplier": 2,
      "part": 10,
      "SKU": "SKU-B",
      "manufacturer_part": 101,
      "MPN": "ERJ-2RKF1002X",
    },
    202: {
      "pk": 202,
      "supplier": 10,
      "part": 10,
      "SKU": "SKU-NOMP",
      "manufacturer_part": null,
      "MPN": null,
    },
    203: {
      "pk": 203,
      "supplier": 11,
      "part": 20,
      "SKU": "SKU-C",
      "manufacturer_part": 102,
      "MPN": "GRM155",
    },
  };

  final Map<int, Map<String, dynamic>> stock = {};

  /// Transfers received (request bodies).
  final List<Map<String, dynamic>> transfers = [];

  /// Make the next transfer be applied, but answered with a server error
  /// (as if the response was lost).
  bool failTransferAfterApplying = false;

  /// Make transfers fail without being applied.
  int? rejectTransfersWithStatus;

  int _nextStock = 2000;

  void _stock(
    int pk, {
    required int part,
    required int? sp,
    required int loc,
    required double qty,
  }) {
    stock[pk] = {
      "pk": pk,
      "part": part,
      "supplier_part": sp,
      "location": loc,
      "quantity": qty,
      "serial": null,
      "batch": "",
    };
  }

  Map<String, dynamic> stockJson(int pk) {
    final s = stock[pk]!;
    final sp = s["supplier_part"] == null
        ? null
        : supplierParts[s["supplier_part"]];
    final mp = sp?["manufacturer_part"] == null
        ? null
        : manufacturerParts[sp!["manufacturer_part"]];
    return {
      ...s,
      "in_stock": (s["quantity"] as double) > 0,
      "MPN": mp?["MPN"],
      "SKU": sp?["SKU"],
      "part_detail": parts[s["part"]],
      "supplier_part_detail": sp,
      "location_detail": locations[s["location"]],
    };
  }

  bool _inLocation(int? itemLoc, int loc, bool cascade) {
    if (itemLoc == null) return false;
    if (itemLoc == loc) return true;
    if (!cascade) return false;
    final String parent = locations[loc]!["pathstring"] as String;
    return (locations[itemLoc]!["pathstring"] as String).startsWith("$parent/");
  }

  Object _page(List<Map<String, dynamic>> all, Map<String, String> q) {
    final int limit = int.tryParse(q["limit"] ?? "") ?? all.length;
    final int offset = int.tryParse(q["offset"] ?? "") ?? 0;
    return {
      "count": all.length,
      "results": all.skip(offset).take(limit).toList(),
    };
  }

  (int, Object) _barcode(String data) {
    (int, Object) match(String key, int pk) => (
      200,
      {
        key: {"pk": pk},
        "success": "Match found",
      },
    );

    final si = RegExp(r"^INV-SI(\d+)$").firstMatch(data);
    if (si != null && stock.containsKey(int.parse(si[1]!))) {
      return match("stockitem", int.parse(si[1]!));
    }

    final m = RegExp(r"^(SUPPLIER|MFR|PARTONLY|LOC):(\d+)$").firstMatch(data);
    if (m != null) {
      final int pk = int.parse(m[2]!);
      return switch (m[1]) {
        "SUPPLIER" => match("supplierpart", pk),
        "MFR" => match("manufacturerpart", pk),
        "PARTONLY" => match("part", pk),
        _ => match("stocklocation", pk),
      };
    }

    return (400, {"error": "No match found for barcode data"});
  }

  (int, Object) _transfer(Map<String, dynamic> body) {
    transfers.add(body);

    if (rejectTransfersWithStatus != null) {
      return (rejectTransfersWithStatus!, {"detail": "Rejected"});
    }

    final int dest = body["location"] as int;
    for (final item in body["items"] as List) {
      final int pk = item["pk"] as int;
      final double q = (item["quantity"] as num).toDouble();
      final s = stock[pk]!;
      final double have = s["quantity"] as double;

      if (q > have) {
        return (
          400,
          {
            "items": [
              {
                "quantity": ["Quantity exceeds stock"],
              },
            ],
          },
        );
      }

      if (q == have) {
        s["location"] = dest;
      } else {
        s["quantity"] = have - q;
        final int newPk = _nextStock++;
        stock[newPk] = {...s, "pk": newPk, "quantity": q, "location": dest};
      }
    }

    if (failTransferAfterApplying) {
      failTransferAfterApplying = false;
      return (500, {"detail": "Server error"});
    }

    return (201, {"items": body["items"], "location": dest});
  }

  /// Handle an (authenticated) inventory request, or return null if unknown.
  (int, Object)? handle(String method, Uri uri, String body) {
    final String path = uri.path;
    final Map<String, String> q = uri.queryParameters;
    RegExpMatch? m(String pattern) =>
        RegExp("^/api/$pattern\$").firstMatch(path);
    (int, Object) obj(Map<int, Map<String, dynamic>> table, String id) {
      final row = table[int.parse(id)];
      return row == null ? (404, {"detail": "Not found."}) : (200, row);
    }

    if (method == "POST" && path == "/api/barcode/") {
      return _barcode(
        (json.decode(body) as Map<String, dynamic>)["barcode"].toString(),
      );
    }

    if (method == "POST" && path == "/api/stock/transfer/") {
      return _transfer(json.decode(body) as Map<String, dynamic>);
    }

    if (method != "GET") return null;

    RegExpMatch? r;

    if ((r = m(r"stock/(\d+)/")) != null) {
      final int pk = int.parse(r![1]!);
      return stock.containsKey(pk)
          ? (200, stockJson(pk))
          : (404, {"detail": "Not found."});
    }

    if (path == "/api/stock/") {
      Iterable<int> pks = stock.keys.toList()..sort();
      if (q["part"] != null) {
        pks = pks.where((pk) => stock[pk]!["part"] == int.parse(q["part"]!));
      }
      if (q["location"] != null) {
        pks = pks.where(
          (pk) => _inLocation(
            stock[pk]!["location"] as int?,
            int.parse(q["location"]!),
            q["cascade"] == "true",
          ),
        );
      }
      if (q["in_stock"] == "true") {
        pks = pks.where((pk) => (stock[pk]!["quantity"] as double) > 0);
      }
      return (200, _page(pks.map(stockJson).toList(), q));
    }

    if ((r = m(r"stock/location/(\d+)/")) != null) {
      return obj(locations, r![1]!);
    }

    if (path == "/api/stock/location/") {
      final String search = (q["search"] ?? "").toLowerCase();
      final rows = locations.values
          .where(
            (l) => (l["pathstring"] as String).toLowerCase().contains(search),
          )
          .toList();
      return (200, _page(rows, q));
    }

    if ((r = m(r"part/(\d+)/")) != null) return obj(parts, r![1]!);

    if ((r = m(r"company/part/manufacturer/(\d+)/")) != null) {
      return obj(manufacturerParts, r![1]!);
    }

    if (path == "/api/company/part/manufacturer/") {
      final rows = manufacturerParts.values
          .where((mp) => q["MPN"] == null || mp["MPN"] == q["MPN"])
          .map((mp) => {...mp, "part_detail": parts[mp["part"]]})
          .toList();
      return (200, _page(rows, q));
    }

    if (path == "/api/company/part/") {
      if (failSupplierPartList) return (500, {"detail": "Server error"});
      final rows = supplierParts.values
          .where((sp) => q["part"] == null || "${sp["part"]}" == q["part"])
          .map((sp) {
            final mp = sp["manufacturer_part"] == null
                ? null
                : manufacturerParts[sp["manufacturer_part"]];
            return {
              ...sp,
              if (q["supplier_detail"] == "true")
                "supplier_detail": {"name": companies[sp["supplier"]]},
              if (q["manufacturer_detail"] == "true")
                "manufacturer_detail": mp == null
                    ? null
                    : {"name": companies[mp["manufacturer"]]},
            };
          })
          .toList();
      return (200, _page(rows, q));
    }

    if ((r = m(r"company/part/(\d+)/")) != null) {
      return obj(supplierParts, r![1]!);
    }

    return null;
  }
}
