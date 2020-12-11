/*
 * Copyright (c) 2019-2020. Antonello Andrea (www.hydrologis.com). All rights reserved.
 * Use of this source code is governed by a GPL3 license that can be
 * found in the LICENSE file.
 */

import 'dart:core';

import 'package:dart_hydrologis_db/dart_hydrologis_db.dart';
import 'package:dart_hydrologis_utils/dart_hydrologis_utils.dart';
import 'package:dart_jts/dart_jts.dart' as JTS;
import 'package:dart_postgis/dart_postgis.dart';
import 'package:flutter/material.dart' hide TextStyle;
import 'package:flutter/widgets.dart' hide TextStyle;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong/latlong.dart';
import 'package:provider/provider.dart';
import 'package:smash/eu/hydrologis/smash/maps/layers/core/layersource.dart';
import 'package:smash/eu/hydrologis/smash/models/map_state.dart';
import 'package:smashlibs/smashlibs.dart';

/// Postgis vector data layer.
class PostgisSource extends VectorLayerSource implements SldLayerSource {
  static final double POINT_SIZE_FACTOR = 3;

  String _tableName;
  bool isVisible = true;
  String _attribution = "";

  PGQueryResult _tableData;
  JTS.Envelope _tableBounds;
  GeometryColumn _geometryColumn;
  SldObjectParser _style;
  TextStyle _textStyle;

  PostgisDb db;
  int _srid;
  String _dbUrl;
  String _user;
  String _pwd;
  String _where;

  List<String> alphaFields = [];
  String sldString;
  JTS.EGeometryType geometryType;

  PostgisSource.fromMap(Map<String, dynamic> map) {
    _tableName = map[LAYERSKEY_LABEL];
    _dbUrl = map[LAYERSKEY_URL]; // postgis:host:port/dbname
    _user = map[LAYERSKEY_USER];
    _pwd = map[LAYERSKEY_PWD];
    _where = map[LAYERSKEY_WHERE];
    if (_where != null && _where.isEmpty) {
      _where = null;
    }
    isVisible = map[LAYERSKEY_ISVISIBLE] ?? true;

    _srid = map[LAYERSKEY_SRID];
  }

  PostgisSource(this._dbUrl, this._tableName, this._user, this._pwd);

  Future<void> load(BuildContext context) async {
    if (!isLoaded) {
      int maxFeaturesToLoad =
          GpPreferences().getIntSync(KEY_VECTOR_MAX_FEATURES, -1);
      bool loadOnlyVisible =
          GpPreferences().getBooleanSync(KEY_VECTOR_LOAD_ONLY_VISIBLE, false);

      JTS.Envelope limitBounds;
      if (loadOnlyVisible) {
        var mapState = Provider.of<SmashMapState>(context, listen: false);
        if (mapState.mapController != null) {
          var bounds = mapState.mapController.bounds;
          var n = bounds.north;
          var s = bounds.south;
          var e = bounds.east;
          var w = bounds.west;
          limitBounds = JTS.Envelope.fromCoordinates(
              JTS.Coordinate(w, s), JTS.Coordinate(e, n));
        }
      }

      await getDatabase();
      var sqlName = SqlName(_tableName);
      _geometryColumn = await db.getGeometryColumnsForTable(sqlName);
      _srid = _geometryColumn.srid;
      geometryType = _geometryColumn.geometryType;
      var alphaFieldsTmp = await db.getTableColumns(sqlName);

      alphaFields = alphaFieldsTmp.map((e) => e[0] as String).toList();
      alphaFields
          .removeWhere((name) => name == _geometryColumn.geometryColumnName);

      sldString = await db.getSld(sqlName);
      if (sldString == null) {
        if (_geometryColumn.geometryType.isPoint()) {
          sldString = DefaultSlds.simplePointSld();
          await db.updateSld(sqlName, sldString);
        } else if (_geometryColumn.geometryType.isLine()) {
          sldString = DefaultSlds.simpleLineSld();
          await db.updateSld(sqlName, sldString);
        } else if (_geometryColumn.geometryType.isPolygon()) {
          sldString = DefaultSlds.simplePolygonSld();
          await db.updateSld(sqlName, sldString);
        }
      }
      if (sldString != null) {
        _style = SldObjectParser.fromString(sldString);
        _style.parse();

        if (_style.featureTypeStyles.first.rules.first.textSymbolizers.length >
            0) {
          _textStyle = _style
              .featureTypeStyles.first.rules.first.textSymbolizers.first.style;
        }
      }
      if (maxFeaturesToLoad == -1) {
        maxFeaturesToLoad = null;
      }

      var dataPrj = SmashPrj.fromSrid(_srid);
      if (dataPrj != null) {
        if (_srid != SmashPrj.EPSG4326_INT) {
          var boundsPolygon =
              PostgisUtils.createPolygonFromEnvelope(limitBounds);
          SmashPrj.transformGeometry(SmashPrj.EPSG4326, dataPrj, boundsPolygon);
          limitBounds = boundsPolygon.getEnvelopeInternal();
        }
        _tableData = await db.getTableData(
          SqlName(_tableName),
          limit: maxFeaturesToLoad,
          envelope: limitBounds,
          where: _where,
        );
        if (_srid != SmashPrj.EPSG4326_INT) {
          SmashPrj.transformListToWgs84(dataPrj, _tableData.geoms);
        }
        _tableBounds = JTS.Envelope.empty();
        _tableData.geoms.forEach((g) {
          _tableBounds.expandToIncludeEnvelope(g.getEnvelopeInternal());
        });

        _attribution =
            "${_geometryColumn.geometryType.getTypeName()} (${_tableData.geoms.length}) ";
        if (_where != null) {
          _attribution += " (where $_where)";
        }

        isLoaded = true;
      }
    }
  }

