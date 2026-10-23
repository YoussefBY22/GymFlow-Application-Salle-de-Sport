/// Avatars illustrés, générés par l'API externe DiceBear (gratuite, sans
/// clé et sans compte).
///
/// Chaque compte reçoit automatiquement un avatar à sa création : la
/// personne a donc une image dès le départ, sans rien téléverser. Elle
/// peut ensuite en choisir un autre dans la galerie, récupérer sa photo
/// Gravatar, ou envoyer sa propre image.
///
/// L'URL est **déterministe** : elle se calcule à partir d'une graine,
/// sans aucun appel réseau au moment de la création du compte. L'image
/// n'est téléchargée que lorsqu'elle s'affiche, et le repli habituel
/// (initiales colorées) joue si le service est injoignable.
class AvatarService {
  AvatarService._();

  static const _base = 'https://api.dicebear.com/9.x';

  /// Styles proposés dans la galerie, du plus sobre au plus ludique.
  static const styles = <({String id, String label})>[
    (id: 'initials', label: 'Initiales'),
    (id: 'thumbs', label: 'Pouces'),
    (id: 'avataaars', label: 'Personnage'),
    (id: 'bottts', label: 'Robot'),
    (id: 'fun-emoji', label: 'Émoji'),
    (id: 'shapes', label: 'Formes'),
  ];

  /// Style attribué par défaut à un nouveau compte.
  static const defaultStyle = 'thumbs';

  /// URL d'un avatar. [seed] détermine le dessin : la même graine donne
  /// toujours la même image, ce qui évite qu'un avatar change tout seul.
  static String url({
    required String seed,
    String style = defaultStyle,
    int size = 256,
  }) {
    final s = Uri.encodeQueryComponent(seed.trim().isEmpty ? 'gymflow' : seed);
    return '$_base/$style/png?seed=$s&size=$size';
  }

  /// Avatar attribué automatiquement à la création d'un compte.
  static String forNewAccount(String seed) => url(seed: seed);

  /// Galerie de propositions : un dessin par style, plus quelques
  /// variantes, pour que le choix soit réel sans être interminable.
  static List<String> gallery(String seed, {int perStyle = 2}) => [
    for (final style in styles)
      for (var i = 0; i < perStyle; i++)
        url(seed: i == 0 ? seed : '$seed-$i', style: style.id, size: 160),
  ];

  /// S'agit-il d'un avatar généré (par opposition à une photo envoyée) ?
  static bool isGenerated(String? path) =>
      path != null && path.startsWith(_base);
}
