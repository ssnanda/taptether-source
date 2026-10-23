// Device-driven capability model for LG ThinQ profiles and live states.
// All readable profile features are shown. Writable features produce an
// action only if an exact parameter can be validated against LG's own
// advertised writable values. No guessed appliance commands.

class ThinQFeature {
  const ThinQFeature({
    required this.resource,
    required this.property,
    required this.type,
    required this.readable,
    required this.writable,
    this.current,
    this.options = const [],
    this.minimum,
    this.maximum,
    this.step,
    this.unit,
    this.location,
    this.locationInResource = false,
    this.excluded = const [],
  });

  final String resource;
  final String property;
  final String type;
  final bool readable;
  final bool writable;
  final Object? current;
  final List<Object> options;
  final num? minimum;
  final num? maximum;
  final num? step;
  final String? unit;
  final String? location;
  final bool locationInResource;
  final List<num> excluded;

  String get identity => '$resource.$property@${location ?? ""}';
  String get group => '${_title(resource)}'
      '${location == null ? "" : " · ${_title(location!)}"}';
  String get name => _title(property);
  String get currentText => current == null
      ? 'Not reported' : _valueLabel(current!);

  bool get actionable => writable &&
      (options.isNotEmpty ||
       (minimum != null && maximum != null &&
          (type == 'range' || type == 'number')));

  bool permits(Object value) {
    if (!actionable) {
      return false;
    }
    if (options.isNotEmpty) {
      return options.contains(value);
    }
    if (value is! num || minimum == null || maximum == null) {
      return false;
    }
    if (value < minimum! || value > maximum! || excluded.contains(value)) {
      return false;
    }
    final increment = step ?? 1;
    if (increment <= 0) {
      return false;
    }
    final multiples = (value - minimum!) / increment;
    return (multiples - multiples.round()).abs() < 0.000001;
  }

  Map<String, Object?> command(Object value) {
    if (!permits(value)) {
      throw const FormatException('Control is not allowed by LG profile.');
    }
    final propertyPayload = <String, Object?>{property: value};
    if (location != null && locationInResource) {
      propertyPayload['locationName'] = location;
    }
    return {
      if (location != null && !locationInResource)
        'location': {'locationName': location},
      resource: propertyPayload,
    };
  }
}

