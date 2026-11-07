// Minimal typed views of the InvenTree API objects the app needs.
// Only the fields used are parsed; everything is defensive about missing data.

int? _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);

double _double(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v == null ? "" : v.toString();

Map<String, dynamic> _map(dynamic v) =>
    v is Map<String, dynamic> ? v : <String, dynamic>{};

/// Format a stock quantity without a pointless ".0".
String formatQuantity(double q) {
  if (q == q.roundToDouble()) return q.toInt().toString();
  String s = q.toStringAsFixed(5);
  s = s.replaceFirst(RegExp(r"0+$"), "");
  return s.endsWith(".") ? s.substring(0, s.length - 1) : s;
}

/// An internal part.
class PartInfo {
  const PartInfo({
    required this.pk,
    this.name = "",
    this.fullName = "",
    this.ipn = "",
    this.description = "",
    this.units = "",
  });

  factory PartInfo.fromJson(Map<String, dynamic> json) => PartInfo(
    pk: _int(json["pk"]) ?? -1,
    name: _str(json["name"]),
    fullName: _str(json["full_name"]),
    ipn: _str(json["IPN"]),
    description: _str(json["description"]),
    units: _str(json["units"]),
  );

  final int pk;
  final String name;
  final String fullName;
  final String ipn;
  final String description;
  final String units;

  String get displayName => fullName.isNotEmpty ? fullName : name;
}

/// A manufacturer part - the identity of an exact MPN.
class ManufacturerPartInfo {
  const ManufacturerPartInfo({
    required this.pk,
    required this.partId,
    required this.mpn,
    this.manufacturerName = "",
  });

  factory ManufacturerPartInfo.fromJson(Map<String, dynamic> json) =>
      ManufacturerPartInfo(
        pk: _int(json["pk"]) ?? -1,
        partId: _int(json["part"]) ?? -1,
        mpn: _str(json["MPN"]),
        manufacturerName: _str(_map(json["manufacturer_detail"])["name"]),
      );

  final int pk;
  final int partId;
  final String mpn;
  final String manufacturerName;
}

/// A stock location.
class StockLocationInfo {
  const StockLocationInfo({
    required this.pk,
    required this.name,
    required this.pathstring,
    this.structural = false,
  });

  factory StockLocationInfo.fromJson(Map<String, dynamic> json) =>
      StockLocationInfo(
        pk: _int(json["pk"]) ?? -1,
        name: _str(json["name"]),
        pathstring: _str(json["pathstring"]).isNotEmpty
            ? _str(json["pathstring"])
            : _str(json["name"]),
        structural: json["structural"] == true,
      );

  final int pk;
  final String name;
  final String pathstring;
  final bool structural;

  Map<String, dynamic> toJson() => {
    "pk": pk,
    "name": name,
    "pathstring": pathstring,
    "structural": structural,
  };

  /// True if [other] is this location or one of its sub-locations.
  bool contains(StockLocationInfo other) =>
      other.pk == pk || other.pathstring.startsWith("$pathstring/");
}

/// A stock item (e.g. one reel).
class StockItemInfo {
  const StockItemInfo({
    required this.pk,
    required this.partId,
    required this.quantity,
    this.part,
    this.serial = "",
    this.batch = "",
    this.locationId,
    this.locationPath = "",
    this.supplierPartId,
    this.manufacturerPartId,
    this.mpn = "",
    this.sku = "",
    this.inStock = true,
    this.manufacturerName = "",
    this.supplierName = "",
  });

  factory StockItemInfo.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> sp = _map(json["supplier_part_detail"]);
    final Map<String, dynamic> loc = _map(json["location_detail"]);
    final Map<String, dynamic> part = _map(json["part_detail"]);

    return StockItemInfo(
      pk: _int(json["pk"]) ?? -1,
      partId: _int(json["part"]) ?? -1,
      quantity: _double(json["quantity"]),
      part: part.isEmpty ? null : PartInfo.fromJson(part),
      serial: _str(json["serial"]),
      batch: _str(json["batch"]),
      locationId: _int(json["location"]),
      locationPath: _str(loc["pathstring"]).isNotEmpty
          ? _str(loc["pathstring"])
          : _str(loc["name"]),
      supplierPartId: _int(json["supplier_part"]),
      manufacturerPartId: _int(sp["manufacturer_part"]),
      mpn: _str(json["MPN"]).isNotEmpty ? _str(json["MPN"]) : _str(sp["MPN"]),
      sku: _str(json["SKU"]).isNotEmpty ? _str(json["SKU"]) : _str(sp["SKU"]),
      inStock: json["in_stock"] != false,
    );
  }

  final int pk;
  final int partId;
  final double quantity;
  final PartInfo? part;
  final String serial;
  final String batch;
  final int? locationId;
  final String locationPath;
  final int? supplierPartId;

  /// Null if the item has no supplier part, or the supplier part has no
  /// manufacturer part - i.e. the MPN cannot be verified.
  final int? manufacturerPartId;

  final String mpn;
  final String sku;
  final bool inStock;

  /// Manufacturer of the reel's MPN ("" if not known).
  final String manufacturerName;

  /// Supplier the reel was bought from ("" if not known).
  final String supplierName;

  /// The supplier, if known and not the same company as the manufacturer
  /// (e.g. bought direct from the manufacturer).
  String get distinctSupplierName =>
      supplierName.isNotEmpty &&
          supplierName.trim().toLowerCase() !=
              manufacturerName.trim().toLowerCase()
      ? supplierName
      : "";

  StockItemInfo withNames({String? manufacturer, String? supplier}) =>
      StockItemInfo(
        pk: pk,
        partId: partId,
        quantity: quantity,
        part: part,
        serial: serial,
        batch: batch,
        locationId: locationId,
        locationPath: locationPath,
        supplierPartId: supplierPartId,
        manufacturerPartId: manufacturerPartId,
        mpn: mpn,
        sku: sku,
        inStock: inStock,
        manufacturerName: manufacturer ?? manufacturerName,
        supplierName: supplier ?? supplierName,
      );

  bool get hasMpnLink => manufacturerPartId != null;

  /// Short label for the reel, e.g. "#330" or "#330 (batch B12)".
  String get label {
    final parts = <String>["#$pk"];
    if (serial.isNotEmpty) parts.add("serial $serial");
    if (batch.isNotEmpty) parts.add("batch $batch");
    return parts.length == 1
        ? parts.first
        : "${parts.first} (${parts.skip(1).join(", ")})";
  }
}