  getDatabase() async {
    var ch = PostgisConnectionsHandler();
    if (db == null) {
      db = await ch.open(_dbUrl, _tableName, _user, _pwd);
    }
  }

  bool hasData() {
    return _tableData != null && _tableData.geoms.length > 0;
  }

  String getAbsolutePath() {
    return null;
  }

  String getUrl() {
    return _dbUrl;
  }

  String getUser() => _user;

  String getPassword() => _pwd;

  String getName() {
    return _tableName;
  }

  String getAttribution() {
    return _attribution;
  }

  String getWhere() {
    return _where;
  }

  bool isActive() {
    return isVisible;
  }

  void setActive(bool active) {
    isVisible = active;
  }

  String toJson() {
    String w = "";
    if (_where != null) {
      w = """ "$LAYERSKEY_WHERE": "$_where", """;
    }
    var json = '''
    {
        "$LAYERSKEY_LABEL": "$_tableName",
        "$LAYERSKEY_URL":"$_dbUrl",
        "$LAYERSKEY_USER":"$_user",
        "$LAYERSKEY_PWD":"$_pwd",
        "$LAYERSKEY_ISVECTOR": true,
        "$LAYERSKEY_SRID": $_srid,
        $w
        "$LAYERSKEY_ISVISIBLE": $isVisible 
    }
    ''';
    return json;
  }

  @override
  Future<List<LayerOptions>> toLayers(BuildContext context) async {
    await load(context);

    List<LayerOptions> layers = [];
    if (_tableData.geoms.isNotEmpty) {
      List<List<Marker>> allPoints = [];
      List<Polyline> allLines = [];
      List<Polygon> allPolygons = [];

      Color pointFillColor;
      _style.applyForEachRule((fts, Rule rule) {
        if (geometryType.isPoint()) {
          List<Marker> points = makeMarkersForRule(rule);
          if (rule.pointSymbolizers.isNotEmpty && pointFillColor == null) {
            pointFillColor =
                ColorExt(rule.pointSymbolizers[0].style.fillColorHex);
          }
          allPoints.add(points);
        } else if (geometryType.isLine()) {
          List<Polyline> lines = makeLinesForRule(rule);
          allLines.addAll(lines);
        } else if (geometryType.isPolygon()) {
          List<Polygon> polygons = makePolygonsForRule(rule);
          allPolygons.addAll(polygons);
        }
      });

      if (allPoints.isNotEmpty) {
        addMarkerLayer(allPoints, layers, pointFillColor);
      } else if (allLines.isNotEmpty) {
        var lineLayer = PolylineLayerOptions(
          polylineCulling: true,
          polylines: allLines,
        );
        layers.add(lineLayer);
      } else if (allPolygons.isNotEmpty) {
        var polygonLayer = PolygonLayerOptions(
          polygonCulling: true,
          // simplify: true,
          polygons: allPolygons,
        );
        layers.add(polygonLayer);
      }
    }
    return layers;
  }

