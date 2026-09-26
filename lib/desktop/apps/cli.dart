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

CliCommand parseCli(List<String> args) => (args.length >= 2 && args[0] == 'open') ? OpenApp(args[1]) : const ShowWindow();
