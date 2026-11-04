import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../models/analytics.dart';
import '../../services/analytics_service.dart';
import '../../services/backend.dart';
import '../../services/ga_report_service.dart';
import '../../widgets/animations.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';

/// Couleur de repère de Google Analytics : sert uniquement à distinguer
/// visuellement l'onglet qui vient de Google de celui qui vient de GymFlow.
const _gaColor = Color(0xFFB45309);
const _gaSoft = Color(0xFFFFF1DC);

/// Statistiques d'usage (super admin).
///
/// Deux sources, volontairement séparées :
/// - **GymFlow** : compteurs anonymes tenus par l'application, instantanés ;
/// - **Google Analytics** : rapports lus chez Google, clairement étiquetés.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  static const _periods = [7, 14, 30];
  int _days = 14;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Statistiques'),
          bottom: const TabBar(
            tabs: [
              Tab(
                key: Key('stats_tab_local'),
                icon: Icon(Icons.fitness_center),
                text: 'GymFlow',
              ),
              Tab(
                key: Key('stats_tab_ga'),
                icon: Icon(Icons.analytics_outlined),
                text: 'Google Analytics',
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
              child: Row(
                children: [
                  Text('Période', style: AppText.label()),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: SegmentedButton<int>(
                      key: const Key('stats_period'),
                      showSelectedIcon: false,
                      segments: [
                        for (final d in _periods)
                          ButtonSegment(value: d, label: Text('$d j')),
                      ],
                      selected: {_days},
                      onSelectionChanged: (s) =>
                          setState(() => _days = s.first),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _LocalTab(days: _days),
                  _GaTab(days: _days),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// Onglet « GymFlow » : compteurs anonymes de l'application
// =========================================================================

class _LocalTab extends StatelessWidget {
  const _LocalTab({required this.days});
  final int days;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return ListenableBuilder(
      listenable: b.bus,
      builder: (context, _) {
        final a = b.analytics.summary(days: days);
        final members = b.users.where((u) => u.isMember);
        final consenting = members.where((u) => u.privacy.analytics).length;
        final realProducts = b.dashboard.topProducts(limit: 8);
        return ListView(
          padding: pagePadding(context, bottom: Gap.l),
          children: [
            _SourceBanner(
              icon: Icons.fitness_center,
              color: AppColors.heading,
              soft: AppColors.cream,
              title: 'Source : GymFlow (dans l\'application)',
              text:
                  'Compteurs anonymes tenus par l\'application : aucun nom, '
                  'aucun compte, seulement « tel jour, tant de fois ». Ils '
                  'comptent les abonnés et s\'accumulent à partir de la mise '
                  'en service de cette fonction.',
            ),
            const SizedBox(height: Gap.m),
            if (a.isEmpty)
              const GfCard(
                child: InfoRow(
                  Icons.hourglass_empty,
                  'Pas encore de mesure sur cette période. Dès que des '
                  'abonnés consultent des produits, des cours ou passent '
                  'commande, les chiffres apparaissent ici.',
                ),
              )
            else ...[
              _kpis(context, a),
              const SectionHeader('Activité par jour'),
              GfCard(
                child: GfBarChart(
                  bars: [
                    for (final (d, n) in a.perDay)
                      ('${d.substring(8)}/${d.substring(5, 7)}', n.toDouble()),
                  ],
                  color: AppColors.heading,
                ),
              ),
              const SectionHeader('Parcours d\'achat'),
              _Funnel(
                steps: [
                  ('Produits consultés', a.views),
                  ('Ajoutés au panier', a.carts),
                  ('Unités achetées', a.purchasedUnits),
                ],
              ),
              const SectionHeader('Produits : consultés, panier, achetés'),
              _ProductsTable(items: a.products.take(10).toList()),
              const SectionHeader('Cours'),
              _CoursesTable(items: a.courses.take(10).toList()),
              const SectionHeader('Recherches les plus fréquentes'),
              _TermList(
                items: a.searches.take(8).toList(),
                empty: 'Aucune recherche mesurée.',
              ),
              const SectionHeader('Recherches sans résultat'),
              _TermList(
                items: a.emptySearches.take(8).toList(),
                empty: 'Toutes les recherches ont donné un résultat.',
                note:
                    'Ce que les abonnés cherchent et que la salle ne propose '
                    'pas encore : des idées de produits ou de cours.',
              ),
              const SectionHeader('Comptes'),
              GfCard(
                child: Column(
                  children: [
                    _kv('Connexions par e-mail', a.logins['password'] ?? 0),
                    _kv('Connexions avec Google', a.logins['google'] ?? 0),
                    _kv('Inscriptions par e-mail', a.signups['password'] ?? 0),
                    _kv('Inscriptions avec Google', a.signups['google'] ?? 0),
                  ],
                ),
              ),
              const SectionHeader('Entraînement et assistant'),
              GfCard(
                child: Column(
                  children: [
                    _kv(
                      'Séances lancées',
                      a.total(AnalyticsEvents.workoutStart),
                    ),
                    _kv(
                      'Séances terminées',
                      a.total(AnalyticsEvents.workoutComplete),
                    ),
                    _kv(
                      'Séances partagées',
                      a.total(AnalyticsEvents.sessionShare),
                    ),
                    _kv(
                      'Questions posées à l\'assistant',
                      a.total(AnalyticsEvents.chatQuestion),
                    ),
                  ],
                ),
              ),
            ],
            const SectionHeader('Achats réels (toutes les commandes)'),
            _RankedList(
              items: realProducts,
              unit: 'vendus',
              empty: 'Aucune commande pour le moment.',
              note:
                  'Calculé sur les commandes enregistrées, depuis toujours : '
                  'fiable même avant la mesure d\'audience.',
            ),
            const SectionHeader('Mesure d\'audience'),
            GfCard(
              child: InfoRow(
                Icons.verified_user_outlined,
                '$consenting abonné(s) sur ${members.length} ont accepté '
                'd\'être comptés par Google Analytics.',
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _kpis(BuildContext context, LocalAnalytics a) {
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: isWide(context) ? 4 : 2,
        mainAxisSpacing: Gap.s,
        crossAxisSpacing: Gap.s,
        mainAxisExtent: 84,
      ),
      children: [
        _Kpi(
          icon: Icons.visibility_outlined,
          value: '${a.views}',
          label: 'Produits consultés',
        ),
        _Kpi(
          icon: Icons.add_shopping_cart,
          value: '${a.carts}',
          label: 'Ajouts au panier',
        ),
        _Kpi(
          icon: Icons.receipt_long,
          value: '${a.orders}',
          label: 'Commandes · ${Fmt.money(a.revenue)}',
          color: AppColors.success,
        ),
        _Kpi(
          icon: Icons.event_available,
          value: '${a.courses.fold<int>(0, (s, c) => s + c.reservations)}',
          label: 'Places réservées',
        ),
        _Kpi(
          icon: Icons.login,
          value: '${a.total(AnalyticsEvents.login)}',
          label: 'Connexions',
        ),
        _Kpi(
          icon: Icons.person_add_alt,
          value: '${a.total(AnalyticsEvents.signUp)}',
          label: 'Inscriptions',
        ),
        _Kpi(
          icon: Icons.search,
          value: '${a.total(AnalyticsEvents.search)}',
          label: 'Recherches',
        ),
        _Kpi(
          icon: Icons.sports_gymnastics,
          value: '${a.total(AnalyticsEvents.workoutComplete)}',
          label: 'Séances terminées',
        ),
      ],
    );
  }
}

// =========================================================================
// Onglet « Google Analytics » : rapports lus chez Google
// =========================================================================

class _GaTab extends StatefulWidget {
  const _GaTab({required this.days});
  final int days;

  @override
  State<_GaTab> createState() => _GaTabState();
}

class _GaTabState extends State<_GaTab> with AutomaticKeepAliveClientMixin {
  bool _checking = true;
  bool _connected = false;
  bool _loading = false;
  bool _testing = false;
  Object? _error;
  GaReport? _report;
  GaRealtime? _realtime;

  @override
  bool get wantKeepAlive => true;

  GaReportService get _ga => Backend.I.gaReport;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(_GaTab old) {
    super.didUpdateWidget(old);
    if (old.days != widget.days && _connected) _load();
  }

  Future<void> _init() async {
    if (!_ga.configured) {
      setState(() => _checking = false);
      return;
    }
    final ok = await _ga.isConnected();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _connected = ok;
    });
    if (ok) await _load();
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    try {
      final ok = await _ga.connect();
      if (!mounted) return;
      setState(() => _connected = ok);
      if (ok) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _ga.report(days: widget.days),
        _ga.realtime(),
      ]);
      if (!mounted) return;
      setState(() {
        _report = results[0] as GaReport;
        _realtime = results[1] as GaRealtime;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendTest() async {
    setState(() => _testing = true);
    final r = await Backend.I.analytics.sendTest();
    if (!mounted) return;
    setState(() => _testing = false);
    showSnack(context, r.message, error: !r.ok);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final b = Backend.I;
    final members = b.users.where((u) => u.isMember);
    final consenting = members.where((u) => u.privacy.analytics).length;
    return ListView(
      padding: pagePadding(context, bottom: Gap.l),
      children: [
        _SourceBanner(
          key: const Key('ga_banner'),
          icon: Icons.analytics_outlined,
          color: _gaColor,
          soft: _gaSoft,
          title: 'Source : Google Analytics 4',
          text:
              'Ces chiffres viennent de Google, pas de GymFlow. Ils ne '
              'couvrent que les abonnés qui ont activé la mesure d\'audience '
              '($consenting sur ${members.length}) et peuvent avoir quelques '
              'heures de retard.',
        ),
        const SizedBox(height: Gap.m),
        if (_checking)
          const Padding(
            padding: EdgeInsets.all(Gap.xl),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (!_ga.configured || !Backend.I.analytics.canSend)
          _setup(context)
        else if (!_connected)
          _connectCard()
        else
          ..._reports(context),
      ],
    );
  }

  Widget _setup(BuildContext context) {
    final steps = <String>[
      'Dans analytics.google.com, créez une propriété Google Analytics 4 et '
          'un flux de données « Web ».',
      'Copiez l\'ID de mesure (G-…) → GA_MEASUREMENT_ID.',
      'Dans le flux, « Secrets de l\'API Measurement Protocol » → créez un '
          'secret → GA_API_SECRET.',
      'Admin → Paramètres de la propriété : copiez l\'ID de propriété '
          '(chiffres) → GA_PROPERTY_ID.',
      'Dans Google Cloud (projet GymFlow), activez « Google Analytics Data '
          'API » et ajoutez le champ d\'application analytics.readonly à '
          'l\'écran de consentement.',
      'Ajoutez les trois valeurs dans secrets.json puis reconstruisez '
          'l\'application.',
    ];
    return GfCard(
      key: const Key('ga_setup'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Google Analytics n\'est pas encore configuré',
            style: AppText.title(size: 17),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            'Tant que les clés sont absentes, rien n\'est envoyé à Google : '
            'l\'onglet GymFlow reste complet.',
            style: AppText.body(size: 14, color: AppColors.inkSoft),
          ),
          const SizedBox(height: Gap.s),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 11,
                    backgroundColor: _gaColor,
                    child: Text(
                      '${i + 1}',
                      style: AppText.label(color: AppColors.white, size: 12),
                    ),
                  ),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: Text(steps[i], style: AppText.body(size: 14)),
                  ),
                ],
              ),
            ),
          if (!AppConfig.gaCanRead && AppConfig.gaCanSend)
            const InfoRow(
              Icons.info_outline,
              'L\'envoi est prêt ; il manque GA_PROPERTY_ID pour la lecture.',
            ),
        ],
      ),
    );
  }

  Widget _connectCard() {
    return GfCard(
      key: const Key('ga_connect'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Autoriser la lecture des rapports',
            style: AppText.title(size: 17),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            'Connectez-vous avec le compte Google qui a accès à la propriété '
            'Analytics. L\'application ne reçoit qu\'un accès en lecture '
            'seule, sans mot de passe.',
            style: AppText.body(size: 14, color: AppColors.inkSoft),
          ),
          if (_error != null) ...[
            const SizedBox(height: Gap.s),
            Text(
              friendlyError(_error!),
              style: AppText.body(size: 14, color: AppColors.redText),
            ),
          ],
          const SizedBox(height: Gap.m),
          ElevatedButton.icon(
            key: const Key('ga_connect_button'),
            onPressed: _connect,
            icon: const Icon(Icons.login),
            label: const Text('Se connecter avec Google'),
          ),
        ],
      ),
    );
  }

  List<Widget> _reports(BuildContext context) {
    final r = _report;
    final rt = _realtime;
    return [
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('ga_refresh'),
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
              label: Text(_loading ? 'Chargement…' : 'Actualiser'),
            ),
          ),
          const SizedBox(width: Gap.s),
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('ga_test'),
              onPressed: _testing ? null : _sendTest,
              icon: const Icon(Icons.send_outlined),
              label: Text(_testing ? 'Envoi…' : 'Événement de test'),
            ),
          ),
        ],
      ),
      if (_error != null) ...[
        const SizedBox(height: Gap.s),
        GfCard(
          color: AppColors.redSoft,
          child: InfoRow(Icons.error_outline, friendlyError(_error!)),
        ),
      ],
      if (_loading && r == null)
        const Padding(
          padding: EdgeInsets.all(Gap.xl),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (rt != null) ...[
        const SectionHeader('En direct (30 dernières minutes)'),
        GfCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt, color: _gaColor),
                  const SizedBox(width: Gap.s),
                  Text('${rt.activeUsers}', style: AppText.stat(size: 28)),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: Text(
                      'utilisateur(s) actif(s)',
                      style: AppText.label(),
                    ),
                  ),
                ],
              ),
              if (rt.events.isNotEmpty) const Divider(),
              for (final e in rt.events.take(8))
                _kvRow(AnalyticsEvents.label(e.name), '${e.count}'),
            ],
          ),
        ),
      ],
      if (r != null) ...[
        SectionHeader('Les ${r.days} derniers jours'),
        if (r.isEmpty)
          const GfCard(
            child: InfoRow(
              Icons.hourglass_empty,
              'Google n\'a encore rien enregistré. Un premier événement peut '
              'mettre plusieurs heures à apparaître : utilisez « Événement de '
              'test » puis regardez « En direct ».',
            ),
          )
        else ...[
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: isWide(context) ? 4 : 2,
              mainAxisSpacing: Gap.s,
              crossAxisSpacing: Gap.s,
              mainAxisExtent: 84,
            ),
            children: [
              _Kpi(
                icon: Icons.group_outlined,
                value: '${r.activeUsers}',
                label: 'Utilisateurs actifs',
                color: _gaColor,
              ),
              _Kpi(
                icon: Icons.person_add_alt,
                value: '${r.newUsers}',
                label: 'Nouveaux utilisateurs',
                color: _gaColor,
              ),
              _Kpi(
                icon: Icons.timelapse,
                value: '${r.sessions}',
                label: 'Sessions',
                color: _gaColor,
              ),
              _Kpi(
                icon: Icons.touch_app_outlined,
                value: '${r.eventCount}',
                label: 'Événements',
                color: _gaColor,
              ),
            ],
          ),
          const SectionHeader('Utilisateurs actifs par jour'),
          GfCard(
            child: GfBarChart(
              bars: [
                for (final (d, users, _) in r.daily)
                  (
                    d.length == 10
                        ? '${d.substring(8)}/${d.substring(5, 7)}'
                        : d,
                    users.toDouble(),
                  ),
              ],
              color: _gaColor,
            ),
          ),
          const SectionHeader('Événements'),
          GfCard(
            child: Column(
              children: [
                for (final e in r.events.take(15))
                  _kvRow(
                    AnalyticsEvents.label(e.name),
                    '${e.count} · ${e.users} utilisateur(s)',
                  ),
              ],
            ),
          ),
          const SectionHeader('Produits (e-commerce Google)'),
          if (r.items.isEmpty)
            const GfCard(
              child: InfoRow(
                Icons.info_outline,
                'Aucun produit mesuré par Google pour le moment.',
              ),
            )
          else
            GfCard(
              child: Column(
                children: [
                  for (final i in r.items.take(10))
                    _kvRow(
                      i.name,
                      '${i.viewed} vues · ${i.addedToCart} panier · '
                      '${i.purchased} achetés',
                    ),
                ],
              ),
            ),
          if (r.devices.isNotEmpty) ...[
            const SectionHeader('Appareils'),
            GfCard(
              child: Column(
                children: [
                  for (final (d, n) in r.devices)
                    _kvRow(switch (d) {
                      'mobile' => 'Téléphone',
                      'desktop' => 'Ordinateur',
                      'tablet' => 'Tablette',
                      _ => d,
                    }, '$n'),
                ],
              ),
            ),
          ],
        ],
      ],
    ];
  }
}

