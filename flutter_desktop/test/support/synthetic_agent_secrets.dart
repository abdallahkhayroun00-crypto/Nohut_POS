// SYNTHETIC TEST ADAPTER ONLY. Production uses WindowsAgentSecrets / DPAPI.
import 'dart:convert';

import 'package:nohut_falafel_desktop/supabase_agent_transport.dart';
import 'package:nohut_falafel_desktop/windows_agent_setup.dart';

class SyntheticAgentSecrets implements AgentSetupSecrets {
  Map<String, dynamic>? persisted;
  bool busy = false;
  int saves = 0;
  @override
  Future<Map<String, dynamic>?> load() async => persisted == null
      ? null
      : Map<String, dynamic>.from(jsonDecode(jsonEncode(persisted)) as Map);
  @override
  Future<void> save(Map<String, dynamic> fields) async {
    saves++;
    persisted = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(fields)) as Map,
    );
  }

  @override
  Future<T> exclusively<T>(Future<T> Function() action) async {
    if (busy) throw const AgentTransportException('setup_busy');
    busy = true;
    try {
      return await action();
    } finally {
      busy = false;
    }
  }
}
