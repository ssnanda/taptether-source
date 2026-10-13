import 'discovery.dart';

/// Strict dotted-decimal address for the LAN-only SSH installer. Rejects
/// partial addresses, extra dots, whitespace and ambiguous leading zeroes.
bool validUbuntuLanIp(String value) {
  if (!RegExp(r'^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$')
      .hasMatch(value)) {
    return false;
  }
  return isPrivateIPv4(value);
}