// =========================================================================
// Éléments communs
// =========================================================================

/// Bandeau qui dit d'où viennent les chiffres de l'onglet.
class _SourceBanner extends StatelessWidget {
  const _SourceBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.soft,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final Color soft;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(Gap.radius),
        border: Border(left: BorderSide(color: color, width: 5)),
      ),
      padding: const EdgeInsets.all(Gap.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.subtitle(size: 15, color: color)),
                const SizedBox(height: 2),
                Text(text, style: AppText.body(size: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.icon,
    required this.value,
    required this.label,
    this.color = AppColors.navy,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GfCard(
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
      child: Row(
        children: [
          Icon(icon, color: AppColors.fg(color)),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.stat(color: AppColors.fg(color), size: 20),
                ),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label(size: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _kv(String label, int value) => _kvRow(label, Fmt.number(value));

Widget _kvRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 5),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: Text(label, style: AppText.body(size: 14))),
      const SizedBox(width: Gap.s),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.right,
          style: AppText.subtitle(size: 14),
        ),
      ),
    ],
  ),
);

/// Entonnoir : chaque étape avec sa part de l'étape précédente.
class _Funnel extends StatelessWidget {
  const _Funnel({required this.steps});
  final List<(String, int)> steps;

  @override
  Widget build(BuildContext context) {
    final top = steps.first.$2;
    return GfCard(
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          steps[i].$1,
                          style: AppText.subtitle(size: 13),
                        ),
                      ),
                      Text(
                        '${steps[i].$2}'
                        '${i > 0 && steps[i - 1].$2 > 0 ? ' · ${(steps[i].$2 * 100 / steps[i - 1].$2).round()} % de l\'étape précédente' : ''}',
                        style: AppText.label(size: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  AnimatedBar(
                    value: top == 0 ? 0 : (steps[i].$2 / top).clamp(0, 1),
                    color: i == steps.length - 1
                        ? AppColors.success
                        : AppColors.heading,
                    height: 8,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProductsTable extends StatelessWidget {
  const _ProductsTable({required this.items});
  final List<ProductActivity> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const GfCard(
        child: InfoRow(Icons.info_outline, 'Aucun produit mesuré.'),
      );
    }
    return GfCard(
      child: Column(
        children: [
          for (final p in items)
            _kvRow(
              p.name,
              '${p.views} vues · ${p.carts} panier · ${p.purchased} achetés'
              '${p.revenue > 0 ? ' · ${Fmt.money(p.revenue)}' : ''}',
            ),
        ],
      ),
    );
  }
}

class _CoursesTable extends StatelessWidget {
  const _CoursesTable({required this.items});
  final List<CourseActivity> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const GfCard(
        child: InfoRow(Icons.info_outline, 'Aucun cours mesuré.'),
      );
    }
    return GfCard(
      child: Column(
        children: [
          for (final c in items)
            _kvRow(
              c.title,
              '${c.views} vues · ${c.reservations} réservés · '
              '${c.waitlisted} attente · ${c.cancellations} annulés',
            ),
        ],
      ),
    );
  }
}

class _TermList extends StatelessWidget {
  const _TermList({required this.items, required this.empty, this.note});
  final List<(String, int)> items;
  final String empty;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return _RankedList(items: items, unit: 'fois', empty: empty, note: note);
  }
}

class _RankedList extends StatelessWidget {
  const _RankedList({
    required this.items,
    required this.unit,
    required this.empty,
    this.note,
  });

  final List<(String, int)> items;
  final String unit;
  final String empty;
  final String? note;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return GfCard(child: InfoRow(Icons.info_outline, empty));
    }
    final max = items.first.$2;
    return GfCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: Text(note!, style: AppText.label(size: 12)),
            ),
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          items[i].$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.subtitle(size: 13),
                        ),
                      ),
                      Text(
                        '${items[i].$2} $unit',
                        style: AppText.label(size: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  AnimatedBar(
                    value: max == 0 ? 0 : items[i].$2 / max,
                    height: 6,
                    color: i == 0 ? AppColors.red : AppColors.heading,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