  List<Polygon> makePolygonsForRule(Rule rule) {
    List<Polygon> polygons = [];
    var filter = rule.filter;
    var key = filter?.uniqueValueKey;
    var value = filter?.uniqueValueValue;

    var polygonSymbolizersList = rule.polygonSymbolizers;
    if (polygonSymbolizersList == null || polygonSymbolizersList.isEmpty) {
      return [];
    }
    var polygonStyle = polygonSymbolizersList[0].style ??= PolygonStyle();

    var lineWidth = polygonStyle.strokeWidth;
    Color lineStrokeColor = ColorExt(polygonStyle.strokeColorHex);
    var lineOpacity = polygonStyle.strokeOpacity * 255;
    lineStrokeColor = lineStrokeColor.withAlpha(lineOpacity.toInt());

    Color fillColor = ColorExt(polygonStyle.fillColorHex)
        .withAlpha((polygonStyle.fillOpacity * 255).toInt());

    var featureCount = _tableData.geoms.length;
    for (var i = 0; i < featureCount; i++) {
      var geom = _tableData.geoms[i];
      var attributes = _tableData.data[i];
      if (key == null || attributes[key]?.toString() == value) {
        var count = geom.getNumGeometries();
        for (var i = 0; i < count; i++) {
          JTS.Polygon p = geom.getGeometryN(i);
          // ext ring
          var extCoords = p
              .getExteriorRing()
              .getCoordinates()
              .map((c) => LatLng(c.y, c.x))
              .toList();

          // inter rings
          var numInteriorRing = p.getNumInteriorRing();
          List<List<LatLng>> intRingCoords = [];
          for (var i = 0; i < numInteriorRing; i++) {
            var intCoords = p
                .getInteriorRingN(i)
                .getCoordinates()
                .map((c) => LatLng(c.y, c.x))
                .toList();
            intRingCoords.add(intCoords);
          }

          polygons.add(Polygon(
            points: extCoords,
            borderStrokeWidth: lineWidth,
            holePointsList: intRingCoords,
            borderColor: lineStrokeColor,
            color: fillColor,
          ));
        }
      }
    }

    return polygons;
  }

  List<Polyline> makeLinesForRule(Rule rule) {
    List<Polyline> lines = [];
    var filter = rule.filter;
    var key = filter?.uniqueValueKey;
    var value = filter?.uniqueValueValue;

    var lineSymbolizersList = rule.lineSymbolizers;
    if (lineSymbolizersList == null || lineSymbolizersList.isEmpty) {
      return [];
    }
    var lineStyle = lineSymbolizersList[0].style ??= LineStyle();

    var lineWidth = lineStyle.strokeWidth;
    Color lineStrokeColor = ColorExt(lineStyle.strokeColorHex);
    var lineOpacity = lineStyle.strokeOpacity * 255;
    lineStrokeColor = lineStrokeColor.withAlpha(lineOpacity.toInt());

    var featureCount = _tableData.geoms.length;
    for (var i = 0; i < featureCount; i++) {
      var geom = _tableData.geoms[i];
      var attributes = _tableData.data[i];
      if (key == null || attributes[key]?.toString() == value) {
        var count = geom.getNumGeometries();
        for (var i = 0; i < count; i++) {
          JTS.LineString l = geom.getGeometryN(i);
          var linePoints =
              l.getCoordinates().map((c) => LatLng(c.y, c.x)).toList();
          lines.add(Polyline(
              points: linePoints,
              strokeWidth: lineWidth,
              color: lineStrokeColor));
        }
      }
    }

    return lines;
  }

