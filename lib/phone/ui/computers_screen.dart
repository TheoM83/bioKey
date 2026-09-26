import 'package:flutter/material.dart';

import '../../core/storage/phone_store.dart';
import '../service/link_coordinator.dart' show isValidHost;

/// The phone role's home screen: the list of paired PCs (or an empty-state
/// CTA when there are none) and the FAB that starts pairing a new one.
///
/// Stateless and driven entirely by parameters (no controller/plugin access)
/// so it is testable without any platform plugins.
final class ComputersScreen extends StatelessWidget {
  const ComputersScreen({
    super.key,
    required this.pcs,
    required this.isOnline,
    required this.needsRepair,
    required this.onScan,
    required this.onRevoke,
    required this.onSetHost,
  });

  final List<PairedPc> pcs;
  final bool Function(String pcId) isOnline;
  final Set<String> needsRepair;
  final VoidCallback onScan;
  final void Function(String pcId) onRevoke;
  final void Function(String pcId, String host) onSetHost;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BioKey')),
      body: pcs.isEmpty
          ? const _EmptyState()
          : _PcList(pcs: pcs, isOnline: isOnline, needsRepair: needsRepair, onRevoke: onRevoke, onSetHost: onSetHost),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scanner un QR'),
        onPressed: onScan,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fingerprint, size: 64),
          SizedBox(height: 16),
          Text('Aucun ordinateur appairé'),
        ],
      ),
    );
  }
}

class _PcList extends StatelessWidget {
  const _PcList({
    required this.pcs,
    required this.isOnline,
    required this.needsRepair,
    required this.onRevoke,
    required this.onSetHost,
  });

  final List<PairedPc> pcs;
  final bool Function(String pcId) isOnline;
  final Set<String> needsRepair;
  final void Function(String pcId) onRevoke;
  final void Function(String pcId, String host) onSetHost;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: pcs.length,
      itemBuilder: (context, i) {
        final pc = pcs[i];
        final repair = needsRepair.contains(pc.pcId);
        final online = isOnline(pc.pcId);
        final status = repair ? 'Réappairage nécessaire' : (online ? 'Connecté' : 'Hors ligne');
        final color = repair ? Colors.orange : (online ? Colors.green : Colors.grey);
        return Dismissible(
          key: ValueKey(pc.pcId),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) => _confirmRevoke(context, pc.name),
          onDismissed: (_) => onRevoke(pc.pcId),
          child: ListTile(
            leading: Icon(Icons.circle, color: color, size: 12),
            title: Text(pc.name),
            subtitle: Text(status),
            onLongPress: () => _showSetHostDialog(context, pc),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'host') _showSetHostDialog(context, pc);
              },
              itemBuilder: (context) => const [
                PopupMenuItem<String>(value: 'host', child: Text("Modifier l'adresse…")),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSetHostDialog(BuildContext context, PairedPc pc) => showDialog<void>(
        context: context,
        builder: (dialogContext) => _SetHostDialog(pc: pc, onSetHost: onSetHost),
      );

  Future<bool> _confirmRevoke(BuildContext context, String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Révoquer $name ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Révoquer')),
        ],
      ),
    );
    return result ?? false;
  }
}

/// The « Modifier l'adresse… » dialog: a [TextEditingController] tied to
/// this widget's own lifecycle (created in [initState], disposed in
/// [dispose]) — rather than one owned by the caller — so it is never
/// disposed while the dialog's closing transition is still animating it.
class _SetHostDialog extends StatefulWidget {
  const _SetHostDialog({required this.pc, required this.onSetHost});

  final PairedPc pc;
  final void Function(String pcId, String host) onSetHost;

  @override
  State<_SetHostDialog> createState() => _SetHostDialogState();
}

class _SetHostDialogState extends State<_SetHostDialog> {
  late final _controller = TextEditingController(text: widget.pc.host);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("Modifier l'adresse de ${widget.pc.name}"),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Adresse'),
          validator: (v) => isValidHost((v ?? '').trim()) ? null : 'Adresse invalide',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        TextButton(
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              widget.onSetHost(widget.pc.pcId, _controller.text.trim());
              Navigator.pop(context);
            }
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
