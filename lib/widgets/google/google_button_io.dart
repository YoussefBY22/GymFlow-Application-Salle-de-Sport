import 'package:flutter/widgets.dart';

/// Hors web, Google n'impose aucun bouton : l'application ouvre elle-même
/// la fenêtre de connexion. Cette implémentation n'est donc jamais
/// utilisée, elle existe pour que le code compile sur Android.
Widget? googleRenderedButton() => null;