  /// Create markers for a given [Rule].
  List<Marker> makeMarkersForRule(Rule rule) {
    List<Marker> points = [];
    var filter = rule.filter;
    var key = filter?.uniqueValueKey;
    var value = filter?.uniqueValueValue;

    var pointSymbolizersList = rule.pointSymbolizers;
    if (pointSymbolizersList == null || pointSymbolizersList.isEmpty) {
      return [];
    }
    var pointStyle = pointSymbolizersList[0].style ??= PointStyle();
    var iconData = SmashIcons.forSldWkName(pointStyle.markerName);
    var pointsSize = pointStyle.markerSize * 3;
    Color pointFillColor = ColorExt(pointStyle.fillColorHex);
    pointFillColor = pointFillColor.withOpacity(pointStyle.fillOpacity);

    String labelName;
    ColorExt labelColor;
    if (_textStyle != null) {
      labelName = _textStyle.labelName;
      labelColor = ColorExt(_textStyle.textColor);
    }

    var featureCount = _tableData.geoms.length;
    for (var i = 0; i < featureCount; i++) {
      var geom = _tableData.geoms[i];
      var attributes = _tableData.data[i];
      if (key == null || attributes[key]?.toString() == value) {
        var count = geom.getNumGeometries();
        for (var i = 0; i < count; i++) {
          JTS.Point l = geom.getGeometryN(i);
          var labelText = attributes[labelName];
          double textExtraHeight = MARKER_ICON_TEXT_EXTRA_HEIGHT;
          String labelTextString;
          if (labelText == null) {
            textExtraHeight = 0;
          } else {
            labelTextString = labelText.toString();
          }

          Marker m = Marker(
              width: pointsSize * MARKER_ICON_TEXT_EXTRA_WIDTH_FACTOR,
              height: pointsSize + textExtraHeight,
              point: LatLng(l.getY(), l.getX()),
              // anchorPos: AnchorPos.exactly(
              //     Anchor(pointsSize / 2, textExtraHeight + pointsSize / 2)),
              builder: (ctx) => MarkerIcon(
                    iconData,
                    pointFillColor,
                    pointsSize,
                    labelTextString,
                    labelColor,
                    pointFillColor.withAlpha(100),
                  ));
          points.add(m);
        }
      }
    }
    return points;
  }

  void addMarkerLayer(List<List<Marker>> allPoints, List<LayerOptions> layers,
      Color pointFillColor) {
    if (allPoints.length == 1) {
      var waypointsCluster = MarkerClusterLayerOptions(
        maxClusterRadius: 20,
        size: Size(40, 40),
        fitBoundsOptions: FitBoundsOptions(
          padding: EdgeInsets.all(50),
        ),
        markers: allPoints[0],
        polygonOptions: PolygonOptions(
            borderColor: pointFillColor,
            color: pointFillColor.withOpacity(0.2),
            borderStrokeWidth: 3),
        builder: (context, markers) {
          return FloatingActionButton(
            child: Text(markers.length.toString()),
            onPressed: null,
            backgroundColor: pointFillColor,
            foregroundColor: SmashColors.mainBackground,
            heroTag: null,
          );
        },
      );
      layers.add(waypointsCluster);
    } else {
      // in case of multiple rules, we would not know the color for a mixed cluster.
      List<Marker> points = [];
      allPoints.forEach((p) => points.addAll(p));
      layers.add(MarkerLayerOptions(markers: points));
    }
  }

  @override
  Future<LatLngBounds> getBounds() async {
    if (_tableBounds != null) {
      var s = _tableBounds.getMinY();
      var n = _tableBounds.getMaxY();
      var w = _tableBounds.getMinX();
      var e = _tableBounds.getMaxX();
      LatLngBounds b = LatLngBounds(LatLng(s, w), LatLng(n, e));
      return b;
    } else {
      return null;
    }
  }

  @override
  void disposeSource() {
    PostgisConnectionsHandler().close(getAbsolutePath(), tableName: getName());
  }

