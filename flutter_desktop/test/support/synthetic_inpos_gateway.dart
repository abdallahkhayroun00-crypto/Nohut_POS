// Synthetic only. Never connects to a terminal or payment processor.
import 'package:nohut_falafel_desktop/card_terminal.dart';

class SyntheticInposGateway implements InposGateway {
  @override
  bool get ready => true;
  int sends = 0, queries = 0;
  TerminalReply reply = const TerminalReply(TerminalStatus.unknown);
  @override
  Future<TerminalReply> pay(String reference, int amount) async {
    sends++;
    return reply;
  }

  @override
  Future<TerminalReply> inquire(String reference) async {
    queries++;
    return reply;
  }
}
