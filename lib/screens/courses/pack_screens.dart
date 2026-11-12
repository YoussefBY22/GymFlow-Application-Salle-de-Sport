import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/responsive.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../models/session_pack.dart';
import '../../services/backend.dart';
import '../../services/payment/payment_gateway.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../shop/shop_screens.dart' show HostedCheckoutPage;

/// Couleur et libellé de l'état d'un carnet.
(String, Color) packStatus(SessionPack p, DateTime now) {
  if (p.isExpiredAt(now)) return ('Expiré', AppColors.divider);
  if (p.kind == PackKind.credits && p.remaining == 0) {
    return ('Épuisé', AppColors.divider);
  }
  if (p.expiresAt.difference(now).inDays < 7) {
    return ('Expire bientôt', AppColors.gold);
  }
  return ('Actif', AppColors.successSoft);
}

/// Dernier jour de validité (la fin est exclue).
String packLastDay(SessionPack p) =>
    Fmt.date(p.expiresAt.subtract(const Duration(minutes: 1)));

/// Solde lisible : séances restantes ou cours de la semaine.
String packBalance(SessionPack p, DateTime now) => p.kind == PackKind.credits
    ? '${Fmt.plural(p.remaining, 'séance')} sur ${p.quota}'
    : '${p.usedInWeek(now)} / ${p.quota} cours cette semaine';

/// « Mes carnets » : solde, expiration, historique et achat de formules.
class MyPacksScreen extends StatefulWidget {
  const MyPacksScreen({super.key});

  @override
  State<MyPacksScreen> createState() => _MyPacksScreenState();
}

class _MyPacksScreenState extends State<MyPacksScreen> {
  late final Future<void> _sync = _refresh();

