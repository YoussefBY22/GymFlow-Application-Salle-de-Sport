import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'backend.dart';

/// Photo de profil Gravatar (API externe, gratuite et sans clé).
///
/// Gravatar associe une photo à une adresse e-mail : beaucoup de personnes
/// en ont déjà une sans le savoir, parce qu'elles ont utilisé un forum, un
/// service de développement ou WordPress. L'application propose donc de la
/// récupérer, pour avoir une photo de profil sans avoir à en téléverser.
///
/// L'adresse n'est jamais envoyée en clair : Gravatar demande son
/// empreinte, qui sert d'identifiant dans l'URL de l'image.
class GravatarService {
  GravatarService(this._b);
  final Backend _b;

  static const host = 'https://www.gravatar.com/avatar/';

  /// Empreinte attendue par Gravatar : MD5 de l'adresse nettoyée
  /// (espaces retirés, minuscules).
  static String hashOf(String email) =>
      md5.convert(utf8.encode(email.trim().toLowerCase())).toString();

  /// URL de la photo. `d=404` est la clé du procédé : sans ce paramètre,
  /// Gravatar renverrait toujours une image générique et on ne pourrait
  /// pas savoir si la personne en a réellement une.
  static String urlFor(String email, {int size = 256}) =>
      '$host${hashOf(email)}?s=$size&d=404';

  /// Cherche la photo associée à l'adresse.
  ///
  /// Renvoie l'URL si une photo existe, `null` si la personne n'a pas de
  /// compte Gravatar (404) ou si le service est injoignable : dans les
  /// deux cas l'application garde simplement les initiales.
  Future<String?> photoFor(String email) async {
    if (email.trim().isEmpty) return null;
    final url = urlFor(email);
    try {
      final res = await _b.httpClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      // Une réponse vide ou qui n'est pas une image ne sert à rien.
      final type = res.headers['content-type'] ?? '';
      if (!type.startsWith('image/') || res.bodyBytes.isEmpty) return null;
      return url;
    } catch (_) {
      return null;
    }
  }
}
