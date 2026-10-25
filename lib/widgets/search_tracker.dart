import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/backend.dart';

/// Mesure une recherche une fois la saisie terminée.
///
/// Écoute le champ de recherche et attend [delay] sans nouvelle frappe avant
/// de compter la recherche : on ne mesure pas « w », « wh », « whe »…
/// mais « whey ». [results] est évalué à ce moment-là pour savoir si la
/// recherche a donné quelque chose (une recherche sans résultat indique ce
/// que les membres veulent et que la salle ne propose pas).
class SearchTracker {
  SearchTracker(
    this.controller,
    this.results, {
    this.delay = const Duration(milliseconds: 1500),
  }) {
    controller.addListener(_changed);
  }

  final TextEditingController controller;
  final int Function() results;
  final Duration delay;

  Timer? _timer;
  String _last = '';

  void _changed() {
    final text = controller.text;
    if (text == _last) return; // simple déplacement du curseur
    _last = text;
    _timer?.cancel();
    if (text.trim().length < 2) return;
    _timer = Timer(delay, () {
      if (!Backend.isReady) return;
      try {
        Backend.I.analytics.search(text, results: results());
      } catch (_) {
        // Mesurer ne doit jamais gêner la recherche.
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    controller.removeListener(_changed);
  }
}
