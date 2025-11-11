import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pedometer/pedometer.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_sensors/flutter_sensors.dart';

void main() {
  runApp(const StepTrackerApp());
}

class StepTrackerApp extends StatelessWidget {
  const StepTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Step Tracker',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const TrackerScreen(),
    );
  }
}

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});
  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  // --- Steps
  StreamSubscription<StepCount>? _stepSub;
  int _steps = 0;
  int? _baseSteps;

  // --- Distance & GPS
  StreamSubscription<Position>? _posSub;
  Position? _lastPos;
  double _distanceMeters = 0.0;

  // --- Elevation (barometer preferred, GPS fallback)
  StreamSubscription<SensorEvent>? _pressSub;
  bool _barometerAvailable = false;
  double? _basePressure; // hPa
  double? _lastAltitude; // meters
  double _elevationGain = 0.0; // uphill-only meters

  bool _tracking = false;
  String _status = '';

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    final results = await [
      Permission.activityRecognition,
      Permission.locationWhenInUse,
    ].request();

    if (results[Permission.locationWhenInUse]?.isGranted != true) {
      throw 'Location permission denied';
    }
    // activityRecognition may not exist on older APIs; ignore if permanently denied.
  }

  Future<void> _start() async {
    try {
      await _requestPermissions();

      // Steps
      _stepSub = Pedometer.stepCountStream.listen((StepCount s) {
        final v = s.steps;
        _baseSteps ??= v;
        setState(() => _steps = math.max(0, v - (_baseSteps ?? v)));
      }, onError: (_) {
        setState(() => _status = 'Step counter not available on this device.');
      });

      // GPS distance stream (2m filter)
      final hasService = await Geolocator.isLocationServiceEnabled();
      if (!hasService) {
        setState(() => _status = 'Please enable Location Services.');
      }
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.deniedForever) {
        setState(() => _status = 'Location permission permanently denied.');
      }

      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 2,
        ),
      ).listen((p) {
        if (_lastPos != null) {
          final d = Geolocator.distanceBetween(
            _lastPos!.latitude, _lastPos!.longitude, p.latitude, p.longitude);
          _distanceMeters += d;

          // GPS altitude fallback when no barometer
          if (!_barometerAvailable) {
            _updateAltitudeFromGPS(p.altitude);
          }
        }
        _lastPos = p;
        setState(() {});
      });

      // Barometer
      _barometerAvailable = await SensorManager()
          .isSensorAvailable(Sensors.PRESSURE);
      if (_barometerAvailable) {
        final stream = await SensorManager().sensorUpdates(
          sensorId: Sensors.PRESSURE,
          interval: Sensors.SENSOR_DELAY_NORMAL,
        );
        _pressSub = stream.listen((event) {
          final pressureHpa = event.data[0]; // hPa
          _updateAltitudeFromPressure(pressureHpa);
        });
      }

      setState(() {
        _tracking = true;
        _status = _barometerAvailable
            ? 'Tracking (barometer + GPS)'
            : 'Tracking (GPS; barometer not available)';
      });
    } catch (e) {
      setState(() => _status = 'Error starting: $e');
    }
  }

  void _stop() {
    _stepSub?.cancel(); _stepSub = null;
    _posSub?.cancel(); _posSub = null;
    _pressSub?.cancel(); _pressSub = null;
    setState(() => _tracking = false);
  }

  void _reset() {
    _stop();
    setState(() {
      _steps = 0; _baseSteps = null;
      _distanceMeters = 0.0;
      _lastPos = null;
      _basePressure = null; _lastAltitude = null; _elevationGain = 0.0;
      _status = '';
    });
  }

  // Hypsometric approximation: altitude in meters from pressure ratio.
  // We use the first pressure as baseline (P0).
  void _updateAltitudeFromPressure(double pressureHpa) {
    _basePressure ??= pressureHpa; // baseline at start
    final P = pressureHpa;
    final P0 = _basePressure!;
    final alt = 44330.0 * (1.0 - math.pow(P / P0, 1 / 5.255));
    _updateElevationGain(alt);
  }

  void _updateAltitudeFromGPS(double altitudeMeters) {
    _updateElevationGain(altitudeMeters);
  }

  void _updateElevationGain(double currentAlt) {
    if (_lastAltitude != null) {
      final delta = currentAlt - _lastAltitude!;
      if (delta > 0) {
        _elevationGain += delta;
      }
    }
    _lastAltitude = currentAlt;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final km = (_distanceMeters / 1000).toStringAsFixed(3);
    final elev = _elevationGain.toStringAsFixed(1);
    return Scaffold(
      appBar: AppBar(title: const Text('Step Tracker')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              child: ListTile(
                title: const Text('Steps'),
                trailing: Text('$_steps', style: const TextStyle(fontSize: 24,fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                title: const Text('Distance'),
                subtitle: const Text('GPS-based (best accuracy)'),
                trailing: Text('$km km', style: const TextStyle(fontSize: 24,fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                title: const Text('Elevation Gain'),
                subtitle: Text(_barometerAvailable ? 'Barometer-based' : 'GPS altitude (fallback)'),
                trailing: Text('$elev m', style: const TextStyle(fontSize: 24,fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),
            if (_status.isNotEmpty)
              Text(_status, style: const TextStyle(color: Colors.grey)),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _tracking ? null : _start,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _tracking ? _stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.refresh),
              label: const Text('Reset'),
            ),
          ],
        ),
      ),
    );
  }
}