String _title(String raw) {
  final words = raw.replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'),
      (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ')
      .replaceAll(RegExp(r'\s+'), ' ').trim();
  return words.isEmpty ? raw
      : words[0].toUpperCase() + words.substring(1);
}

String _valueLabel(Object value) {
  if (value is bool) {
    return value ? 'Enabled' : 'Disabled';
  }
  if (value is num) {
    return value.toString();
  }
  final text = value.toString().replaceAll('_', ' ');
  return text.length > 130 ? '${text.substring(0, 130)}…' : text;
}

const _privateKeys = {
  'deviceId', 'userId', 'ownerId', 'serialNumber', 'serial',
  'ssid', 'bssid', 'macAddress', 'ipAddress', 'clientKey',
  'accessToken', 'refreshToken', 'token', 'password', 'locationId',
  'deviceUUID', 'uuid', 'certificate', 'modelId', 'userNo',
};

bool _safeName(String name) {
  if (_privateKeys.contains(name)) {
    return false;
  }
  final low = name.toLowerCase();
  return !(low.contains('secret') || low.contains('password') ||
      low.contains('token') || low.contains('credential') ||
      low.contains('serial') || low.contains('authkey') ||
      low == 'deviceid' || low == 'userid');
}

String? _location(Map node) {
  final location = node['location'];
  if (location is Map && location['locationName'] is String) {
    return location['locationName'] as String;
  }
  if (node['locationName'] is String) {
    return node['locationName'] as String;
  }
  return null;
}

Object? _extractCurrent(Object? status, String resource,
    String key, String? location) {
  Object? found;
  var exact = false;
  void visit(Object? node, String? zone, int depth) {
    if (depth > 9 || exact) {
      return;
    }
    if (node is List) {
      for (final item in node.take(32)) {
        visit(item, zone, depth + 1);
      }
    } else if (node is Map) {
      final here = _location(node) ?? zone;
      final resourceValue = node[resource];
      void takeValue(Map data, String? candidateLocation) {
        if (!data.containsKey(key)) {
          return;
        }
        final actualLocation = _location(data) ?? candidateLocation;
        if (location != null && location != actualLocation) {
          return;
        }
        final value = data[key];
        if (value is String || value is num || value is bool) {
          found = value;
          exact = location == null || actualLocation == location;
        }
      }
      if (resourceValue is Map) {
        takeValue(resourceValue, here);
      } else if (resourceValue is List) {
        // Refrigerator temperature/door resources contain a zone array.
        for (final item in resourceValue) {
          if (item is Map) {
            takeValue(item, here);
          }
        }
      }
      for (final entry in node.entries) {
        if (!_safeName(entry.key.toString())) {
          continue;
        }
        final value = entry.value;
        if (value is Map || value is List) {
          visit(value, here, depth + 1);
        }
      }
    }
  }
  visit(status, null, 0);
  return found;
}

/// Supports standard ThinQ property maps, washer subdevice profile arrays,
/// and refrigerator door/temperature profile arrays with locationName.
List<ThinQFeature> thinQFeatures(Object? profile, Object? state) {
  final values = <String, ThinQFeature>{};

  void addFeature(String resource, String key, Object? raw,
      String? location, bool inResource) {
    if (!_safeName(resource) || !_safeName(key) ||
        resource == 'location' || key == 'locationName' ||
        key == 'unit' || key == 'location') {
      return;
    }
    if (raw is! Map && raw is! String && raw is! bool &&
        raw is! num) {
      return;
    }
    final meta = raw is Map ? raw : <String, Object?>{};
    final type = meta['type']?.toString().toLowerCase() ??
        (raw is String ? 'string' : raw is bool ? 'boolean' : 'number');
    final mode = meta['mode'];
    final readable = mode is! List || mode.contains('r');
    final writable = mode is List && mode.contains('w');
    final valueMap = meta['value'];
    final writableValues = valueMap is Map ? valueMap['w'] : null;
    var opts = <Object>[];
    num? minimum, maximum, step;
    var excluded = <num>[];
    if (writable) {
      if (writableValues is List) {
        opts = writableValues
            .where((v) => v is String || v is bool || v is num)
            .take(75).cast<Object>().toList();
      } else if (type == 'boolean') {
        opts = [true, false];
      }
      if (writableValues is Map) {
        minimum = writableValues['min'] is num
            ? writableValues['min'] as num : null;
        maximum = writableValues['max'] is num
            ? writableValues['max'] as num : null;
        step = writableValues['step'] is num
            ? writableValues['step'] as num : null;
        excluded = writableValues['except'] is List
            ? (writableValues['except'] as List).whereType<num>().toList()
            : [];
      }
    }
    final current = _extractCurrent(state, resource, key, location) ??
        (raw is String || raw is num || raw is bool ? raw : null);
    final entry = ThinQFeature(
      resource: resource,
      property: key,
      location: location,
      locationInResource: inResource,
      type: type,
      readable: readable,
      writable: writable,
      current: current,
      options: opts,
      minimum: minimum,
      maximum: maximum,
      step: step,
      excluded: excluded,
      unit: meta['unit']?.toString(),
    );
    values[entry.identity] = entry;
  }

  void resourceMap(Map resourceNodes, String? location,
      bool inResource) {
    for (final entry in resourceNodes.entries) {
      final resource = entry.key.toString();
      if (resource == 'location' || resource == 'locationName' ||
          resource == 'unit' || !_safeName(resource)) {
        continue;
      }
      final properties = entry.value;
      if (properties is Map) {
        for (final prop in properties.entries) {
          addFeature(resource, prop.key.toString(), prop.value,
              location, inResource);
        }
      } else if (properties is List) {
        // Refrigerators store per-door/per-compartment resources in arrays.
        for (final item in properties) {
          if (item is Map) {
            final zone = _location(item) ?? location;
            for (final prop in item.entries) {
              addFeature(resource, prop.key.toString(), prop.value,
                  zone, true);
            }
          }
        }
      }
    }
  }

  final root = profile is Map ? profile['property'] : null;
  if (root is Map) {
    resourceMap(root, null, false);
  } else if (root is List) {
    // Multi-tub washers often have profile.property: [{location:{...},...}].
    for (final item in root) {
      if (item is Map) {
        resourceMap(item, _location(item), false);
      }
    }
  }

  // Include ALL additional scalar live state fields not in the profile;
  // LG firmware frequently adds status fields without profile metadata.
  void statusWalk(Object? node, String? location, int depth) {
    if (depth > 8 || values.length > 250) {
      return;
    }
    if (node is List) {
      for (final item in node.take(24)) {
        statusWalk(item, location, depth + 1);
      }
      return;
    }
    if (node is! Map) {
      return;
    }
    final zone = _location(node) ?? location;
    for (final entry in node.entries) {
      final group = entry.key.toString();
      if (!_safeName(group) || group == 'location' ||
          group == 'locationName') {
        continue;
      }
      final child = entry.value;
      if (child is Map) {
        final resourceZone = _location(child) ?? zone;
        for (final prop in child.entries) {
          final key = prop.key.toString();
          if (!_safeName(key) || key == 'locationName' ||
              key == 'location' || key == 'unit') {
            continue;
          }
          final value = prop.value;
          if (value is String || value is num || value is bool) {
            final id = '$group.$key@${resourceZone ?? ""}';
            if (!values.containsKey(id)) {
              addFeature(group, key, value, resourceZone,
                  child.containsKey('locationName'));
            }
          }
        }
      } else if (child is List) {
        for (final item in child) {
          if (item is Map) {
            statusWalk({group: item}, zone, depth + 1);
          }
        }
      }
    }
    final wrapped = node['property'] ?? node['response'] ?? node['result'];
    if (wrapped is Map || wrapped is List) {
      statusWalk(wrapped, zone, depth + 1);
    }
  }
  statusWalk(state, null, 0);
  return values.values.toList()
    ..sort((a, b) {
      final group = a.group.compareTo(b.group);
      return group != 0 ? group : a.name.compareTo(b.name);
    });
}

String thinQSummaryLine(List<ThinQFeature> features) {
  String? field(String key) {
    for (final value in features) {
      if (value.property == key && value.current != null) {
        return value.currentText;
      }
    }
    return null;
  }
  final stage = field('currentState') ?? field('runState');
  final rawHours = field('remainHour');
  final rawMinutes = field('remainMinute');
  final h = int.tryParse(rawHours ?? '0');
  final m = int.tryParse(rawMinutes ?? '0');
  if (stage != null && (rawHours != null || rawMinutes != null) &&
      h != null && m != null) {
    return '$stage · ${h > 0 ? "$h hr " : ""}$m min remaining';
  }
  if (stage != null) {
    return stage;
  }
  final door = field('doorState') ?? field('doorOpen');
  return door == null ? 'Status not available' : 'Door: $door';
}