  @override
  bool hasProperties() {
    return true;
  }

  @override
  bool isZoomable() {
    return _tableBounds != null;
  }

  @override
  int getSrid() {
    return _srid;
  }

  @override
  void calculateSrid() {
    // TODO check
    // if (_srid == null) {
    //   if (db == null) {
    //     getDatabase();
    //   }
    //   if (_srid == null) {
    //     _geometryColumn = db.getGeometryColumnsForTable(SqlName(_tableName));
    //     _srid = _geometryColumn.srid;
    //   }
    // }
    return;
  }

  Widget getPropertiesWidget() {
    return SldPropertiesEditor(sldString, geometryType,
        alphaFields: alphaFields);
  }

  @override
  void updateStyle(String newSldString) async {
    sldString = newSldString;
    var _styleTmp = SldObjectParser.fromString(sldString);
    _styleTmp.parse();

    // check is label has changed, in that case a reload will be necessary
    if (_styleTmp.featureTypeStyles.first.rules.first.textSymbolizers.length >
        0) {
      var textStyleTmp = _styleTmp
          .featureTypeStyles.first.rules.first.textSymbolizers.first.style;

      if (_textStyle?.labelName != textStyleTmp.labelName) {
        isLoaded = false;
      }
      _textStyle = textStyleTmp;
    }
    _style = _styleTmp;
    await db.updateSld(SqlName(_tableName), sldString);
  }
}

class PostgisConnectionsHandler {
  static final PostgisConnectionsHandler _singleton =
      PostgisConnectionsHandler._internal();

  factory PostgisConnectionsHandler() {
    return _singleton;
  }

  PostgisConnectionsHandler._internal();

  /// Map containing a mapping of db paths and db connections.
  Map<String, PostgisDb> _connectionsMap = {};

  /// Map containing a mapping of db paths opened tables.
  ///
  /// The db can be closed only when all tables have been removed.
  Map<String, List<String>> _tableNamesMap = {};

  /// Open a new db or retrieve it from the cache.
  ///
  /// The [tableName] can be added to keep track of the tables that
  /// still need an open connection boudn to a given [_dbUrl].
  Future<PostgisDb> open(
      String _dbUrl, String tableName, String user, String pwd) async {
    PostgisDb db = _connectionsMap[_dbUrl];
    if (db == null) {
      // _dbUrl = postgis:host:port/dbname
      var split = _dbUrl.split(RegExp(r":|/"));
      var port = int.tryParse(split[2]) ?? 5432;
      db = PostgisDb(split[1], split[3], port: port, user: user, pwd: pwd);
      await db.open();

      _connectionsMap[_dbUrl] = db;
    }
    var namesList = _tableNamesMap[_dbUrl];
    if (namesList == null) {
      namesList = List<String>();
      _tableNamesMap[_dbUrl] = namesList;
    }
    if (tableName != null && !namesList.contains(tableName)) {
      namesList.add(tableName);
    }
    return db;
  }

  /// Close an existing db connection, if all tables bound to it were released.
  Future<void> close(String path, {String tableName}) async {
    var tableNamesList = _tableNamesMap[path];
    if (tableNamesList != null && tableNamesList.contains(tableName)) {
      tableNamesList.remove(tableName);
    }
    if (tableNamesList == null || tableNamesList.length == 0) {
      // ok to close db and remove the connection
      _tableNamesMap.remove(path);
      PostgisDb db = _connectionsMap.remove(path);
      await db?.close();
    }
  }

  Future<void> closeAll() async {
    _tableNamesMap.clear();
    Iterable<PostgisDb> values = _connectionsMap.values;
    for (PostgisDb c in values) {
      await c.close();
    }
  }

  List<String> getOpenDbReport() {
    List<String> msgs = [];
    if (_tableNamesMap.length > 0) {
      _tableNamesMap.forEach((p, n) {
        msgs.add("Database: $p");
        if (n != null && n.length > 0) {
          msgs.add("-> with tables: ${n.join("; ")}");
        }
      });
    } else {
      msgs.add("No database connection.");
    }
    return msgs;
  }
}
