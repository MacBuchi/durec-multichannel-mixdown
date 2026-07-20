import 'package:flutter/material.dart';

/// Ask for a custom integrated-loudness target; returns the clamped value
/// or null on cancel.
Future<double?> askCustomLufs(BuildContext context, double initial) {
  final controller = TextEditingController(text: initial.toStringAsFixed(1));
  return showDialog<double>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Custom LUFS target'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(
          signed: true,
          decimal: true,
        ),
        decoration: const InputDecoration(
          labelText: 'Integrated loudness (−30 … −6 LUFS)',
        ),
        onSubmitted: (_) => Navigator.of(
          context,
        ).pop(double.tryParse(controller.text)?.clamp(-30.0, -6.0)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(double.tryParse(controller.text)?.clamp(-30.0, -6.0)),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