  Future<void> _refresh() async {
    final b = Backend.I;
    await b.reservationService.closeStartedWaitlists();
    await b.packs.sync(b.requireUser().id);
    b.bus.emit();
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    return Scaffold(
      appBar: AppBar(title: const Text('Mes carnets')),
      body: FutureBuilder<void>(
        future: _sync,
        builder: (context, _) => ListenableBuilder(
          listenable: b.bus,
          builder: (context, _) {
            final now = b.now();
            final packs = b.packs.myPacks().reversed.toList()
              ..sort((x, y) {
                final ax = x.isExpiredAt(now) ? 1 : 0;
                final ay = y.isExpiredAt(now) ? 1 : 0;
                return ax != ay ? ax - ay : x.expiresAt.compareTo(y.expiresAt);
              });
            final offers = b.packs.offers();
            final hours = b.packs.settings.freeCancelHours;
            return ListView(
              padding: pagePadding(context, maxWidth: 760, bottom: Gap.xl),
              children: [
                GfCard(
                  color: AppColors.cream,
                  child: Column(
                    children: [
                      const InfoRow(
                        Icons.card_membership,
                        'Avec un abonnement actif, les cours inclus sont '
                        'gratuits ; les autres cours se réservent avec un '
                        'carnet. Sans abonnement, chaque cours prend une '
                        'séance.',
                      ),
                      InfoRow(
                        Icons.event_busy,
                        'Annulation au moins $hours h avant le cours : la '
                        'séance vous est rendue. Plus tard, ou en cas '
                        'd\'absence, elle est décomptée.',
                      ),
                      const InfoRow(
                        Icons.low_priority,
                        'La séance est prise sur le carnet qui expire en '
                        'premier.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Gap.m),
                Text('Mes carnets', style: AppText.title(size: 18)),
                const SizedBox(height: Gap.s),
                if (packs.isEmpty)
                  const GfCard(
                    child: InfoRow(
                      Icons.confirmation_number_outlined,
                      'Vous n\'avez pas encore de carnet.',
                    ),
                  ),
                for (final (i, p) in packs.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: FadeSlideIn(
                      index: i,
                      child: PackCard(pack: p),
                    ),
                  ),
                const SizedBox(height: Gap.m),
                Text('Acheter une formule', style: AppText.title(size: 18)),
                const SizedBox(height: Gap.s),
                for (final o in offers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.s),
                    child: _OfferCard(offer: o),
                  ),
                if (offers.isEmpty)
                  const GfCard(
                    child: InfoRow(
                      Icons.info_outline,
                      'Aucune formule en vente pour le moment.',
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Carte d'un carnet avec son historique.
class PackCard extends StatelessWidget {
  const PackCard({super.key, required this.pack});
  final SessionPack pack;

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final p = pack;
    final now = b.now();
    final (status, color) = packStatus(p, now);
    final expired = p.isExpiredAt(now);
    return GfCard(
      key: Key('pack_${p.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(p.name, style: AppText.subtitle())),
              Pill(status, color: color),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Text(
            packBalance(p, now),
            key: Key('pack_balance_${p.id}'),
            style: AppText.stat(
              size: 20,
              color: expired ? AppColors.inkSoft : AppColors.heading,
            ),
          ),
          Text(
            '${p.kind.label} · ${p.categoriesLabel}',
            style: AppText.label(),
          ),
          Text(
            expired
                ? 'Expiré le ${packLastDay(p)}'
                : 'Valable jusqu\'au ${packLastDay(p)} '
                      '(${Fmt.plural(p.expiresAt.difference(now).inDays, 'jour')})',
            style: AppText.label(
              color: !expired && p.expiresAt.difference(now).inDays < 7
                  ? AppColors.redText
                  : AppColors.inkSoft,
            ),
          ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: Key('pack_history_${p.id}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(
                'Historique (${p.movements.length})',
                style: AppText.subtitle(size: 14),
              ),
              children: [
                if (p.movements.isEmpty)
                  Text('Aucun mouvement.', style: AppText.label()),
                for (final m in p.movements.reversed) _MovementRow(m),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow(this.m);
  final PackMovement m;

  static IconData _icon(PackMoveKind k) => switch (k) {
    PackMoveKind.reserved => Icons.lock_clock,
    PackMoveKind.consumed => Icons.check_circle_outline,
    PackMoveKind.released => Icons.undo,
    PackMoveKind.refunded => Icons.replay,
    PackMoveKind.expired => Icons.timer_off_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final r = b.reservations.byId(m.reservationId);
    final c = r == null ? null : b.courses.byId(r.courseId);
    final what = m.kind == PackMoveKind.expired
        ? '${Fmt.plural(m.count, 'séance')} non utilisée${m.count > 1 ? 's' : ''}'
        : c == null
        ? 'Réservation archivée'
        : '${c.title}${c.startAt == null ? '' : ' · ${Fmt.dateTime(c.startAt!)}'}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon(m.kind), color: AppColors.heading),
      title: Text(
        '${m.kind.label}'
        '${m.kind != PackMoveKind.expired && m.count > 1 ? ' (${m.count} séances)' : ''}'
        ' · $what',
        style: AppText.body(size: 13),
      ),
      subtitle: Text(Fmt.dateTime(m.at), style: AppText.label(size: 12)),
      onTap: c == null
          ? null
          : () => Navigator.pushNamed(
              context,
              Routes.courseDetail,
              arguments: c.id,
            ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.offer});
  final PackOffer offer;

  @override
  Widget build(BuildContext context) {
    final o = offer;
    return GfCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(o.name, style: AppText.subtitle()),
                Text(
                  '${o.quotaLabel} · ${o.validityDays} jours · '
                  '${o.categoriesLabel}',
                  style: AppText.label(),
                ),
                Text(
                  Fmt.money(o.price),
                  style: AppText.stat(size: 18, color: AppColors.redText),
                ),
              ],
            ),
          ),
          ElevatedButton(
            key: Key('buy_${o.id}'),
            style: ElevatedButton.styleFrom(minimumSize: const Size(96, 44)),
            onPressed: () => Navigator.pushNamed(
              context,
              Routes.packCheckout,
              arguments: o.id,
            ),
            child: const Text('Acheter'),
          ),
        ],
      ),
    );
  }
}

/// Paiement d'une formule : même passerelle et mêmes règles que la
/// boutique (le carnet n'est créé qu'après un paiement accepté).
class PackCheckoutScreen extends StatefulWidget {
  const PackCheckoutScreen({super.key, required this.offerId});
  final String offerId;

  @override
  State<PackCheckoutScreen> createState() => _PackCheckoutScreenState();
}

class _PackCheckoutScreenState extends State<PackCheckoutScreen> {
  final _formKey = GlobalKey<FormState>();
  final _number = TextEditingController(text: '4242 4242 4242 4242');
  final _expiry = TextEditingController(text: '12/30');
  final _cvc = TextEditingController(text: '123');
  bool _paying = false;

  @override
  void dispose() {
    for (final c in [_number, _expiry, _cvc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pay() async {
    final b = Backend.I;
    final gateway = b.payment;
    if (gateway is SimulatedPaymentGateway &&
        !_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _paying = true);
    try {
      final q = b.packs.quote(widget.offerId);
      PaymentResult? result;
      if (gateway is HostedPaymentGateway) {
        final me = b.requireUser();
        final session = await gateway.createSession(
          lines: b.packs.paymentLines(q),
          customerEmail: me.email,
          customerName: me.fullName,
          total: q.total,
          stamp: q.stamp,
        );
        if (!mounted) return;
        final finished = await Navigator.push<bool?>(
          context,
          gfRoute(HostedCheckoutPage(session: session, gateway: gateway)),
        );
        if (finished == false) {
          throw const BusinessRuleException('Paiement annulé.');
        }
        result = await gateway.verify(session.id);
      } else if (gateway is SimulatedPaymentGateway) {
        result = await gateway.charge(
          cardNumber: _number.text,
          expiry: _expiry.text,
          cvc: _cvc.text,
          amount: q.total,
          now: b.now(),
        );
      }
      if (result == null || !result.success) {
        throw const BusinessRuleException('Paiement non finalisé.');
      }
      final pack = await b.packs.buy(widget.offerId, result);
      if (mounted) {
        showSnack(context, '« ${pack.name} » ajouté à vos carnets.');
        Navigator.pop(context, pack.id);
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Backend.I;
    final offer = b.packOffers.byId(widget.offerId);
    if (offer == null || !offer.active) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.search_off,
          title: 'Formule indisponible',
          message: 'Elle n\'est plus en vente.',
        ),
      );
    }
    final q = b.packs.quote(offer.id);
    final simulated = b.payment is SimulatedPaymentGateway;
    return Scaffold(
      appBar: AppBar(title: const Text('Acheter un carnet')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: pagePadding(context, maxWidth: 760, bottom: Gap.xl),
          children: [
            GfCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(offer.name, style: AppText.title(size: 18)),
                  Text(
                    '${offer.quotaLabel} · valable ${offer.validityDays} '
                    'jours · ${offer.categoriesLabel}',
                    style: AppText.label(),
                  ),
                  const Divider(),
                  _line('Prix de la formule', Fmt.money(q.price)),
                  _line('Timbre fiscal', Fmt.money(q.stamp)),
                  const Divider(),
                  Row(
                    children: [
                      Text('Total à payer', style: AppText.subtitle()),
                      const Spacer(),
                      Text(
                        Fmt.money(q.total),
                        key: const Key('pack_total'),
                        style: AppText.stat(color: AppColors.redText),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.m),
            Row(
              children: [
                Icon(Icons.lock, color: AppColors.successText, size: 18),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    b.payment.label,
                    style: AppText.subtitle(size: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.s),
            if (simulated) ...[
              GfCard(
                color: AppColors.cream,
                child: const InfoRow(
                  Icons.science_outlined,
                  'Mode test : carte 4242 4242 4242 4242 acceptée. Aucune '
                  'donnée de carte n\'est enregistrée.',
                ),
              ),
              const SizedBox(height: Gap.m),
              TextFormField(
                controller: _number,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d ]')),
                  LengthLimitingTextInputFormatter(23),
                ],
                decoration: const InputDecoration(
                  labelText: 'Numéro de carte',
                  prefixIcon: Icon(Icons.credit_card),
                ),
                validator: (v) => SimulatedPaymentGateway.luhnValid(v ?? '')
                    ? null
                    : 'Numéro de carte invalide.',
              ),
              const SizedBox(height: Gap.m),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _expiry,
                      decoration: const InputDecoration(
                        labelText: 'Expiration (MM/AA)',
                      ),
                      validator: (v) => SimulatedPaymentGateway.validateExpiry(
                        v ?? '',
                        b.now(),
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: TextFormField(
                      controller: _cvc,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'CVC'),
                      validator: (v) =>
                          RegExp(r'^\d{3,4}$').hasMatch(v?.trim() ?? '')
                          ? null
                          : 'CVC invalide.',
                    ),
                  ),
                ],
              ),
            ] else
              GfCard(
                color: AppColors.cream,
                child: const InfoRow(
                  Icons.open_in_browser,
                  'Vous allez être redirigé vers la page de paiement '
                  'sécurisée. Aucune donnée de carte n\'est enregistrée par '
                  'GymFlow.',
                ),
              ),
            const SizedBox(height: Gap.l),
            LoadingButton(
              key: const Key('pack_pay'),
              label: 'Payer ${Fmt.money(q.total)}',
              icon: Icons.lock,
              loading: _paying,
              onPressed: _pay,
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label, style: AppText.body(size: 14))),
        Text(value, style: AppText.subtitle(size: 14)),
      ],
    ),
  );
}
