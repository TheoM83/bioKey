sealed class CliCommand {
  const CliCommand();
}

final class OpenApp extends CliCommand {
  const OpenApp(this.id);
  final String id;
}

final class ShowWindow extends CliCommand {
  const ShowWindow();
}

/// Flag the autostart entry launches BioKey with: start in the tray only.
const hiddenFlag = '--hidden';

/// Parses the command line; [hiddenFlag] is a startup option, not a
/// command, and is ignored here.
CliCommand parseCli(List<String> args) {
  final a = args.where((x) => x != hiddenFlag).toList();
  return (a.length >= 2 && a[0] == 'open') ? OpenApp(a[1]) : const ShowWindow();
}
