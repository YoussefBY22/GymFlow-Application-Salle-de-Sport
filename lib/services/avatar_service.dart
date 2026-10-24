/// Avatars générés par l'API externe DiceBear (gratuite, sans clé et sans
/// compte).
///
/// Par défaut, chaque compte reçoit **ses initiales** sur une couleur qui
/// lui est propre : « Ahmed Gharbi » devient « AG ». La personne peut
/// ensuite choisir parmi une centaine de dessins, récupérer sa photo
/// Gravatar, ou envoyer sa propre image.
///
/// Toutes les URL sont **calculées**, sans aucun appel réseau : l'image
/// n'est téléchargée que lorsqu'elle s'affiche, et le repli habituel
/// (initiales colorées dessinées par l'application) joue si le service est
/// injoignable.
class AvatarService {
  AvatarService._();

  static const _base = 'https://api.dicebear.com/9.x';

  /// Couleurs de fond des initiales. Toutes assez sombres pour un texte
  /// blanc lisible (contraste suffisant), avec les deux couleurs de la
  /// charte (marine et rouge) en tête.
  static const palette = <String>[
    '002855', // marine (charte)
    'BA0C2F', // rouge (charte)
    '0F766E', // vert canard
    '6D28D9', // violet
    'C2410C', // orange brûlé
    '1D4ED8', // bleu
    'BE185D', // rose
    '4D7C0F', // olive
    '334155', // ardoise
    '4338CA', // indigo
    '9A3412', // brique
    '0E7490', // turquoise
  ];

  /// Styles illustrés de la galerie, avec leur intitulé.
  static const styles = <({String id, String label})>[
    (id: 'adventurer', label: 'Aventurier'),
    (id: 'avataaars', label: 'Personnage'),
    (id: 'lorelei', label: 'Portrait'),
    (id: 'micah', label: 'Visage'),
    (id: 'big-smile', label: 'Sourire'),
    (id: 'open-peeps', label: 'Croquis'),
    (id: 'notionists', label: 'Esquisse'),
    (id: 'pixel-art', label: 'Pixels'),
    (id: 'bottts', label: 'Robot'),
    (id: 'fun-emoji', label: 'Émoji'),
    (id: 'thumbs', label: 'Pouces'),
    (id: 'shapes', label: 'Formes'),
  ];

  /// Nombre de variantes proposées par style.
  static const variantsPerStyle = 8;

  /// Nettoie un nom pour en faire une graine : espaces superflus retirés,
  /// repli sur « gymflow » si rien ne reste.
  static String _seed(String name) {
    final s = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    return s.isEmpty ? 'gymflow' : s;
  }

  /// Couleur attribuée à un nom : toujours la même pour la même personne,
  /// sans dépendre de `String.hashCode` (qui peut varier d'une plateforme
  /// à l'autre, ce qui changerait la couleur entre le téléphone et le web).
  static String colorFor(String name) {
    var h = 7;
    for (final c in _seed(name).toLowerCase().codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  /// Initiales d'un nom sur la couleur [color] (hexadécimal sans « # »).
  static String initials(String name, {String? color, int size = 256}) {
    final bg = color ?? colorFor(name);
    return '$_base/initials/png?seed=${Uri.encodeQueryComponent(_seed(name))}'
        '&size=$size&backgroundColor=$bg&textColor=ffffff&fontWeight=700';
  }

  /// Dessin d'un style donné. [variant] 0 donne le dessin « de base » du
  /// nom ; les suivants en sont des variantes, pour offrir du choix.
  static String illustrated(
    String name, {
    required String style,
    int variant = 0,
    int size = 256,
  }) {
    final seed = variant == 0 ? _seed(name) : '${_seed(name)} #$variant';
    return '$_base/$style/png?seed=${Uri.encodeQueryComponent(seed)}'
        '&size=$size';
  }

  /// Avatar attribué automatiquement à la création d'un compte : les
  /// initiales du nom, sur la couleur de la personne.
  static String forNewAccount(String fullName) => initials(fullName);

  /// Sections de la galerie : d'abord les initiales (une couleur au
  /// choix), puis chaque style illustré avec ses variantes.
  static List<({String title, List<String> urls})> sections(String name) => [
    (
      title: 'Mes initiales',
      urls: [for (final c in palette) initials(name, color: c, size: 160)],
    ),
    for (final s in styles)
      (
        title: s.label,
        urls: [
          for (var i = 0; i < variantsPerStyle; i++)
            illustrated(name, style: s.id, variant: i, size: 160),
        ],
      ),
  ];

  /// Nombre total de propositions de la galerie.
  static int get galleryCount => palette.length + styles.length * variantsPerStyle;

  /// S'agit-il d'un avatar généré (par opposition à une photo envoyée) ?
  static bool isGenerated(String? path) =>
      path != null && path.startsWith(_base);
}
