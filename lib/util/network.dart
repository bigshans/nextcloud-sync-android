import 'package:connectivity_plus/connectivity_plus.dart';

/// True when the device is on Wi-Fi or Ethernet.
Future<bool> isOnWifi() async {
  try {
    final results = await Connectivity().checkConnectivity();
    return results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
  } catch (_) {
    return true; // never block syncing because of a probe failure
  }
}
